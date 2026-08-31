-- 0090 · Move the money/call lifecycle scheduler from in-process BullMQ to pg_cron.
--
-- WHY
-- The BullMQ worker (src/jobs/jobs.module.ts) only runs while the Render web
-- service is awake. Render idles the service when there is no HTTP traffic, and
-- the worker goes with it. Verified against Redis on 2026-08-30: the
-- `stalled-calls` job ran every minute until 2026-08-28 15:41 UTC, then nothing
-- for ~2 days, then resumed the moment an external request woke the service.
--
-- Consequence: settlement, no-show refunds, deadline auto-complete and the
-- stale-heartbeat sweep all pause for hours or days at a time. Live evidence:
-- call 11fceaad-… had deadline_at 14:03:22 and actually ended 20h56m later
-- (actual_duration_seconds = 75318) because nothing swept it.
--
-- WHAT
-- Five SECURITY DEFINER "job_*" functions reproduce what JobsService did
-- (settle / sweep-calls / expire-windows / cleanup-topups / purge-deletions),
-- each running the already-certified rpc_* functions as the trusted service
-- role, with per-item savepoint isolation so one bad row never aborts the run.
-- pg_cron then calls them on a fixed schedule — no always-on compute, and it is
-- exactly how the legacy database drove the same lifecycle (cron.job jobids
-- 1-3: process_end_of_day_expired_bookings, cleanup_stalled_calls, …).
--
-- The in-process BullMQ path stays in the code but is disabled by default
-- (JOBS_DRIVER=pgcron); set JOBS_DRIVER=bullmq to fall back to it. Both are
-- idempotent (row locks + partner_earnings_service_uq + already_settled guards),
-- so a brief overlap during rollout is safe.
--
-- SECURITY
-- These functions self-elevate (set app.is_service_role) so the assert_system()
-- guards inside the rpc_* pass. That guard is the ONLY thing standing between a
-- public anon key and a settlement run — verified: POST /rest/v1/rpc/
-- process_end_of_day_expired_bookings with the anon key reaches assert_system()
-- today. So each job_* is (a) REVOKEd from every PostgREST-reachable role and
-- (b) refuses to run from a session that carries an end-user identity.
--
-- NOTE ON purge-deletions: job_purge_deletions() runs rpc_purge_profile (PII
-- anonymisation) only — not the GoTrue auth.users credential delete, nor the R2
-- KYC object delete. Both were already app-side responsibilities the BullMQ job
-- did not perform in production (SUPABASE_SERVICE_ROLE_KEY unset), so this is
-- not a regression. Follow-up: drive them from pg_net or a dedicated worker.

BEGIN;

-- ── 1. sweeper functions ────────────────────────────────────────────────────
-- Each: SECURITY DEFINER + pinned empty search_path (db-doctor SECDEF_PATH);
-- refuse an end-user session; then set service context for the txn.

-- 1a. Calls: deadline auto-complete, stale-heartbeat drop, fan-no-join sweep.
--     Backed by call_deadline_idx / call_heartbeat_idx / call_active_idx.
CREATE OR REPLACE FUNCTION public.job_sweep_calls()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $fn$
DECLARE
  r record;
  v_completed int := 0;
  v_dropped   int := 0;
  v_failed    int := 0;
  v_sweep     jsonb;
BEGIN
  IF coalesce(current_setting('app.user_id', true), '') <> '' THEN
    RAISE EXCEPTION 'job_sweep_calls is a system sweep, not callable from a user session';
  END IF;
  PERFORM set_config('app.is_service_role', 'true', true);

  -- IN_PROGRESS past its deterministic deadline → auto-complete (→ settlement).
  FOR r IN
    SELECT id FROM public.calls
    WHERE attempt_status = 'IN_PROGRESS' AND deadline_at IS NOT NULL AND deadline_at <= now()
    ORDER BY deadline_at
    LIMIT 200
  LOOP
    BEGIN
      PERFORM public.rpc_complete_call(r.id, true);
      v_completed := v_completed + 1;
    EXCEPTION WHEN OTHERS THEN
      v_failed := v_failed + 1;
      RAISE WARNING 'job_sweep_calls: auto-complete % failed: %', r.id, SQLERRM;
    END;
  END LOOP;

  -- IN_PROGRESS but the freshest heartbeat from EITHER party is > 60s old →
  -- both sides are gone, drop it. greatest() over the two last-heartbeat columns
  -- coalesced to started_at matches the previous BullMQ query exactly — a call
  -- where one side is still beating survives and resolves at its deadline.
  FOR r IN
    SELECT id FROM public.calls
    WHERE attempt_status = 'IN_PROGRESS'
      AND greatest(coalesce(fan_last_heartbeat_at, started_at),
                   coalesce(partner_last_heartbeat_at, started_at)) < now() - interval '60 seconds'
    LIMIT 200
  LOOP
    BEGIN
      PERFORM public.rpc_mark_call_missed(r.id, 'DROPPED_TECHNICAL_ISSUE'::public.call_status);
      v_dropped := v_dropped + 1;
    EXCEPTION WHEN OTHERS THEN
      v_failed := v_failed + 1;
      RAISE WARNING 'job_sweep_calls: drop % failed: %', r.id, SQLERRM;
    END;
  END LOOP;

  -- PARTNER_INITIATED, fan never joined within the ring window → no-join.
  -- cleanup_stalled_calls() is self-contained and assert_system-gated.
  BEGIN
    v_sweep := public.cleanup_stalled_calls();
  EXCEPTION WHEN OTHERS THEN
    v_sweep := jsonb_build_object('error', SQLERRM);
    RAISE WARNING 'job_sweep_calls: cleanup_stalled_calls failed: %', SQLERRM;
  END;

  RETURN jsonb_build_object(
    'success', true,
    'completed', v_completed,
    'dropped', v_dropped,
    'missed_fan_no_join', coalesce((v_sweep ->> 'missed_fan_no_join')::int, 0),
    'failed', v_failed
  );
END $fn$;

-- 1b. Settlement: expire overdue bookings, then settle everything past its
--     settle_at (bookings, paid DM windows, shout-outs), plus shout-out
--     auto-confirm / expiry. Expiry FIRST so a booking reaches its terminal
--     status before the settle filter looks at it. Every driving query is
--     served by a purpose-built partial index (booking_settle_due_idx,
--     conversation_window_settle_due_idx, shoutout_*_due_idx).
CREATE OR REPLACE FUNCTION public.job_settle()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $fn$
DECLARE
  r record;
  v_expiry     jsonb;
  v_book_ok    int := 0; v_book_fail  int := 0;
  v_win_ok     int := 0; v_win_fail   int := 0;
  v_conf_ok    int := 0; v_conf_fail  int := 0;
  v_exp_ok     int := 0; v_exp_fail   int := 0;
  v_so_ok      int := 0; v_so_fail    int := 0;
BEGIN
  IF coalesce(current_setting('app.user_id', true), '') <> '' THEN
    RAISE EXCEPTION 'job_settle is a system sweep, not callable from a user session';
  END IF;
  PERFORM set_config('app.is_service_role', 'true', true);

  BEGIN
    v_expiry := public.process_end_of_day_expired_bookings();
  EXCEPTION WHEN OTHERS THEN
    v_expiry := jsonb_build_object('error', SQLERRM);
    RAISE WARNING 'job_settle: process_end_of_day_expired_bookings failed: %', SQLERRM;
  END;

  FOR r IN
    SELECT b.id FROM public.bookings b
    WHERE b.status = 'COMPLETED_SUCCESSFUL' AND b.settle_at <= now()
      AND NOT EXISTS (SELECT 1 FROM public.partner_earnings e WHERE e.service_id = b.id)
      AND NOT EXISTS (
        SELECT 1 FROM public.reports rp JOIN public.calls c ON c.id = rp.target_id
        WHERE rp.target_type = 'CALL' AND c.booking_id = b.id AND rp.status IN ('PENDING','REVIEWING'))
    LIMIT 200
  LOOP
    BEGIN PERFORM public.rpc_settle_booking(r.id); v_book_ok := v_book_ok + 1;
    EXCEPTION WHEN OTHERS THEN v_book_fail := v_book_fail + 1;
      RAISE WARNING 'job_settle: settle-booking % failed: %', r.id, SQLERRM; END;
  END LOOP;

  FOR r IN
    SELECT w.id FROM public.conversation_windows w
    WHERE w.kind = 'PAID' AND w.status = 'ANSWERED' AND w.settle_at <= now()
      AND NOT EXISTS (SELECT 1 FROM public.partner_earnings e WHERE e.service_id = w.id)
      AND NOT EXISTS (
        SELECT 1 FROM public.reports rp
        WHERE rp.target_type = 'DM' AND rp.target_id = w.id AND rp.status IN ('PENDING','REVIEWING'))
    LIMIT 200
  LOOP
    BEGIN PERFORM public.rpc_settle_window(r.id); v_win_ok := v_win_ok + 1;
    EXCEPTION WHEN OTHERS THEN v_win_fail := v_win_fail + 1;
      RAISE WARNING 'job_settle: settle-window % failed: %', r.id, SQLERRM; END;
  END LOOP;

  FOR r IN
    SELECT id FROM public.shout_out_requests
    WHERE status = 'VIDEO_DELIVERED_TO_FAN' AND fan_confirmed_at IS NULL AND review_deadline_at <= now()
    LIMIT 200
  LOOP
    BEGIN PERFORM public.rpc_auto_confirm_shoutout(r.id); v_conf_ok := v_conf_ok + 1;
    EXCEPTION WHEN OTHERS THEN v_conf_fail := v_conf_fail + 1;
      RAISE WARNING 'job_settle: auto-confirm-shoutout % failed: %', r.id, SQLERRM; END;
  END LOOP;

  FOR r IN
    SELECT id FROM public.shout_out_requests
    WHERE status = 'AWAITING_PARTNER_VIDEO' AND settle_at <= now()
    LIMIT 200
  LOOP
    BEGIN PERFORM public.rpc_expire_shoutout(r.id); v_exp_ok := v_exp_ok + 1;
    EXCEPTION WHEN OTHERS THEN v_exp_fail := v_exp_fail + 1;
      RAISE WARNING 'job_settle: expire-shoutout % failed: %', r.id, SQLERRM; END;
  END LOOP;

  FOR r IN
    SELECT id FROM public.shout_out_requests
    WHERE status = 'VIDEO_DELIVERED_TO_FAN' AND settle_at <= now() AND fan_confirmed_at IS NOT NULL
      AND NOT EXISTS (SELECT 1 FROM public.partner_earnings e WHERE e.service_id = shout_out_requests.id)
    LIMIT 200
  LOOP
    BEGIN PERFORM public.rpc_settle_shoutout(r.id); v_so_ok := v_so_ok + 1;
    EXCEPTION WHEN OTHERS THEN v_so_fail := v_so_fail + 1;
      RAISE WARNING 'job_settle: settle-shoutout % failed: %', r.id, SQLERRM; END;
  END LOOP;

  RETURN jsonb_build_object(
    'success', true,
    'expiry', v_expiry,
    'bookings',  jsonb_build_object('ok', v_book_ok, 'failed', v_book_fail),
    'windows',   jsonb_build_object('ok', v_win_ok,  'failed', v_win_fail),
    'confirms',  jsonb_build_object('ok', v_conf_ok, 'failed', v_conf_fail),
    'expired_shoutouts', jsonb_build_object('ok', v_exp_ok, 'failed', v_exp_fail),
    'shoutouts', jsonb_build_object('ok', v_so_ok,   'failed', v_so_fail)
  );
END $fn$;

-- 1c. Paid DM windows unanswered past their deadline → refund the fan.
--     Port of JobsService.expireWindows(): the refund and the status flip are
--     one atomic unit per window (a failed refund rolls back the whole
--     iteration and the window stays OPEN for the next run). Served by
--     window_open_idx.
CREATE OR REPLACE FUNCTION public.job_expire_windows()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $fn$
DECLARE
  r record;
  v_ok int := 0;
  v_failed int := 0;
  v_wallet uuid;
BEGIN
  IF coalesce(current_setting('app.user_id', true), '') <> '' THEN
    RAISE EXCEPTION 'job_expire_windows is a system sweep, not callable from a user session';
  END IF;
  PERFORM set_config('app.is_service_role', 'true', true);

  FOR r IN
    SELECT w.id, c.fan_id, w.charge_paise
    FROM public.conversation_windows w
    JOIN public.conversations c ON c.id = w.conversation_id
    WHERE w.kind = 'PAID' AND w.status = 'OPEN' AND w.response_deadline <= now()
    LIMIT 200
  LOOP
    BEGIN
      SELECT id INTO v_wallet FROM public.wallets WHERE profile_id = r.fan_id;
      IF v_wallet IS NULL THEN
        RAISE EXCEPTION 'no wallet for fan %', r.fan_id;
      END IF;

      PERFORM public.post_transaction(
        'REFUND'::public.txn_type,
        r.charge_paise,
        'qq-expire-refund:' || r.id::text,
        jsonb_build_array(
          jsonb_build_object('account', 'booking_escrow', 'delta_paise', -r.charge_paise),
          jsonb_build_object('wallet_id', v_wallet, 'account', 'wallet', 'delta_paise', r.charge_paise)
        )
      );
      UPDATE public.conversation_windows SET status = 'EXPIRED' WHERE id = r.id;

      BEGIN
        PERFORM public.rpc_create_notification(
          r.fan_id, NULL,
          'QUESTION_EXPIRED_NO_RESPONSE_FAN'::public.notification_event_type_enum,
          'Question expired',
          'Your question went unanswered in time and you have been refunded.',
          'question'::public.notification_related_entity_type_enum,
          r.id, '{}'::jsonb
        );
      EXCEPTION WHEN OTHERS THEN
        RAISE WARNING 'job_expire_windows: notify % failed (refund kept): %', r.id, SQLERRM;
      END;

      v_ok := v_ok + 1;
    EXCEPTION WHEN OTHERS THEN
      v_failed := v_failed + 1;
      RAISE WARNING 'job_expire_windows: % failed (left OPEN for retry): %', r.id, SQLERRM;
    END;
  END LOOP;

  RETURN jsonb_build_object('success', true, 'refunded', v_ok, 'failed', v_failed);
END $fn$;

-- 1d. Abandoned Razorpay checkouts → FAILED. rpc_cleanup_abandoned_topups() is
--     a single self-contained statement; this just supplies service context.
CREATE OR REPLACE FUNCTION public.job_cleanup_topups()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $fn$
BEGIN
  IF coalesce(current_setting('app.user_id', true), '') <> '' THEN
    RAISE EXCEPTION 'job_cleanup_topups is a system sweep, not callable from a user session';
  END IF;
  PERFORM set_config('app.is_service_role', 'true', true);
  RETURN public.rpc_cleanup_abandoned_topups();
END $fn$;

-- 1e. Account-deletion PII purge (grace period elapsed). See header note on
--     what this deliberately does NOT do. Served by deletion_requests_purge_idx.
CREATE OR REPLACE FUNCTION public.job_purge_deletions()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $fn$
DECLARE
  r record;
  v_ok int := 0;
  v_failed int := 0;
BEGIN
  IF coalesce(current_setting('app.user_id', true), '') <> '' THEN
    RAISE EXCEPTION 'job_purge_deletions is a system sweep, not callable from a user session';
  END IF;
  PERFORM set_config('app.is_service_role', 'true', true);

  FOR r IN
    SELECT id, profile_id FROM public.deletion_requests
    WHERE status IN ('REQUESTED','CONFIRMED') AND scheduled_purge_at <= now()
    LIMIT 100
  LOOP
    BEGIN
      PERFORM public.rpc_purge_profile(r.profile_id);
      UPDATE public.deletion_requests SET status = 'COMPLETED', completed_at = now() WHERE id = r.id;
      v_ok := v_ok + 1;
    EXCEPTION WHEN OTHERS THEN
      v_failed := v_failed + 1;
      RAISE WARNING 'job_purge_deletions: % failed: %', r.profile_id, SQLERRM;
    END;
  END LOOP;

  RETURN jsonb_build_object('success', true, 'purged', v_ok, 'failed', v_failed);
END $fn$;

-- Lock these to pg_cron (which runs as the owner). Supabase's ALTER DEFAULT
-- PRIVILEGES auto-grants EXECUTE to PUBLIC + anon/authenticated/service_role/
-- zudue_app on every new public function — and these functions self-elevate to
-- service role, so leaving any of those grants makes them a
-- POST /rest/v1/rpc/<name> escalation endpoint. Revoke all of them; the owner
-- keeps EXECUTE implicitly. (anon/authenticated/service_role are created by
-- 0000, zudue_app by 0025 — all exist before this runs.)
REVOKE ALL ON FUNCTION public.job_sweep_calls()     FROM PUBLIC, anon, authenticated, service_role, zudue_app;
REVOKE ALL ON FUNCTION public.job_settle()          FROM PUBLIC, anon, authenticated, service_role, zudue_app;
REVOKE ALL ON FUNCTION public.job_expire_windows()  FROM PUBLIC, anon, authenticated, service_role, zudue_app;
REVOKE ALL ON FUNCTION public.job_cleanup_topups()  FROM PUBLIC, anon, authenticated, service_role, zudue_app;
REVOKE ALL ON FUNCTION public.job_purge_deletions() FROM PUBLIC, anon, authenticated, service_role, zudue_app;

-- ── 2. schedule (pg_cron must already be enabled) ───────────────────────────
-- pg_cron's control file requires a superuser to CREATE EXTENSION, and the
-- migration role is not one — so enabling the extension is a one-time project
-- action, not something this migration does. On Supabase: Dashboard → Database →
-- Extensions → pg_cron, or SQL Editor `create extension pg_cron;`. Then run
-- `pnpm db:migrate`. cron.schedule() upserts by job name, so 0090 is replay-safe.
--
-- Standard 5-field cron (1-minute floor) everywhere for portability. The client
-- also learns a terminal status within one 15s heartbeat (migration 0088), so
-- the 60s call-sweep cadence is a backstop, not the primary path.
DO $cron$
BEGIN
  IF coalesce(current_setting('shared_preload_libraries', true), '') NOT LIKE '%pg_cron%' THEN
    RAISE NOTICE '0090: pg_cron not preloaded — job_* functions applied, scheduling skipped (expected on CI / local Postgres).';
    RETURN;
  END IF;

  IF to_regclass('cron.job') IS NULL THEN
    RAISE EXCEPTION USING
      message = '0090 needs the pg_cron extension enabled. Enable it once (Supabase Dashboard -> Database -> Extensions -> pg_cron, or SQL Editor: create extension pg_cron;), then re-run pnpm db:migrate. Nothing was applied.',
      errcode = 'feature_not_supported';
  END IF;

  PERFORM cron.schedule('zudue-sweep-calls',        '* * * * *',   'SELECT public.job_sweep_calls()');
  PERFORM cron.schedule('zudue-settle',             '*/5 * * * *', 'SELECT public.job_settle()');
  PERFORM cron.schedule('zudue-expire-windows',     '*/5 * * * *', 'SELECT public.job_expire_windows()');
  PERFORM cron.schedule('zudue-cleanup-topups',     '30 2 * * *',  'SELECT public.job_cleanup_topups()');
  PERFORM cron.schedule('zudue-purge-deletions',    '0 3 * * *',   'SELECT public.job_purge_deletions()');
  -- pg_cron writes one cron.job_run_details row per run and never prunes it
  -- (6 jobs, sweep-calls every minute → ~1.5k rows/day). Keep 7 days.
  PERFORM cron.schedule('zudue-cron-log-retention', '17 4 * * *',
    $q$DELETE FROM cron.job_run_details WHERE end_time < now() - interval '7 days'$q$);

  RAISE NOTICE '0090: 6 pg_cron jobs scheduled (zudue-*)';
END
$cron$;

INSERT INTO _migrations (name) VALUES ('0090_pgcron_lifecycle_scheduler.sql')
  ON CONFLICT (name) DO NOTHING;

COMMIT;

-- 0066 · Settlement sweep correctness and performance — Fixes 1-3 (VERIFIED SAFE).
--
-- ⚠️ NEEDS REVIEW BEFORE APPLYING — this touches money-moving functions
-- directly, not just indexes as the filename originally implied.
--
-- Every function body below was pulled live via pg_get_functiondef and
-- diffed by hand — each change is called out in its own comment so the diff
-- against the currently-running version is auditable line by line, the same
-- discipline as 0058's "only that one line changed."
--
-- ────────────────────────────────────────────────────────────────────────
-- FIX 1 (CRITICAL, verified via database audit): EXPIRED_FAN_NO_JOIN bookings
-- are currently double-paid.
--
-- process_end_of_day_expired_bookings refunds the fan in full for ANY
-- non-COMPLETED_SUCCESSFUL terminal status, including EXPIRED_FAN_NO_JOIN
-- (see its own "CRITICAL: Any call >= 3 min -> partner earned the money"
-- comment — everything else is refund-only, by design).
--
-- But apps/api/src/jobs/jobs.module.ts's settle() sweep queries
--   bookings WHERE status IN ('COMPLETED_SUCCESSFUL','EXPIRED_FAN_NO_JOIN')
-- and calls rpc_settle_booking on every match. rpc_settle_booking has no
-- internal status check — it only checks whether a partner_earnings row
-- already exists, and a REFUND transaction doesn't create one. Both steps
-- run back-to-back inside the same settle() call. Net effect: a booking
-- where the fan never joins gets refunded to the fan in full, then
-- immediately credited to the partner in full — two payouts against escrow
-- that only ever received one payment.
--
-- rpc_settle_shoutout already gates on status internally
-- (status<>'VIDEO_DELIVERED_TO_FAN' -> NOT_SETTLEABLE). rpc_settle_booking
-- and rpc_settle_window never got the equivalent check. Adding it here.
-- The jobs.module.ts query itself also needs EXPIRED_FAN_NO_JOIN removed
-- (separate change, application code, not this file) — this DB-layer gate
-- is the real fix; that's just to stop the sweep wasting attempts and
-- logging false "settle had failures" on every run.
--
-- FIX 2 (CRITICAL, verified via database audit): report-aware settlement hold
-- (calls + DM windows).
--
-- Shout-outs already correctly stop settling once reported — rpc_report_
-- shoutout flips status to ISSUE_REPORTED_BY_FAN, which falls outside
-- rpc_settle_shoutout's own status gate. Calls and DM windows have no
-- equivalent: reporting a call or question inserts into `reports` but never
-- touches the booking's or window's own status column, so the sweep is
-- completely blind to open reports and pays out on schedule regardless.
-- Adding an internal EXISTS check against `reports` (status PENDING/
-- REVIEWING) to both rpc_settle_booking and rpc_settle_window closes this
-- the same way status already does for shout-outs — and because it's
-- inside the settle functions themselves, rpc_admin_force_settle_booking
-- (which just calls rpc_settle_booking) automatically respects it too, so
-- an admin can't accidentally force-settle past an open report either.
--
-- FIX 3 (HIGH priority, verified via database audit): settle_at anchor for bookings.
--
-- shout_out_requests resets settle_at to now()+settlement_window_days at
-- delivery time (rpc_upload_shoutout) — a genuine review window regardless
-- of when within the request lifecycle delivery happens. Bookings never do
-- this: settle_at is fixed at booking CREATION, not call completion. A call
-- landing on day 6 of a 7-day booking window leaves the fan one day to
-- notice a problem before the sweep would otherwise settle it. This
-- recomputes settle_at at the moment a booking actually reaches
-- COMPLETED_SUCCESSFUL, mirroring the shout-out pattern. EXPIRED_* bookings
-- don't need this — they're refunded and fully resolved in this same
-- function call, settle_at is irrelevant to them afterward.
-- ────────────────────────────────────────────────────────────────────────

BEGIN;

-- Supports the report-hold EXISTS check added to rpc_settle_booking below.
-- report_status_idx already covers plain `status`; this covers the
-- (target_type, target_id) lookup the hold check actually filters on, same
-- partial predicate (only open reports matter for this).
CREATE INDEX report_target_open_idx ON public.reports (target_type, target_id)
  WHERE status IN ('PENDING', 'REVIEWING');

-- Settlement-sweep indexes (original scope of this file) — match the
-- sweep's actual queries in jobs.module.ts, which the pre-existing
-- booking_settle_idx (WHERE status='BOOKED') does not; that index still
-- backs the day-7 expiry pass in process_end_of_day_expired_bookings and is
-- left untouched.
CREATE INDEX booking_settle_due_idx ON public.bookings (settle_at)
  WHERE status IN ('COMPLETED_SUCCESSFUL', 'EXPIRED_FAN_NO_JOIN');

CREATE INDEX conversation_window_settle_due_idx ON public.conversation_windows (settle_at)
  WHERE kind = 'PAID' AND status = 'ANSWERED';

CREATE INDEX shoutout_settle_due_idx ON public.shout_out_requests (settle_at)
  WHERE status = 'VIDEO_DELIVERED_TO_FAN' AND fan_confirmed_at IS NOT NULL;

-- rpc_settle_booking — hardened with a status gate (Fix 1) and a report-hold
-- gate (Fix 2). Everything else below is byte-identical to the live
-- definition pulled via pg_get_functiondef.
CREATE OR REPLACE FUNCTION public.rpc_settle_booking(p_booking uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE b public.bookings; v_res jsonb; v_gross bigint;
BEGIN
  PERFORM public.assert_system();
  SELECT * INTO b FROM public.bookings WHERE id=p_booking FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('success',false,'error','NOT_FOUND'); END IF;

  -- Fix 1: only a booking the partner actually delivered is settleable.
  -- EXPIRED_* statuses are refund-only, handled entirely inside
  -- process_end_of_day_expired_bookings — this function must never also pay
  -- the partner for one, or the same escrow paisa gets spent twice.
  IF b.status <> 'COMPLETED_SUCCESSFUL' THEN
    RETURN jsonb_build_object('success',false,'error','NOT_SETTLEABLE','status',b.status); END IF;

  -- Fix 2: a call with an open report holds here until the report resolves.
  -- target_id on a CALL-type report is the calls row, not the booking, so
  -- this joins through booking_id.
  IF EXISTS (
    SELECT 1 FROM public.reports r JOIN public.calls c ON c.id = r.target_id
     WHERE r.target_type = 'CALL' AND c.booking_id = p_booking
       AND r.status IN ('PENDING','REVIEWING')
  ) THEN
    RETURN jsonb_build_object('success',false,'error','REPORT_PENDING'); END IF;

  -- Idempotency (0043): the row lock above serialises concurrent settles of
  -- this booking, so a replay sees the committed earning and exits cleanly.
  IF EXISTS (SELECT 1 FROM public.partner_earnings e WHERE e.service_id = p_booking) THEN
    RETURN jsonb_build_object('success',true,'already_settled',true); END IF;

  -- Escrow holds the list price; the creator is settled that, not the
  -- discounted amount the fan paid. COALESCE guards rows predating 0042.
  v_gross := COALESCE(b.original_price_paise, b.price_paise);

  v_res := public.post_transaction('PARTNER_EARNING', v_gross, 'settle:'||b.id::text,
    jsonb_build_array(
      jsonb_build_object('account','booking_escrow','delta_paise',-v_gross),
      jsonb_build_object('account','partner_payable','delta_paise',v_gross)),
    b.id::text);

  INSERT INTO public.partner_earnings (partner_id, transaction_id, service_type, service_id, amount_paise)
  VALUES (b.partner_id, (v_res->>'transaction_id')::uuid, 'VIDEO_CALL', b.id, v_gross);

  RETURN jsonb_build_object('success',true,'transaction_id',v_res->>'transaction_id');
END $function$;

-- rpc_settle_window — same two gates added (Fix 1 equivalent: status must
-- be ANSWERED, which the original never checked either; Fix 2: report hold,
-- target_id on a DM-type report IS the window id directly).
CREATE OR REPLACE FUNCTION public.rpc_settle_window(p_window uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE w public.conversation_windows; v_partner uuid; v_res jsonb;
BEGIN
  PERFORM public.assert_system();
  SELECT * INTO w FROM public.conversation_windows WHERE id=p_window FOR UPDATE;
  IF NOT FOUND OR w.kind<>'PAID' OR w.charge_paise=0 OR w.status<>'ANSWERED' THEN
    RETURN jsonb_build_object('success',false,'error','NOT_SETTLEABLE'); END IF;

  IF EXISTS (
    SELECT 1 FROM public.reports r
     WHERE r.target_type = 'DM' AND r.target_id = p_window
       AND r.status IN ('PENDING','REVIEWING')
  ) THEN
    RETURN jsonb_build_object('success',false,'error','REPORT_PENDING'); END IF;

  -- Idempotency (0043) — see rpc_settle_booking.
  IF EXISTS (SELECT 1 FROM public.partner_earnings e WHERE e.service_id = p_window) THEN
    RETURN jsonb_build_object('success',true,'already_settled',true); END IF;

  SELECT partner_id INTO v_partner FROM public.conversations WHERE id=w.conversation_id;

  v_res := public.post_transaction('PARTNER_EARNING', w.charge_paise, 'settlewin:'||w.id::text,
    jsonb_build_array(
      jsonb_build_object('account','booking_escrow','delta_paise',-w.charge_paise),
      jsonb_build_object('account','partner_payable','delta_paise',w.charge_paise)),
    w.id::text);
  INSERT INTO public.partner_earnings (partner_id, transaction_id, service_type, service_id, amount_paise)
    VALUES (v_partner, (v_res->>'transaction_id')::uuid, 'QUICK_QUESTION', w.id, w.charge_paise);
  RETURN jsonb_build_object('success',true,'transaction_id',v_res->>'transaction_id');
END $function$;

-- process_end_of_day_expired_bookings — byte-identical to the live
-- definition except the single UPDATE at the end, split in two so only the
-- COMPLETED_SUCCESSFUL path recomputes settle_at (Fix 3). Everything above
-- that point — the call-history classification, the refund legs, the
-- availability release — is untouched.
CREATE OR REPLACE FUNCTION public.process_end_of_day_expired_bookings()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_booking RECORD;
  v_status public.booking_status;
  v_gross bigint;
  v_disc bigint;
  v_wallet uuid;
  v_legs jsonb;
  v_mins int;

  v_completed int := 0;
  v_partner_no_show int := 0;
  v_fan_no_join int := 0;
  v_fan_declined int := 0;
  v_technical int := 0;
  v_failed int := 0;
BEGIN
  PERFORM public.assert_system();

  FOR v_booking IN (
    SELECT
      b.id, b.fan_id, b.price_paise, b.original_price_paise, b.discount_paise,
      b.selected_duration, b.partner_id, b.scheduled_date,
      COALESCE(MAX(EXTRACT(epoch FROM (c.ended_at - c.started_at))), 0) as max_duration_sec,
      COUNT(c.id) FILTER (WHERE c.attempt_status = 'MISSED_FAN_NO_JOIN') as missed_fan,
      COUNT(c.id) FILTER (WHERE c.attempt_status = 'MISSED_FAN_DECLINED') as declined_fan,
      COUNT(c.id) FILTER (WHERE c.attempt_status = 'DROPPED_TECHNICAL_ISSUE') as dropped_tech,
      COUNT(c.id) as total_calls
    FROM public.bookings b
    LEFT JOIN public.calls c ON c.booking_id = b.id
      AND c.attempt_status IN ('COMPLETED_SUCCESSFUL', 'MISSED_FAN_NO_JOIN', 'MISSED_FAN_DECLINED', 'DROPPED_TECHNICAL_ISSUE')
    WHERE b.status = 'BOOKED' AND b.settle_at <= now()
    GROUP BY b.id, b.fan_id, b.price_paise, b.original_price_paise, b.discount_paise,
             b.selected_duration, b.partner_id, b.scheduled_date
    LIMIT 200
  )
  LOOP
    BEGIN
      IF v_booking.max_duration_sec >= 180 THEN
        v_status := 'COMPLETED_SUCCESSFUL';
        v_completed := v_completed + 1;
      ELSIF v_booking.total_calls = 0 THEN
        v_status := 'EXPIRED_PARTNER_NO_SHOW';
        v_partner_no_show := v_partner_no_show + 1;
      ELSIF v_booking.declined_fan > 0 THEN
        v_status := 'EXPIRED_FAN_DECLINED';
        v_fan_declined := v_fan_declined + 1;
      ELSIF v_booking.missed_fan > 0 THEN
        v_status := 'EXPIRED_FAN_NO_JOIN';
        v_fan_no_join := v_fan_no_join + 1;
      ELSIF v_booking.dropped_tech > 0 THEN
        v_status := 'EXPIRED_TECHNICAL_ISSUE';
        v_technical := v_technical + 1;
      ELSE
        v_status := 'EXPIRED_TECHNICAL_ISSUE';
        v_technical := v_technical + 1;
      END IF;

      IF v_status <> 'COMPLETED_SUCCESSFUL' THEN
        v_gross := COALESCE(v_booking.original_price_paise, v_booking.price_paise);
        v_disc := COALESCE(v_booking.discount_paise, 0);

        SELECT id INTO v_wallet FROM public.wallets WHERE profile_id = v_booking.fan_id;
        IF v_wallet IS NULL THEN
          RAISE EXCEPTION 'Wallet not found for fan %', v_booking.fan_id;
        END IF;

        v_legs := jsonb_build_array(
          jsonb_build_object('account', 'booking_escrow', 'delta_paise', -v_gross),
          jsonb_build_object('wallet_id', v_wallet, 'account', 'wallet', 'delta_paise', v_booking.price_paise)
        );
        IF v_disc > 0 THEN
          v_legs := v_legs || jsonb_build_array(
            jsonb_build_object('account', 'promo_incentive', 'delta_paise', v_disc)
          );
        END IF;

        PERFORM public.post_transaction('REFUND', v_gross, 'expire:'||v_booking.id::text, v_legs, v_booking.id::text);

        v_mins := (v_booking.selected_duration::text)::int;
        UPDATE public.availability
        SET booked_minutes = GREATEST(0, booked_minutes - v_mins)
        WHERE partner_id = v_booking.partner_id AND date = v_booking.scheduled_date;
      END IF;

      -- Fix 3: only the COMPLETED_SUCCESSFUL path gets a recomputed
      -- settle_at, giving the fan a genuine review window from actual call
      -- completion rather than from the original booking date. EXPIRED_*
      -- bookings are already fully resolved (refunded above) — settle_at is
      -- moot for them from here on.
      IF v_status = 'COMPLETED_SUCCESSFUL' THEN
        UPDATE public.bookings
        SET status = v_status,
            settle_at = now() + ((SELECT settlement_window_days FROM public.platform_settings WHERE id=1) * interval '1 day'),
            updated_at = now()
        WHERE id = v_booking.id;
      ELSE
        UPDATE public.bookings
        SET status = v_status, updated_at = now()
        WHERE id = v_booking.id;
      END IF;

    EXCEPTION WHEN OTHERS THEN
      v_failed := v_failed + 1;
      RAISE WARNING 'expire-booking failed for %: %', v_booking.id, SQLERRM;
    END;
  END LOOP;

  RETURN jsonb_build_object(
    'success', true,
    'completed', v_completed,
    'expired_partner_no_show', v_partner_no_show,
    'expired_fan_no_join', v_fan_no_join,
    'expired_fan_declined', v_fan_declined,
    'expired_technical', v_technical,
    'failed', v_failed
  );
END $function$;

INSERT INTO _migrations (name) VALUES ('0066_settlement_sweep_indexes.sql')
  ON CONFLICT (name) DO NOTHING;

COMMIT;

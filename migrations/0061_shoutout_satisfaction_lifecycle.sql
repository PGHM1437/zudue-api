-- 0061 · Shout-out customer-satisfaction & dispute lifecycle.
--
-- Replaces the timer-settled, admin-offline delivery flow (0017/0036/0059) with
-- a fan-gated lifecycle. The business rule: the partner is credited ONLY after
-- the fan confirms the work is acceptable (or an admin decides on their
-- behalf). Money may never move on a delivery the fan never accepted.
--
-- 1. Fan requests a shout-out → escrow funded, AWAITING_PARTNER_VIDEO.
-- 2. Partner uploads the video → delivered straight to the fan
--    (VIDEO_DELIVERED_TO_FAN). The admin offline pre-review is abolished.
-- 3. The fan gets ONE FREE correction round.
-- 4. Every further correction round is PAID: a platform fee flows
--    wallet → booking_escrow, so it is credited to the partner at settlement.
-- 5. The fan may raise a dispute → ISSUE_REPORTED_BY_FAN → admin queue.
-- 6. Settlement is DOUBLE-GATED: VIDEO_DELIVERED_TO_FAN AND fan_confirmed_at
--    IS NOT NULL. The settle job additionally auto-confirms deliveries whose
--    review window (shoutout_review_days) elapsed without fan action.
-- 7. Admin can force-confirm (work submitted properly even if the fan is
--    unhappy) via the repurposed rpc_admin_deliver_shoutout(approve=true).
-- 8. Admin can cancel with a FULL refund — price + every paid correction fee —
--    via rpc_admin_cancel_shoutout.
-- 9. Cancellation is ADMIN-ONLY; post-settlement is irreversible by design.
--
-- Zero new enum values: every lifecycle stage maps onto an existing
-- shout_out_status_enum value (all rework rounds reuse AWAITING_PARTNER_VIDEO),
-- and all notification event types already exist.

BEGIN;

-- ── 1 · Lifecycle columns on shout_out_requests ─────────────────────────
ALTER TABLE public.shout_out_requests ADD COLUMN fan_confirmed_at timestamptz;
ALTER TABLE public.shout_out_requests ADD COLUMN fan_confirmed_source text
  CHECK (fan_confirmed_source IN ('FAN','ADMIN','AUTO'));
ALTER TABLE public.shout_out_requests ADD COLUMN admin_confirmed_by uuid REFERENCES public.profiles(id);
ALTER TABLE public.shout_out_requests ADD COLUMN free_correction_used_at timestamptz;
ALTER TABLE public.shout_out_requests ADD COLUMN disputed_at timestamptz;
ALTER TABLE public.shout_out_requests ADD COLUMN review_deadline_at timestamptz;

-- ── 2 · Platform knobs: paid-correction fee + fan review window ─────────
ALTER TABLE public.platform_settings ADD COLUMN shoutout_correction_fee_paise bigint NOT NULL DEFAULT 9900;
ALTER TABLE public.platform_settings ADD COLUMN shoutout_review_days integer NOT NULL DEFAULT 3;

-- ── 3 · Correction rounds (one row per free/paid round). Writes happen ONLY
--      inside RPCs — RLS grants SELECT to the shout-out's fan/partner/admin
--      and deliberately has no insert/update policy. ─────────────────────
CREATE TABLE public.shoutout_corrections (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  shoutout_id     uuid NOT NULL REFERENCES public.shout_out_requests(id),
  kind            text NOT NULL CHECK (kind IN ('FREE','PAID')),
  fee_paise       bigint NOT NULL DEFAULT 0 CHECK (fee_paise >= 0),
  fee_txn_id      uuid REFERENCES public.transactions(id),
  fan_note        text,
  video_path      text,
  resubmitted_at  timestamptz,
  created_at      timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX shoutout_correction_shoutout_idx ON public.shoutout_corrections (shoutout_id, created_at);

ALTER TABLE public.shoutout_corrections ENABLE ROW LEVEL SECURITY;
CREATE POLICY shoutout_correction_party ON public.shoutout_corrections FOR SELECT USING (
  EXISTS (SELECT 1 FROM public.shout_out_requests s WHERE s.id = shoutout_corrections.shoutout_id
          AND (s.fan_id = current_user_id() OR s.partner_id = current_user_id()))
  OR is_admin());

-- ── 4 · rpc_upload_shoutout — partner delivers DIRECTLY to the fan, on the
--      initial upload and on every correction re-submit. The admin CC
--      notification 0059 added is dropped with the offline review step.
--      Both clocks re-anchor on every delivery: the fan's review window and
--      the settlement date (the fan may only be owed days from the latest
--      video they received). fan_confirmed_at is forced NULL on every
--      delivery (defense-in-depth: a rework round can never inherit a
--      stale confirmation) — confirmation is a separate fan/admin/auto
--      act. ──────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION rpc_upload_shoutout(p_id uuid, p_video_path text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE r public.shout_out_requests; v_review_days int; v_settle_days int;
BEGIN
  SELECT * INTO r FROM public.shout_out_requests WHERE id=p_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('success',false,'error','NOT_FOUND'); END IF;
  PERFORM public.assert_caller(r.partner_id);
  IF btrim(coalesce(p_video_path,'')) = '' THEN
    RETURN jsonb_build_object('success',false,'error','LINK_REQUIRED'); END IF;

  SELECT shoutout_review_days, settlement_window_days INTO v_review_days, v_settle_days
    FROM public.platform_settings WHERE id=1;

  UPDATE public.shout_out_requests
     SET partner_video_storage_path = p_video_path,
         delivered_video_link       = p_video_path,
         partner_video_submitted_at = now(),
         delivered_at               = now(),
         status                     = 'VIDEO_DELIVERED_TO_FAN',
         fan_confirmed_at           = NULL,
         fan_confirmed_source       = NULL,
         admin_confirmed_by         = NULL,
         review_deadline_at         = now() + (v_review_days || ' days')::interval,
         settle_at                  = now() + (v_settle_days || ' days')::interval,
         updated_at                 = now()
   WHERE id=p_id AND status='AWAITING_PARTNER_VIDEO';
  IF NOT FOUND THEN RETURN jsonb_build_object('success',false,'error','INVALID_STATE'); END IF;

  -- Close every open correction round with the video that answers it.
  UPDATE public.shoutout_corrections
     SET resubmitted_at=now(), video_path=p_video_path
   WHERE shoutout_id=p_id AND resubmitted_at IS NULL;

  INSERT INTO public.notifications (recipient_id, event_type, title, message, related_entity_type, related_entity_id)
    VALUES (r.fan_id,'SHOUTOUT_STATUS_UPDATE_FAN','Your shout-out is ready',
            'Your personalised shout-out video has been delivered.','shoutout',p_id);

  RETURN jsonb_build_object('success',true,'status','VIDEO_DELIVERED_TO_FAN');
END $$;

-- ── 5 · rpc_settle_shoutout — fan-gated. The earning is price + every PAID
--      correction fee, posted as one escrow → partner_payable movement. ──
CREATE OR REPLACE FUNCTION rpc_settle_shoutout(p_shoutout uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE s public.shout_out_requests; v_res jsonb; v_fees bigint; v_total bigint;
BEGIN
  PERFORM public.assert_system();   -- settlement sweep job / admin only
  SELECT * INTO s FROM public.shout_out_requests WHERE id = p_shoutout FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('success',false,'error','NOT_FOUND'); END IF;
  -- Money only after the fan confirmed (or admin/auto confirmed on their
  -- behalf). An unconfirmed delivery is NOT settleable, however old.
  IF s.status <> 'VIDEO_DELIVERED_TO_FAN' OR s.fan_confirmed_at IS NULL THEN
    RETURN jsonb_build_object('success',false,'error','NOT_SETTLEABLE'); END IF;
  -- Idempotent: never create a second earning for the same shout-out.
  IF EXISTS (SELECT 1 FROM public.partner_earnings e WHERE e.service_id = p_shoutout) THEN
    RETURN jsonb_build_object('success',true,'already_settled',true); END IF;

  SELECT COALESCE(sum(c.fee_paise),0) INTO v_fees
    FROM public.shoutout_corrections c WHERE c.shoutout_id=p_shoutout AND c.kind='PAID';
  v_total := s.price_paise + v_fees;

  v_res := public.post_transaction('PARTNER_EARNING', v_total, 'settle-so:'||s.id::text,
    jsonb_build_array(
      jsonb_build_object('account','booking_escrow','delta_paise',-v_total),
      jsonb_build_object('account','partner_payable','delta_paise',v_total)),
    s.id::text);

  INSERT INTO public.partner_earnings (partner_id, transaction_id, service_type, service_id, amount_paise)
  VALUES (s.partner_id, (v_res->>'transaction_id')::uuid, 'SHOUT_OUT', s.id, v_total);

  RETURN jsonb_build_object('success',true,'transaction_id',v_res->>'transaction_id');
END $$;

-- ── 6 · rpc_report_shoutout — disputes only BEFORE confirmation ─────────
CREATE OR REPLACE FUNCTION rpc_report_shoutout(p_id uuid, p_reason text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE r public.shout_out_requests;
BEGIN
  SELECT * INTO r FROM public.shout_out_requests WHERE id=p_id FOR UPDATE;
  IF NOT FOUND OR r.status<>'VIDEO_DELIVERED_TO_FAN' OR r.fan_confirmed_at IS NOT NULL THEN
    RETURN jsonb_build_object('success',false,'error','NOT_REPORTABLE'); END IF;
  PERFORM public.assert_caller(r.fan_id);
  UPDATE public.shout_out_requests
     SET status='ISSUE_REPORTED_BY_FAN', disputed_at=now(), updated_at=now()
   WHERE id=p_id;
  INSERT INTO public.reports (reporter_id, target_type, target_id, reason)
    VALUES (r.fan_id, 'SHOUTOUT', p_id, p_reason);
  INSERT INTO public.notifications (recipient_id, event_type, title, message, related_entity_type, related_entity_id)
    SELECT p.id, 'PLATFORM_ANNOUNCEMENT', 'Shout-out flagged', 'A delivered shout-out was reported.', 'shoutout', p_id
    FROM public.profiles p WHERE p.role='ADMIN' LIMIT 1;
  RETURN jsonb_build_object('success',true);
END $$;

-- ── 7 · rpc_confirm_shoutout — the fan accepts the delivered video ──────
CREATE OR REPLACE FUNCTION rpc_confirm_shoutout(p_fan uuid, p_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE r public.shout_out_requests;
BEGIN
  SELECT * INTO r FROM public.shout_out_requests WHERE id=p_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('success',false,'error','NOT_FOUND'); END IF;
  PERFORM public.assert_caller(p_fan);
  IF p_fan IS DISTINCT FROM r.fan_id THEN
    RETURN jsonb_build_object('success',false,'error','FAN_MISMATCH'); END IF;
  IF r.status <> 'VIDEO_DELIVERED_TO_FAN' THEN
    RETURN jsonb_build_object('success',false,'error','INVALID_STATE'); END IF;
  IF r.fan_confirmed_at IS NOT NULL THEN
    RETURN jsonb_build_object('success',true,'already_confirmed',true); END IF;
  UPDATE public.shout_out_requests
     SET fan_confirmed_at=now(), fan_confirmed_source='FAN', updated_at=now()
   WHERE id=p_id AND status='VIDEO_DELIVERED_TO_FAN' AND fan_confirmed_at IS NULL;
  IF NOT FOUND THEN RETURN jsonb_build_object('success',false,'error','INVALID_STATE'); END IF;
  RETURN jsonb_build_object('success',true,'confirmed',true);
END $$;

-- ── 8 · rpc_request_correction — one free round, then paid rounds. A paid
--      round moves the fee wallet → booking_escrow under its own idempotency
--      key so it is credited back to the partner at settlement. A wallet
--      CHECK abort (negative balance) is caught and surfaced as an error
--      json instead of a 500. ────────────────────────────────────────────
CREATE OR REPLACE FUNCTION rpc_request_correction(p_fan uuid, p_id uuid, p_note text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE r public.shout_out_requests; v_wallet uuid; v_fee bigint;
        v_corr uuid; v_res jsonb; v_kind text;
BEGIN
  SELECT * INTO r FROM public.shout_out_requests WHERE id=p_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('success',false,'error','NOT_FOUND'); END IF;
  PERFORM public.assert_caller(p_fan);
  IF p_fan IS DISTINCT FROM r.fan_id THEN
    RETURN jsonb_build_object('success',false,'error','FAN_MISMATCH'); END IF;
  IF r.status <> 'VIDEO_DELIVERED_TO_FAN' OR r.fan_confirmed_at IS NOT NULL OR r.disputed_at IS NOT NULL THEN
    RETURN jsonb_build_object('success',false,'error','INVALID_STATE'); END IF;

  IF r.free_correction_used_at IS NULL THEN
    -- The fan's ONE free correction round.
    v_kind := 'FREE';
    UPDATE public.shout_out_requests
       SET free_correction_used_at=now(), status='AWAITING_PARTNER_VIDEO', updated_at=now()
     WHERE id=p_id;
    INSERT INTO public.shoutout_corrections (shoutout_id, kind, fee_paise, fan_note)
      VALUES (p_id, 'FREE', 0, p_note);
  ELSE
    -- Every further round is PAID. The correction row, the wallet debit and
    -- the status flip live in one exception block: if the wallet CHECK fires
    -- (insufficient balance), the subtransaction rolls back and NOTHING of
    -- this round persists — no orphan correction row, no state change.
    v_kind := 'PAID';
    SELECT shoutout_correction_fee_paise INTO v_fee FROM public.platform_settings WHERE id=1;
    SELECT id INTO v_wallet FROM public.wallets WHERE profile_id=r.fan_id;
    BEGIN
      INSERT INTO public.shoutout_corrections (shoutout_id, kind, fee_paise, fan_note)
        VALUES (p_id, 'PAID', v_fee, p_note) RETURNING id INTO v_corr;
      v_res := public.post_transaction('SHOUTOUT_DEBIT', v_fee, 'so-corr:'||v_corr::text,
        jsonb_build_array(
          jsonb_build_object('wallet_id',v_wallet,'account','wallet','delta_paise',-v_fee),
          jsonb_build_object('account','booking_escrow','delta_paise',v_fee)),
        v_corr::text);
      UPDATE public.shoutout_corrections SET fee_txn_id=(v_res->>'transaction_id')::uuid WHERE id=v_corr;
      UPDATE public.shout_out_requests SET status='AWAITING_PARTNER_VIDEO', updated_at=now() WHERE id=p_id;
    EXCEPTION WHEN check_violation THEN
      RETURN jsonb_build_object('success',false,'error','INSUFFICIENT_BALANCE');
    END;
  END IF;

  INSERT INTO public.notifications (recipient_id, event_type, title, message, related_entity_type, related_entity_id)
    VALUES (r.partner_id,'SHOUTOUT_VIDEO_NEEDED_PARTNER','Shout-out correction requested',
            COALESCE(p_note,'The fan asked for changes to this shout-out video. Please resubmit.'),'shoutout',p_id);
  RETURN jsonb_build_object('success',true,'kind',v_kind);
END $$;

-- ── 9 · rpc_admin_cancel_shoutout — the ONLY cancellation path. Full refund
--      (price + every paid correction fee) escrow → fan wallet, exactly once
--      per shout-out (idempotency-keyed). Blocked once an earning exists:
--      post-settlement is irreversible by design. ────────────────────────
CREATE OR REPLACE FUNCTION rpc_admin_cancel_shoutout(p_admin uuid, p_id uuid, p_notes text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE r public.shout_out_requests; v_wallet uuid; v_fees bigint; v_total bigint; v_res jsonb;
BEGIN
  PERFORM public.assert_is_admin_actor(p_admin);
  PERFORM public.assert_admin_role('FINANCE','SUPER_ADMIN');
  SELECT * INTO r FROM public.shout_out_requests WHERE id=p_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('success',false,'error','NOT_FOUND'); END IF;
  IF r.status NOT IN ('AWAITING_PARTNER_VIDEO','VIDEO_DELIVERED_TO_FAN','ISSUE_REPORTED_BY_FAN','VIDEO_RECEIVED_BY_ADMIN') THEN
    RETURN jsonb_build_object('success',false,'error','INVALID_STATE','status',r.status); END IF;
  IF EXISTS (SELECT 1 FROM public.partner_earnings e WHERE e.service_id = p_id) THEN
    RETURN jsonb_build_object('success',false,'error','ALREADY_SETTLED'); END IF;

  SELECT COALESCE(sum(c.fee_paise),0) INTO v_fees
    FROM public.shoutout_corrections c WHERE c.shoutout_id=p_id AND c.kind='PAID';
  v_total := r.price_paise + v_fees;
  SELECT id INTO v_wallet FROM public.wallets WHERE profile_id=r.fan_id;
  v_res := public.post_transaction('REFUND', v_total, 'so-cancel:'||r.id::text,
    jsonb_build_array(
      jsonb_build_object('account','booking_escrow','delta_paise',-v_total),
      jsonb_build_object('wallet_id',v_wallet,'account','wallet','delta_paise',v_total)),
    r.id::text);
  UPDATE public.transactions SET refund_reason='DISPUTE' WHERE id=(v_res->>'transaction_id')::uuid;
  UPDATE public.shout_out_requests
     SET status='REFUNDED_BY_ADMIN', admin_review_notes=p_notes, updated_at=now()
   WHERE id=p_id;
  UPDATE public.reports SET status='RESOLVED', resolution=p_notes, resolved_by=p_admin, resolved_at=now()
    WHERE target_type='SHOUTOUT' AND target_id=p_id AND status IN ('PENDING','REVIEWING');
  INSERT INTO public.notifications (recipient_id, event_type, title, message, related_entity_type, related_entity_id)
    VALUES (r.fan_id,'REFUND_PROCESSED_FAN','Shout-out refund processed',
            'Your shout-out was cancelled and the full amount refunded to your wallet.','shoutout',p_id);
  INSERT INTO public.audit_log (actor_id, actor_role, action, target_type, target_id, new_value)
    VALUES (p_admin,'ADMIN','CANCEL_SHOUTOUT','shout_out_request',p_id,
            jsonb_build_object('price_paise',r.price_paise,'paid_correction_fees_paise',v_fees,
                               'total_refund_paise',v_total,'notes',p_notes));
  RETURN jsonb_build_object('success',true,'refunded_paise',v_total);
END $$;

-- ── 10 · rpc_admin_resolve_shoutout_report — REWORK/DISMISS also close the
--       reports rows (mirrors rpc_admin_resolve_report); DISMISS re-anchors
--       the review window and settlement clocks so a dismissed dispute earns
--       a fresh fan review period instead of auto-confirming at once;
--       REFUND delegates to rpc_admin_cancel_shoutout — one money path. ──
CREATE OR REPLACE FUNCTION rpc_admin_resolve_shoutout_report(
  p_admin uuid, p_shoutout uuid, p_action text, p_notes text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE r public.shout_out_requests; v_res jsonb; v_review_days int; v_settle_days int;
BEGIN
  PERFORM public.assert_is_admin_actor(p_admin);
  IF p_action = 'REFUND' THEN
    PERFORM public.assert_admin_role('FINANCE','SUPER_ADMIN');
  END IF;
  SELECT * INTO r FROM public.shout_out_requests WHERE id=p_shoutout FOR UPDATE;
  IF NOT FOUND OR r.status <> 'ISSUE_REPORTED_BY_FAN' THEN
    RETURN jsonb_build_object('success',false,'error','NOT_FLAGGED'); END IF;

  IF p_action = 'REFUND' THEN
    v_res := public.rpc_admin_cancel_shoutout(p_admin, p_shoutout, p_notes);
    IF v_res->>'success' <> 'true' THEN RETURN v_res; END IF;
    INSERT INTO public.audit_log (actor_id, actor_role, action, target_type, target_id, new_value)
      VALUES (p_admin,'ADMIN','RESOLVE_SHOUTOUT_REPORT','shout_out_request',p_shoutout, jsonb_build_object('action','REFUND'));
    RETURN jsonb_build_object('success',true,'refunded',true);
  ELSIF p_action = 'REWORK' THEN
    UPDATE public.shout_out_requests SET status='AWAITING_PARTNER_VIDEO', admin_review_notes=p_notes, updated_at=now() WHERE id=p_shoutout;
    UPDATE public.reports SET status='RESOLVED', resolution=p_notes, resolved_by=p_admin, resolved_at=now()
      WHERE target_type='SHOUTOUT' AND target_id=p_shoutout AND status IN ('PENDING','REVIEWING');
    INSERT INTO public.notifications (recipient_id, event_type, title, message, related_entity_type, related_entity_id)
      VALUES (r.partner_id, 'SHOUTOUT_VIDEO_NEEDED_PARTNER', 'Rework needed',
              COALESCE(p_notes,'Please redo this shout-out video.'), 'shoutout', p_shoutout);
    INSERT INTO public.audit_log (actor_id, actor_role, action, target_type, target_id, new_value)
      VALUES (p_admin,'ADMIN','RESOLVE_SHOUTOUT_REPORT','shout_out_request',p_shoutout, jsonb_build_object('action','REWORK'));
    RETURN jsonb_build_object('success',true,'reworked',true);
  ELSIF p_action = 'DISMISS' THEN
    SELECT shoutout_review_days, settlement_window_days INTO v_review_days, v_settle_days
      FROM public.platform_settings WHERE id=1;
    UPDATE public.shout_out_requests
       SET status='VIDEO_DELIVERED_TO_FAN', admin_review_notes=p_notes,
           review_deadline_at = now() + (v_review_days || ' days')::interval,
           settle_at          = now() + (v_settle_days || ' days')::interval,
           updated_at=now()
     WHERE id=p_shoutout;
    UPDATE public.reports SET status='RESOLVED', resolution=p_notes, resolved_by=p_admin, resolved_at=now()
      WHERE target_type='SHOUTOUT' AND target_id=p_shoutout AND status IN ('PENDING','REVIEWING');
    INSERT INTO public.audit_log (actor_id, actor_role, action, target_type, target_id, new_value)
      VALUES (p_admin,'ADMIN','RESOLVE_SHOUTOUT_REPORT','shout_out_request',p_shoutout, jsonb_build_object('action','DISMISS'));
    RETURN jsonb_build_object('success',true,'dismissed',true);
  ELSE
    RETURN jsonb_build_object('success',false,'error','INVALID_ACTION');
  END IF;
END $$;

-- ── 11 · rpc_admin_deliver_shoutout — REPURPOSED. With direct delivery the
--       admin no longer reviews before the fan sees the video; this is now
--       the admin decision point on a delivered-but-unconfirmed shout-out:
--       approve → FORCE-CONFIRM (the partner will be credited even if the fan
--       is unhappy — the work was submitted properly); reject → admin rework
--       round back to the partner (does NOT consume the fan's free correction). ──
CREATE OR REPLACE FUNCTION rpc_admin_deliver_shoutout(
  p_admin uuid, p_id uuid, p_approve boolean, p_note text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE r public.shout_out_requests;
BEGIN
  PERFORM public.assert_is_admin_actor(p_admin);
  PERFORM public.assert_admin_role('SUPER_ADMIN','SUPPORT','MODERATOR');
  SELECT * INTO r FROM public.shout_out_requests WHERE id=p_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('success',false,'error','NOT_FOUND'); END IF;
  IF r.status NOT IN ('VIDEO_DELIVERED_TO_FAN','ISSUE_REPORTED_BY_FAN') OR r.fan_confirmed_at IS NOT NULL THEN
    RETURN jsonb_build_object('success',false,'error','INVALID_STATE','status',r.status); END IF;

  IF p_approve THEN
    UPDATE public.shout_out_requests
       SET fan_confirmed_at=now(), fan_confirmed_source='ADMIN', admin_confirmed_by=p_admin,
           status='VIDEO_DELIVERED_TO_FAN', admin_handler_id=p_admin,
           admin_review_notes=p_note, updated_at=now()
     WHERE id=p_id;
    UPDATE public.reports SET status='RESOLVED', resolution=p_note, resolved_by=p_admin, resolved_at=now()
      WHERE target_type='SHOUTOUT' AND target_id=p_id AND status IN ('PENDING','REVIEWING');
    INSERT INTO public.notifications (recipient_id, event_type, title, message, related_entity_type, related_entity_id)
      VALUES (r.fan_id,'SHOUTOUT_STATUS_UPDATE_FAN','Your shout-out is confirmed',
              'Your shout-out delivery has been confirmed.','shoutout',p_id);
  ELSE
    UPDATE public.shout_out_requests
       SET status='AWAITING_PARTNER_VIDEO', admin_handler_id=p_admin,
           admin_review_notes=COALESCE(p_note,'Please resubmit the video'), updated_at=now()
     WHERE id=p_id;
    INSERT INTO public.notifications (recipient_id, event_type, title, message, related_entity_type, related_entity_id)
      VALUES (r.partner_id,'SHOUTOUT_VIDEO_NEEDED_PARTNER','Shout-out needs changes',
              COALESCE(p_note,'Your shout-out video was not accepted. Please resubmit.'),'shoutout',p_id);
  END IF;

  INSERT INTO public.audit_log (actor_id, actor_role, action, target_type, target_id, new_value)
    VALUES (p_admin,'ADMIN','DELIVER_SHOUTOUT','shoutout',p_id,
            jsonb_build_object('approved',p_approve,'note',p_note));
  RETURN jsonb_build_object('success',true,'delivered',p_approve);
END $$;

-- ── 12 · rpc_auto_confirm_shoutout — the settle job confirms deliveries the
--       fan never acted on once their review window elapsed. ─────────────
CREATE OR REPLACE FUNCTION rpc_auto_confirm_shoutout(p_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE r public.shout_out_requests;
BEGIN
  PERFORM public.assert_system();   -- settlement sweep job only
  SELECT * INTO r FROM public.shout_out_requests WHERE id=p_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('success',false,'error','NOT_FOUND'); END IF;
  IF r.status <> 'VIDEO_DELIVERED_TO_FAN' OR r.fan_confirmed_at IS NOT NULL
     OR r.review_deadline_at IS NULL OR r.review_deadline_at > now() THEN
    RETURN jsonb_build_object('success',false,'error','NOT_CONFIRMABLE'); END IF;
  UPDATE public.shout_out_requests
     SET fan_confirmed_at=now(), fan_confirmed_source='AUTO', updated_at=now()
   WHERE id=p_id;
  RETURN jsonb_build_object('success',true);
END $$;

-- ── 13 · rpc_admin_update_settings — whitelist the two new knobs ─────────
CREATE OR REPLACE FUNCTION rpc_admin_update_settings(p_patch jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_num numeric;
BEGIN
  PERFORM public.assert_admin_role('SUPER_ADMIN','FINANCE');
  IF p_patch IS NULL OR jsonb_typeof(p_patch) <> 'object' THEN
    RETURN jsonb_build_object('success',false,'error','INVALID_PATCH'); END IF;

  -- Validate anything present. Absent keys are left untouched.
  IF p_patch ? 'gst_rate' THEN
    v_num := (p_patch->>'gst_rate')::numeric;
    IF v_num < 0 OR v_num > 1 THEN RETURN jsonb_build_object('success',false,'error','GST_RATE_OUT_OF_RANGE'); END IF;
  END IF;
  IF p_patch ? 'default_commission_rate' THEN
    v_num := (p_patch->>'default_commission_rate')::numeric;
    IF v_num < 0 OR v_num > 1 THEN RETURN jsonb_build_object('success',false,'error','COMMISSION_OUT_OF_RANGE'); END IF;
  END IF;
  IF p_patch ? 'settlement_window_days' THEN
    v_num := (p_patch->>'settlement_window_days')::numeric;
    IF v_num < 1 OR v_num > 90 THEN RETURN jsonb_build_object('success',false,'error','SETTLEMENT_WINDOW_OUT_OF_RANGE'); END IF;
  END IF;
  IF p_patch ? 'question_sla_hours' THEN
    v_num := (p_patch->>'question_sla_hours')::numeric;
    IF v_num < 1 OR v_num > 720 THEN RETURN jsonb_build_object('success',false,'error','SLA_OUT_OF_RANGE'); END IF;
  END IF;
  IF p_patch ? 'payout_day_of_month' THEN
    v_num := (p_patch->>'payout_day_of_month')::numeric;
    -- 28 is the highest day every month actually has.
    IF v_num < 1 OR v_num > 28 THEN RETURN jsonb_build_object('success',false,'error','PAYOUT_DAY_OUT_OF_RANGE'); END IF;
  END IF;
  IF p_patch ? 'shoutout_correction_fee_paise' THEN
    v_num := (p_patch->>'shoutout_correction_fee_paise')::numeric;
    IF v_num < 0 OR v_num > 10000000 THEN RETURN jsonb_build_object('success',false,'error','CORRECTION_FEE_OUT_OF_RANGE'); END IF;
  END IF;
  IF p_patch ? 'shoutout_review_days' THEN
    v_num := (p_patch->>'shoutout_review_days')::numeric;
    IF v_num < 1 OR v_num > 90 THEN RETURN jsonb_build_object('success',false,'error','REVIEW_DAYS_OUT_OF_RANGE'); END IF;
  END IF;

  UPDATE public.platform_settings SET
    gst_rate                        = COALESCE((p_patch->>'gst_rate')::numeric, gst_rate),
    default_commission_rate         = COALESCE((p_patch->>'default_commission_rate')::numeric, default_commission_rate),
    min_wallet_topup_paise          = COALESCE((p_patch->>'min_wallet_topup_paise')::bigint, min_wallet_topup_paise),
    max_wallet_topup_paise          = COALESCE((p_patch->>'max_wallet_topup_paise')::bigint, max_wallet_topup_paise),
    max_wallet_balance_paise        = COALESCE((p_patch->>'max_wallet_balance_paise')::bigint, max_wallet_balance_paise),
    min_withdrawal_paise            = COALESCE((p_patch->>'min_withdrawal_paise')::bigint, min_withdrawal_paise),
    settlement_window_days          = COALESCE((p_patch->>'settlement_window_days')::int, settlement_window_days),
    question_sla_hours              = COALESCE((p_patch->>'question_sla_hours')::int, question_sla_hours),
    payout_day_of_month             = COALESCE((p_patch->>'payout_day_of_month')::int, payout_day_of_month),
    referral_referrer_reward_paise  = COALESCE((p_patch->>'referral_referrer_reward_paise')::bigint, referral_referrer_reward_paise),
    referral_referee_reward_paise   = COALESCE((p_patch->>'referral_referee_reward_paise')::bigint, referral_referee_reward_paise),
    referral_budget_remaining_paise = COALESCE((p_patch->>'referral_budget_remaining_paise')::bigint, referral_budget_remaining_paise),
    is_referral_program_active      = COALESCE((p_patch->>'is_referral_program_active')::boolean, is_referral_program_active),
    min_service_prices              = COALESCE(p_patch->'min_service_prices', min_service_prices),
    shoutout_correction_fee_paise   = COALESCE((p_patch->>'shoutout_correction_fee_paise')::bigint, shoutout_correction_fee_paise),
    shoutout_review_days            = COALESCE((p_patch->>'shoutout_review_days')::int, shoutout_review_days),
    updated_at = now()
  WHERE id = 1;

  -- Cross-field checks after the write, inside the same transaction, so an
  -- inconsistent pair (min above max) aborts rather than persisting.
  IF EXISTS (SELECT 1 FROM public.platform_settings
              WHERE id=1 AND min_wallet_topup_paise > max_wallet_topup_paise) THEN
    RAISE EXCEPTION 'MIN_TOPUP_ABOVE_MAX';
  END IF;
  IF EXISTS (SELECT 1 FROM public.platform_settings
              WHERE id=1 AND max_wallet_balance_paise IS NOT NULL
                AND max_wallet_balance_paise < max_wallet_topup_paise) THEN
    RAISE EXCEPTION 'BALANCE_CAP_BELOW_MAX_TOPUP';
  END IF;

  RETURN jsonb_build_object('success',true);
END $$;

-- ── 14 · New-function ACLs (CREATE OR REPLACE above preserved the existing
--       grants on the rewritten RPCs). ───────────────────────────────────
REVOKE ALL ON FUNCTION rpc_confirm_shoutout(uuid,uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION rpc_confirm_shoutout(uuid,uuid) TO zudue_app;
REVOKE ALL ON FUNCTION rpc_request_correction(uuid,uuid,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION rpc_request_correction(uuid,uuid,text) TO zudue_app;
REVOKE ALL ON FUNCTION rpc_admin_cancel_shoutout(uuid,uuid,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION rpc_admin_cancel_shoutout(uuid,uuid,text) TO zudue_app;
REVOKE ALL ON FUNCTION rpc_auto_confirm_shoutout(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION rpc_auto_confirm_shoutout(uuid) TO zudue_app;

-- ── 15 · Admin view refresh (DROP + recreate: new columns) ──────────────
DROP VIEW vw_admin_all_shout_outs;
CREATE VIEW vw_admin_all_shout_outs AS
SELECT s.id, s.fan_id, fp.full_name AS fan_name, s.partner_id, pp.display_name AS partner_name,
       s.recipient_name, s.gifter_name, s.occasion, s.price_paise, s.status,
       s.partner_video_storage_path, s.partner_video_submitted_at,
       s.delivered_video_link, s.delivered_at, s.admin_handler_id, s.admin_review_notes,
       EXISTS(SELECT 1 FROM reports r WHERE r.target_type='SHOUTOUT' AND r.target_id = s.id) AS is_reported,
       s.settle_at, s.created_at,
       s.fan_confirmed_at, s.fan_confirmed_source, s.review_deadline_at, s.disputed_at,
       (SELECT COALESCE(sum(c.fee_paise),0) FROM shoutout_corrections c
         WHERE c.shoutout_id = s.id AND c.kind='PAID') AS paid_correction_fees_paise
FROM shout_out_requests s
JOIN profiles fp ON fp.id = s.fan_id
JOIN partner_profiles pp ON pp.profile_id = s.partner_id
WHERE is_admin();
ALTER VIEW vw_admin_all_shout_outs SET (security_invoker = true);
REVOKE ALL ON public.vw_admin_all_shout_outs FROM PUBLIC;
GRANT SELECT ON public.vw_admin_all_shout_outs TO zudue_app;

-- ── 16 · Backfill: the admin offline pre-review is abolished. Legacy
--       VIDEO_RECEIVED_BY_ADMIN rows reopen to their partners, who get
--       notified to resubmit. Legacy rows already VIDEO_DELIVERED_TO_FAN get
--       a review deadline (and a settle date if missing), or their escrow
--       would sit forever: never auto-confirmed, never settled. ──────────
WITH reopened AS (
  UPDATE public.shout_out_requests
     SET status='AWAITING_PARTNER_VIDEO', updated_at=now()
   WHERE status='VIDEO_RECEIVED_BY_ADMIN'
   RETURNING id, partner_id
)
INSERT INTO public.notifications (recipient_id, event_type, title, message, related_entity_type, related_entity_id)
  SELECT partner_id, 'SHOUTOUT_VIDEO_NEEDED_PARTNER', 'Shout-out reopened',
         'Your shout-out video is needed again — please resubmit it.', 'shoutout', id
    FROM reopened;

UPDATE public.shout_out_requests s
   SET review_deadline_at = now() + (ps.shoutout_review_days || ' days')::interval,
       settle_at          = COALESCE(s.settle_at, now() + (ps.settlement_window_days || ' days')::interval)
  FROM public.platform_settings ps
 WHERE ps.id = 1
   AND s.status = 'VIDEO_DELIVERED_TO_FAN'
   AND s.fan_confirmed_at IS NULL
   AND s.review_deadline_at IS NULL;

-- Re-assert the no-overload invariant (0021/0023/0039): a drifted signature in
-- a CREATE OR REPLACE silently ADDS an overload instead of replacing, and two
-- callable versions of a money RPC is precisely the failure this guards.
DO $$
DECLARE v_dupes text;
BEGIN
  SELECT string_agg(DISTINCT p.proname, ', ') INTO v_dupes
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname LIKE 'rpc_%'
  GROUP BY p.proname HAVING count(*) > 1;
  IF v_dupes IS NOT NULL THEN
    RAISE EXCEPTION 'Duplicate RPC overloads detected (fix before deploy): %', v_dupes;
  END IF;
END $$;

INSERT INTO _migrations (name) VALUES ('0061_shoutout_satisfaction_lifecycle.sql')
  ON CONFLICT (name) DO NOTHING;

COMMIT;

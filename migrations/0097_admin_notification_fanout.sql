-- 0097 · Admin alerts reach every capable admin, not one arbitrary inbox.
--
-- WHY
-- Two functions end with:
--   INSERT INTO notifications SELECT p.id, ... FROM profiles p
--     WHERE p.role='ADMIN' LIMIT 1;
-- The INSERT..SELECT is already a fan-out shape; the LIMIT 1 chops it to a
-- single admin, chosen non-deterministically (no ORDER BY). There is no
-- "open disputes" / "open reports" work-queue view in the admin panel -- these
-- notifications ARE the signal that money is being clawed back (Razorpay
-- chargebacks carry a hard response deadline) or a delivered shout-out is
-- disputed. Route that to one admin who may be away / have push off / not be
-- the finance person, and it ages silently.
--
-- It looks harmless only because there is exactly ONE admin today, so LIMIT 1
-- == all admins by accident. It breaks the moment a second admin is added --
-- which is the entire point of the admin_profiles role tiers.
--
--   rpc_record_dispute   -- chargeback recorded (assert_system; webhook path)
--   rpc_report_shoutout  -- a fan flags a delivered shout-out
--
-- FIX
-- Fan out to the admin_role tier that actually handles each event
-- (admin_profiles), keyed on the EVENT row (disputes.id / reports.id) with
-- related_entity_type='system' -- same shape 0095 used, and the same shape
-- rpc_admin_resolve_report already uses for the reporter's own notification.
-- SUPER_ADMIN is in both tiers as the always-present catch-all (bootstrap_admin
-- defaults to it). ON CONFLICT DO NOTHING so a re-fire is idempotent regardless
-- of future status-guard changes.
--
--   dispute (money)      -> FINANCE, SUPER_ADMIN
--   shout-out flag       -> MODERATOR, SUPPORT, SUPER_ADMIN
--
-- Same pass closes the last two notification writers with no ON CONFLICT at
-- all -- rpc_admin_cancel_shoutout and rpc_expire_shoutout both write the fan's
-- REFUND_PROCESSED_FAN row on key (fan, 'REFUND_PROCESSED_FAN', 'shoutout', id).
-- They are status-guard-exclusive today (cancel leaves REFUNDED_BY_ADMIN,
-- expire needs AWAITING_PARTNER_VIDEO and leaves EXPIRED_PARTNER_NO_DELIVERY),
-- so this only makes an emergent invariant explicit. No behaviour change.
--
-- No signature changes -> no GRANT/REVOKE. Client is unaffected: GET
-- /notifications returns id/event_type/title/message/is_read/created_at only;
-- the entity columns are server-only, and 0084's clear-trigger touches only the
-- three VIDEO_CALL_* types, none of them here.
--
-- Live state: 0 disputes, 0 reports ever -- none of this has fired.

BEGIN;

-- ── rpc_record_dispute ──────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.rpc_record_dispute(p_razorpay_dispute_id text, p_razorpay_payment_id text, p_amount_paise bigint, p_reason text DEFAULT NULL::text, p_status dispute_status DEFAULT 'OPEN'::dispute_status)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE v_txn uuid; v_id uuid; v_existing public.disputes;
BEGIN
  PERFORM public.assert_system();
  IF p_razorpay_dispute_id IS NULL OR p_amount_paise IS NULL OR p_amount_paise <= 0 THEN
    RETURN jsonb_build_object('success',false,'error','INVALID_INPUT'); END IF;

  -- Resolve the disputed payment back to our transaction. topup_orders is the
  -- only place a Razorpay payment id is recorded; a dispute for a payment we
  -- cannot match is still worth recording (transaction_id stays NULL) rather
  -- than dropped, so it surfaces for a human instead of vanishing.
  SELECT transaction_id INTO v_txn FROM public.topup_orders
    WHERE razorpay_payment_id = p_razorpay_payment_id;

  SELECT * INTO v_existing FROM public.disputes
    WHERE razorpay_dispute_id = p_razorpay_dispute_id FOR UPDATE;

  IF FOUND THEN
    -- Lifecycle update (created -> under review -> won/lost/closed).
    UPDATE public.disputes
       SET status = p_status,
           reason = COALESCE(p_reason, reason),
           transaction_id = COALESCE(transaction_id, v_txn),
           resolved_at = CASE WHEN p_status IN ('WON','LOST','CLOSED') THEN now() ELSE resolved_at END
     WHERE id = v_existing.id;
    RETURN jsonb_build_object('success',true,'dispute_id',v_existing.id,'updated',true);
  END IF;

  INSERT INTO public.disputes (transaction_id, razorpay_dispute_id, amount_paise, reason, status)
    VALUES (v_txn, p_razorpay_dispute_id, p_amount_paise, p_reason, p_status)
    RETURNING id INTO v_id;

  -- Chargebacks are money leaving without our initiation; make them loud -- to
  -- every finance-capable admin, keyed on the dispute row (0097).
  INSERT INTO public.notifications (recipient_id, event_type, title, message, related_entity_type, related_entity_id)
    SELECT ap.profile_id, 'PLATFORM_ANNOUNCEMENT', 'Payment dispute opened',
           'A chargeback was raised on a payment. Review it in the admin panel.', 'system', v_id
      FROM public.admin_profiles ap
      JOIN public.profiles p ON p.id = ap.profile_id AND p.role = 'ADMIN'
     WHERE ap.admin_role = ANY (ARRAY['FINANCE','SUPER_ADMIN']::public.admin_role[])
  ON CONFLICT (recipient_id, event_type, related_entity_type, related_entity_id) DO NOTHING;

  RETURN jsonb_build_object('success',true,'dispute_id',v_id,'created',true);
END $function$;

-- ── rpc_report_shoutout ─────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.rpc_report_shoutout(p_id uuid, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE r public.shout_out_requests; v_report_id uuid;
BEGIN
  SELECT * INTO r FROM public.shout_out_requests WHERE id=p_id FOR UPDATE;
  IF NOT FOUND OR r.status<>'VIDEO_DELIVERED_TO_FAN' OR r.fan_confirmed_at IS NOT NULL THEN
    RETURN jsonb_build_object('success',false,'error','NOT_REPORTABLE'); END IF;
  PERFORM public.assert_caller(r.fan_id);
  UPDATE public.shout_out_requests
     SET status='ISSUE_REPORTED_BY_FAN', disputed_at=now(), updated_at=now()
   WHERE id=p_id;
  INSERT INTO public.reports (reporter_id, target_type, target_id, reason)
    VALUES (r.fan_id, 'SHOUTOUT', p_id, p_reason)
    RETURNING id INTO v_report_id;

  -- Every moderation-capable admin, keyed on the report row (0097).
  INSERT INTO public.notifications (recipient_id, event_type, title, message, related_entity_type, related_entity_id)
    SELECT ap.profile_id, 'PLATFORM_ANNOUNCEMENT', 'Shout-out flagged',
           'A delivered shout-out was reported and needs review.', 'system', v_report_id
      FROM public.admin_profiles ap
      JOIN public.profiles p ON p.id = ap.profile_id AND p.role = 'ADMIN'
     WHERE ap.admin_role = ANY (ARRAY['MODERATOR','SUPPORT','SUPER_ADMIN']::public.admin_role[])
  ON CONFLICT (recipient_id, event_type, related_entity_type, related_entity_id) DO NOTHING;

  RETURN jsonb_build_object('success',true);
END $function$;

-- ── rpc_admin_cancel_shoutout  (add the missing ON CONFLICT; no other change) ─
CREATE OR REPLACE FUNCTION public.rpc_admin_cancel_shoutout(p_admin uuid, p_id uuid, p_notes text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
            'Your shout-out was cancelled and the full amount refunded to your wallet.','shoutout',p_id)
  ON CONFLICT (recipient_id, event_type, related_entity_type, related_entity_id) DO NOTHING;
  INSERT INTO public.audit_log (actor_id, actor_role, action, target_type, target_id, new_value)
    VALUES (p_admin,'ADMIN','CANCEL_SHOUTOUT','shout_out_request',p_id,
            jsonb_build_object('price_paise',r.price_paise,'paid_correction_fees_paise',v_fees,
                               'total_refund_paise',v_total,'notes',p_notes));
  RETURN jsonb_build_object('success',true,'refunded_paise',v_total);
END $function$;

-- ── rpc_expire_shoutout  (add the missing ON CONFLICT; no other change) ──────
CREATE OR REPLACE FUNCTION public.rpc_expire_shoutout(p_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  s public.shout_out_requests;
  v_wallet uuid;
  v_res jsonb;
BEGIN
  PERFORM public.assert_system();  -- settlement sweep job only
  SELECT * INTO s FROM public.shout_out_requests WHERE id=p_id FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('success',false,'error','NOT_FOUND');
  END IF;

  -- Only expire if still awaiting delivery past settle_at
  IF s.status <> 'AWAITING_PARTNER_VIDEO' OR s.settle_at > now() THEN
    RETURN jsonb_build_object('success',false,'error','NOT_EXPIRABLE');
  END IF;

  -- Idempotency check - if already refunded, exit cleanly
  IF EXISTS (
    SELECT 1 FROM public.transactions t
    WHERE t.idempotency_key = 'so-expire:' || s.id::text
  ) THEN
    RETURN jsonb_build_object('success',true,'already_refunded',true);
  END IF;

  -- Full refund to fan
  SELECT id INTO v_wallet FROM public.wallets WHERE profile_id=s.fan_id;
  IF v_wallet IS NULL THEN
    RAISE EXCEPTION 'Wallet not found for fan %', s.fan_id;
  END IF;

  v_res := public.post_transaction('REFUND', s.price_paise, 'so-expire:'||s.id::text,
    jsonb_build_array(
      jsonb_build_object('account','booking_escrow','delta_paise',-s.price_paise),
      jsonb_build_object('wallet_id',v_wallet,'account','wallet','delta_paise',s.price_paise)),
    s.id::text);

  UPDATE public.shout_out_requests
     SET status='EXPIRED_PARTNER_NO_DELIVERY', updated_at=now()
   WHERE id=p_id;

  -- Notify fan of refund
  INSERT INTO public.notifications (recipient_id, event_type, title, message, related_entity_type, related_entity_id)
    VALUES (s.fan_id,'REFUND_PROCESSED_FAN','Shout-out refunded',
            'Your shout-out request was not delivered and has been refunded to your wallet.','shoutout',p_id)
  ON CONFLICT (recipient_id, event_type, related_entity_type, related_entity_id) DO NOTHING;

  RETURN jsonb_build_object('success',true,'refunded_paise',s.price_paise,'transaction_id',v_res->>'transaction_id');
END $function$;

INSERT INTO _migrations (name) VALUES ('0097_admin_notification_fanout.sql') ON CONFLICT (name) DO NOTHING;

COMMIT;

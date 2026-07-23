-- 0017 · Shout-out flow (auto-deliver + exception flag) and the payout batch
-- (both integrity bugs fixed: reject releases earnings; amount = exactly Σ earnings).

BEGIN;

-- Fan requests a shout-out → escrow the price, create request AWAITING_PARTNER_VIDEO.
CREATE OR REPLACE FUNCTION rpc_request_shoutout(
  p_fan uuid, p_partner uuid, p_recipient text, p_message text, p_price_paise bigint)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_wallet uuid; v_id uuid; v_res jsonb;
BEGIN
  IF public.is_blocked(p_fan, p_partner) THEN
    RETURN jsonb_build_object('success',false,'error','BLOCKED'); END IF;
  SELECT id INTO v_wallet FROM public.wallets WHERE profile_id=p_fan;
  v_id := gen_random_uuid();
  v_res := public.post_transaction('SHOUTOUT_DEBIT', p_price_paise, 'so:'||v_id::text,
    jsonb_build_array(
      jsonb_build_object('wallet_id',v_wallet,'account','wallet','delta_paise',-p_price_paise),
      jsonb_build_object('account','booking_escrow','delta_paise',p_price_paise)),
    v_id::text);
  INSERT INTO public.shout_out_requests (id, fan_id, partner_id, recipient_name, message_for_partner,
      price_paise, status, escrow_txn_id, settle_at)
    VALUES (v_id, p_fan, p_partner, p_recipient, p_message, p_price_paise, 'AWAITING_PARTNER_VIDEO',
      (v_res->>'transaction_id')::uuid, now()+interval '7 days');
  RETURN jsonb_build_object('success',true,'shoutout_id',v_id);
END $$;

-- Partner uploads video → AUTO-DELIVER to fan (no admin gate).
CREATE OR REPLACE FUNCTION rpc_upload_shoutout(p_id uuid, p_video_path text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  UPDATE public.shout_out_requests
     SET partner_video_storage_path=p_video_path, partner_video_submitted_at=now(),
         delivered_video_link=p_video_path, delivered_at=now(),
         status='VIDEO_DELIVERED_TO_FAN', updated_at=now()
   WHERE id=p_id AND status='AWAITING_PARTNER_VIDEO';
  IF NOT FOUND THEN RETURN jsonb_build_object('success',false,'error','INVALID_STATE'); END IF;
  RETURN jsonb_build_object('success',true,'delivered',true);
END $$;

-- Fan flags a delivered shout-out → exception path, admin notified.
CREATE OR REPLACE FUNCTION rpc_report_shoutout(p_id uuid, p_reason text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE r public.shout_out_requests;
BEGIN
  SELECT * INTO r FROM public.shout_out_requests WHERE id=p_id FOR UPDATE;
  IF NOT FOUND OR r.status<>'VIDEO_DELIVERED_TO_FAN' THEN
    RETURN jsonb_build_object('success',false,'error','NOT_REPORTABLE'); END IF;
  UPDATE public.shout_out_requests SET status='ISSUE_REPORTED_BY_FAN', updated_at=now() WHERE id=p_id;
  INSERT INTO public.reports (reporter_id, target_type, target_id, reason)
    VALUES (r.fan_id, 'SHOUTOUT', p_id, p_reason);
  INSERT INTO public.notifications (recipient_id, event_type, title, message, related_entity_type, related_entity_id)
    SELECT p.id, 'PLATFORM_ANNOUNCEMENT', 'Shout-out flagged', 'A delivered shout-out was reported.', 'shoutout', p_id
    FROM public.profiles p WHERE p.role='ADMIN' LIMIT 1;
  RETURN jsonb_build_object('success',true);
END $$;

-- ── Payout batch (fixes: reject releases earnings; amount = exactly Σ marked) ──
CREATE OR REPLACE FUNCTION rpc_create_payout_batch(p_partner uuid, p_method uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_sum bigint; v_payout uuid;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.payout_methods WHERE id=p_method AND partner_id=p_partner AND is_verified) THEN
    RETURN jsonb_build_object('success',false,'error','UNVERIFIED_METHOD'); END IF;
  -- amount = EXACTLY the sum of eligible (settled, past window) PENDING earnings
  SELECT COALESCE(sum(amount_paise),0) INTO v_sum FROM public.partner_earnings
    WHERE partner_id=p_partner AND status='PENDING_PAYOUT';
  IF v_sum = 0 THEN RETURN jsonb_build_object('success',false,'error','NOTHING_TO_PAY'); END IF;

  INSERT INTO public.partner_payouts (partner_id, amount_paise, status, payout_method_id)
    VALUES (p_partner, v_sum, 'REQUESTED', p_method) RETURNING id INTO v_payout;
  UPDATE public.partner_earnings SET status='INCLUDED_IN_PAYOUT', payout_id=v_payout
    WHERE partner_id=p_partner AND status='PENDING_PAYOUT';
  RETURN jsonb_build_object('success',true,'payout_id',v_payout,'amount_paise',v_sum);
END $$;

CREATE OR REPLACE FUNCTION rpc_process_payout(p_payout uuid, p_approve boolean, p_reference text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE po public.partner_payouts; v_res jsonb;
BEGIN
  SELECT * INTO po FROM public.partner_payouts WHERE id=p_payout FOR UPDATE;
  IF NOT FOUND OR po.status NOT IN ('REQUESTED','APPROVED') THEN
    RETURN jsonb_build_object('success',false,'error','INVALID_STATE'); END IF;

  IF p_approve THEN
    v_res := public.post_transaction('PAYOUT_DEBIT', po.amount_paise, 'payout:'||po.id::text,
      jsonb_build_array(
        jsonb_build_object('account','partner_payable','delta_paise',-po.amount_paise),
        jsonb_build_object('account','razorpay_clearing','delta_paise',po.amount_paise)),
      po.id::text);
    UPDATE public.partner_payouts SET status='PAID', reference=p_reference, transaction_id=(v_res->>'transaction_id')::uuid, processed_at=now() WHERE id=p_payout;
    UPDATE public.partner_earnings SET status='PAID' WHERE payout_id=p_payout;
    RETURN jsonb_build_object('success',true,'status','PAID');
  ELSE
    -- REJECT → release the earnings back so they can be paid later (bug fixed)
    UPDATE public.partner_payouts SET status='REJECTED', processed_at=now() WHERE id=p_payout;
    UPDATE public.partner_earnings SET status='PENDING_PAYOUT', payout_id=NULL WHERE payout_id=p_payout;
    RETURN jsonb_build_object('success',true,'status','REJECTED','earnings_released',true);
  END IF;
END $$;

REVOKE ALL ON FUNCTION rpc_create_payout_batch(uuid,uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION rpc_process_payout(uuid,boolean,text) FROM PUBLIC;

COMMIT;

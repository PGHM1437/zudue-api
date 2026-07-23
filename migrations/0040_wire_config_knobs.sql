-- 0040 · Make platform_settings actually configure things.
--
-- The audit found platform_settings carries 23 tunables of which 14 are never
-- read anywhere. Two of them are not merely unused but actively misleading:
--   settlement_window_days (DEFAULT 7)  — three RPCs hardcode interval '7 days'
--   question_sla_hours     (DEFAULT 48) — one RPC hardcodes interval '48 hours'
-- An operator changing either value in the database today would see no effect
-- whatsoever. That is worse than having no knob at all.
--
-- This migration points those four call sites at the settings row. It is
-- deliberately BEHAVIOUR-PRESERVING: both databases were checked first and
-- already hold 7 and 48, so every computed deadline is identical the moment
-- this lands. Only the ability to change them differs.
--
-- The three function bodies below were not retyped. They were dumped from the
-- live database with pg_get_functiondef, transformed mechanically, and diffed:
-- exactly 4 lines differ in total (1 + 2 + 1), all of them the interval
-- expressions. Everything else is byte-identical to what is running now. That
-- matters because these are money RPCs — escrow debits and settlement dates.
--
-- CREATE OR REPLACE preserves existing ACLs, so the 0021/0023/0034 REVOKE and
-- GRANT statements for these functions continue to apply unchanged.
--
-- The remaining 12 unused knobs are left alone: wiring them (booking_lead_days,
-- min_withdrawal_paise, call_operational_*_hour_ist, etc.) would introduce NEW
-- business rules — rejecting bookings, blocking withdrawals — not preserve
-- existing behaviour. Those are product decisions, not cleanup.

BEGIN;

CREATE OR REPLACE FUNCTION public.rpc_book_video_call(p_fan uuid, p_partner uuid, p_date date, p_duration call_duration_options_enum, p_note text DEFAULT NULL::text, p_promo_code text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE v_wallet uuid; v_avail public.availability; v_mins int; v_booking uuid; v_res jsonb;
        v_premium boolean; v_kyc public.verification_status; v_partner_status public.account_status;
        v_price jsonb; v_final bigint;
BEGIN
  PERFORM public.assert_caller(p_fan);
  PERFORM public.assert_active(p_fan);
  SELECT status, is_premium INTO v_partner_status, v_premium FROM public.partner_profiles WHERE profile_id=p_partner;
  IF v_partner_status IS DISTINCT FROM 'ACTIVE' THEN
    RETURN jsonb_build_object('success',false,'error','PARTNER_NOT_ACTIVE'); END IF;
  IF v_premium THEN
    SELECT verification_status INTO v_kyc FROM public.profiles WHERE id=p_fan;
    IF v_kyc IS DISTINCT FROM 'VERIFIED' THEN
      RETURN jsonb_build_object('success',false,'error','KYC_REQUIRED'); END IF;
  END IF;
  v_price := public.resolve_price(p_partner,'VIDEO_CALL',p_duration,p_promo_code,p_fan);
  IF v_price ? 'error' THEN RETURN jsonb_build_object('success',false,'error',v_price->>'error'); END IF;
  v_final := (v_price->>'final_paise')::bigint;
  v_mins := (p_duration::text)::int;
  SELECT * INTO v_avail FROM public.availability WHERE partner_id=p_partner AND date=p_date FOR UPDATE;
  IF NOT FOUND OR NOT v_avail.is_available THEN
    RETURN jsonb_build_object('success',false,'error','NOT_AVAILABLE'); END IF;
  IF v_avail.booked_minutes + v_mins > v_avail.threshold_minutes THEN
    RETURN jsonb_build_object('success',false,'error','NO_CAPACITY'); END IF;
  SELECT id INTO v_wallet FROM public.wallets WHERE profile_id=p_fan;
  v_booking := gen_random_uuid();
  v_res := public.post_transaction('BOOKING_DEBIT', v_final, 'book:'||v_booking::text,
    jsonb_build_array(
      jsonb_build_object('wallet_id',v_wallet,'account','wallet','delta_paise',-v_final),
      jsonb_build_object('account','booking_escrow','delta_paise',v_final)),
    v_booking::text);
  INSERT INTO public.bookings (id, fan_id, partner_id, scheduled_date, selected_duration,
    price_paise, original_price_paise, discount_paise, promo_code_id, status, fan_note, escrow_txn_id, settle_at)
  VALUES (v_booking, p_fan, p_partner, p_date, p_duration, v_final,
    (v_price->>'base_paise')::bigint, (v_price->>'discount_paise')::bigint,
    (v_price->>'promo_id')::uuid, 'BOOKED', p_note, (v_res->>'transaction_id')::uuid, now()+((SELECT settlement_window_days FROM public.platform_settings WHERE id=1) * interval '1 day'));
  UPDATE public.availability SET booked_minutes = booked_minutes + v_mins, updated_at=now() WHERE id = v_avail.id;
  IF p_promo_code IS NOT NULL AND (v_price->>'promo_id') IS NOT NULL THEN
    INSERT INTO public.promo_code_usages (promo_code_id, fan_id, transaction_id, discount_paise)
      VALUES ((v_price->>'promo_id')::uuid, p_fan, (v_res->>'transaction_id')::uuid, (v_price->>'discount_paise')::bigint);
    UPDATE public.promo_codes SET current_total_uses = current_total_uses+1 WHERE id=(v_price->>'promo_id')::uuid;
  END IF;
  RETURN jsonb_build_object('success',true,'booking_id',v_booking,'price_paise',v_final);
END $function$
;

CREATE OR REPLACE FUNCTION public.rpc_ask_question(p_fan uuid, p_partner uuid, p_text text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE v_conv uuid; v_win public.conversation_windows; v_wallet uuid;
        v_count int; v_any_window boolean; v_new_win uuid; v_res jsonb;
        v_premium boolean; v_kyc public.verification_status; v_price bigint;
BEGIN
  PERFORM public.assert_caller(p_fan);
  PERFORM public.assert_active(p_fan);
  IF public.is_blocked(p_fan, p_partner, 'DM') THEN
    RETURN jsonb_build_object('success',false,'error','BLOCKED'); END IF;
  SELECT is_premium INTO v_premium FROM public.partner_profiles WHERE profile_id=p_partner;
  IF v_premium THEN
    SELECT verification_status INTO v_kyc FROM public.profiles WHERE id=p_fan;
    IF v_kyc IS DISTINCT FROM 'VERIFIED' THEN
      RETURN jsonb_build_object('success',false,'error','KYC_REQUIRED'); END IF;
  END IF;
  SELECT id INTO v_conv FROM public.conversations WHERE fan_id=p_fan AND partner_id=p_partner;
  IF v_conv IS NULL THEN
    INSERT INTO public.conversations (fan_id, partner_id) VALUES (p_fan, p_partner) RETURNING id INTO v_conv;
  END IF;
  SELECT * INTO v_win FROM public.conversation_windows
    WHERE conversation_id=v_conv AND status='OPEN' ORDER BY opened_at DESC LIMIT 1 FOR UPDATE;
  IF FOUND THEN
    SELECT count(*) INTO v_count FROM public.messages m WHERE m.window_id=v_win.id AND m.sender='FAN';
    IF v_count >= v_win.message_cap THEN
      RETURN jsonb_build_object('success',false,'error','WINDOW_LIMIT'); END IF;
    INSERT INTO public.messages (window_id, sender, body) VALUES (v_win.id,'FAN',p_text);
    UPDATE public.conversations SET last_activity_at=now() WHERE id=v_conv;
    RETURN jsonb_build_object('success',true,'window_id',v_win.id,'kind',v_win.kind,'charged',false);
  END IF;
  SELECT EXISTS(SELECT 1 FROM public.conversation_windows WHERE conversation_id=v_conv) INTO v_any_window;
  v_new_win := gen_random_uuid();
  IF NOT v_any_window THEN
    INSERT INTO public.conversation_windows (id, conversation_id, kind, charge_paise, status)
      VALUES (v_new_win, v_conv, 'FREE', 0, 'OPEN');
  ELSE
    SELECT price_paise INTO v_price FROM public.partner_services
      WHERE partner_id=p_partner AND service_type='QUICK_QUESTION' AND duration IS NULL AND is_active;
    IF v_price IS NULL THEN RETURN jsonb_build_object('success',false,'error','SERVICE_NOT_OFFERED'); END IF;
    SELECT id INTO v_wallet FROM public.wallets WHERE profile_id=p_fan;
    v_res := public.post_transaction('QUESTION_DEBIT', v_price, 'qq:'||v_new_win::text,
      jsonb_build_array(
        jsonb_build_object('wallet_id',v_wallet,'account','wallet','delta_paise',-v_price),
        jsonb_build_object('account','booking_escrow','delta_paise',v_price)),
      v_new_win::text);
    INSERT INTO public.conversation_windows (id, conversation_id, kind, charge_paise, status,
        response_deadline, escrow_txn_id, settle_at)
      VALUES (v_new_win, v_conv, 'PAID', v_price, 'OPEN', now()+((SELECT question_sla_hours FROM public.platform_settings WHERE id=1) * interval '1 hour'),
        (v_res->>'transaction_id')::uuid, now()+((SELECT settlement_window_days FROM public.platform_settings WHERE id=1) * interval '1 day'));
  END IF;
  INSERT INTO public.messages (window_id, sender, body) VALUES (v_new_win,'FAN',p_text);
  UPDATE public.conversations SET last_activity_at=now() WHERE id=v_conv;
  RETURN jsonb_build_object('success',true,'window_id',v_new_win,
    'kind', CASE WHEN v_any_window THEN 'PAID' ELSE 'FREE' END, 'charged', v_any_window);
END $function$
;

CREATE OR REPLACE FUNCTION public.rpc_request_shoutout(p_fan uuid, p_partner uuid, p_recipient text, p_message text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE v_wallet uuid; v_id uuid; v_res jsonb; v_price bigint;
        v_premium boolean; v_kyc public.verification_status;
BEGIN
  PERFORM public.assert_caller(p_fan);
  PERFORM public.assert_active(p_fan);
  IF public.is_blocked(p_fan, p_partner) THEN
    RETURN jsonb_build_object('success',false,'error','BLOCKED'); END IF;
  SELECT is_premium INTO v_premium FROM public.partner_profiles WHERE profile_id=p_partner;
  IF v_premium THEN
    SELECT verification_status INTO v_kyc FROM public.profiles WHERE id=p_fan;
    IF v_kyc IS DISTINCT FROM 'VERIFIED' THEN
      RETURN jsonb_build_object('success',false,'error','KYC_REQUIRED'); END IF;
  END IF;
  SELECT price_paise INTO v_price FROM public.partner_services
    WHERE partner_id=p_partner AND service_type='SHOUT_OUT' AND duration IS NULL AND is_active;
  IF v_price IS NULL THEN RETURN jsonb_build_object('success',false,'error','SERVICE_NOT_OFFERED'); END IF;
  SELECT id INTO v_wallet FROM public.wallets WHERE profile_id=p_fan;
  v_id := gen_random_uuid();
  v_res := public.post_transaction('SHOUTOUT_DEBIT', v_price, 'so:'||v_id::text,
    jsonb_build_array(
      jsonb_build_object('wallet_id',v_wallet,'account','wallet','delta_paise',-v_price),
      jsonb_build_object('account','booking_escrow','delta_paise',v_price)),
    v_id::text);
  INSERT INTO public.shout_out_requests (id, fan_id, partner_id, recipient_name, message_for_partner,
      price_paise, status, escrow_txn_id, settle_at)
    VALUES (v_id, p_fan, p_partner, p_recipient, p_message, v_price, 'AWAITING_PARTNER_VIDEO',
      (v_res->>'transaction_id')::uuid, now()+((SELECT settlement_window_days FROM public.platform_settings WHERE id=1) * interval '1 day'));
  RETURN jsonb_build_object('success',true,'shoutout_id',v_id,'price_paise',v_price);
END $function$
;

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

COMMIT;

-- 0021 · Close the gaps found by adversarial audit (account-status enforcement,
-- KYC gate on all paid services, real shoutout refund, promo wiring, server-side
-- price validation, partner-active gate, bounded referral budget).

BEGIN;

-- ── Helper: is this profile allowed to transact? ──
CREATE OR REPLACE FUNCTION assert_active(p_profile uuid)
RETURNS void LANGUAGE plpgsql STABLE SET search_path = '' AS $$
DECLARE v_status public.user_account_status;
BEGIN
  SELECT account_status INTO v_status FROM public.profiles WHERE id=p_profile;
  IF v_status IS DISTINCT FROM 'ACTIVE' THEN
    RAISE EXCEPTION 'ACCOUNT_NOT_ACTIVE' USING ERRCODE = 'P0001';
  END IF;
END $$;

-- Bounded referral budget (fixes the phantom unbounded account).
ALTER TABLE platform_settings
  ADD COLUMN IF NOT EXISTS referral_budget_remaining_paise bigint NOT NULL DEFAULT 0;

-- ── Server-validated price + promo lookup (shared by all three service RPCs) ──
CREATE OR REPLACE FUNCTION resolve_price(
  p_partner uuid, p_type service_type_enum, p_duration call_duration_options_enum,
  p_promo_code text, p_fan uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_base bigint; v_promo public.promo_codes; v_final bigint; v_discount bigint := 0;
BEGIN
  SELECT price_paise INTO v_base FROM public.partner_services
    WHERE partner_id=p_partner AND service_type=p_type
      AND duration IS NOT DISTINCT FROM p_duration AND is_active;
  IF v_base IS NULL THEN RETURN jsonb_build_object('error','SERVICE_NOT_OFFERED'); END IF;
  v_final := v_base;

  IF p_promo_code IS NOT NULL THEN
    SELECT * INTO v_promo FROM public.promo_codes
      WHERE code=upper(p_promo_code) AND is_active
        AND (expiry_date IS NULL OR expiry_date > now())
        AND (start_date IS NULL OR start_date <= now())
        AND (applies_to='ALL' OR applies_to::text=p_type::text)
        AND (max_uses_total IS NULL OR current_total_uses < max_uses_total);
    IF FOUND THEN
      IF v_promo.max_uses_per_user IS NOT NULL AND
         (SELECT count(*) FROM public.promo_code_usages WHERE promo_code_id=v_promo.id AND fan_id=p_fan) >= v_promo.max_uses_per_user
      THEN
        RETURN jsonb_build_object('error','PROMO_LIMIT_REACHED');
      END IF;
      v_discount := CASE v_promo.discount_type
        WHEN 'PERCENTAGE' THEN round(v_base * v_promo.discount_value / 100)
        ELSE least(v_promo.discount_value::bigint, v_base) END;
      v_final := v_base - v_discount;   -- platform-funded: partner still settles v_base
    ELSE
      RETURN jsonb_build_object('error','INVALID_PROMO');
    END IF;
  END IF;

  RETURN jsonb_build_object('base_paise',v_base,'discount_paise',v_discount,'final_paise',v_final,
    'promo_id', CASE WHEN p_promo_code IS NOT NULL THEN v_promo.id END);
END $$;

-- ── Booking: rebuilt with account-status, server-priced, promo-aware ──
CREATE OR REPLACE FUNCTION rpc_book_video_call(
  p_fan uuid, p_partner uuid, p_date date, p_duration call_duration_options_enum,
  p_note text DEFAULT NULL, p_promo_code text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_wallet uuid; v_avail public.availability; v_mins int; v_booking uuid; v_res jsonb;
        v_premium boolean; v_kyc public.verification_status; v_partner_status public.account_status;
        v_price jsonb; v_final bigint;
BEGIN
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
    (v_price->>'promo_id')::uuid, 'BOOKED', p_note, (v_res->>'transaction_id')::uuid, now()+interval '7 days');
  UPDATE public.availability SET booked_minutes = booked_minutes + v_mins, updated_at=now() WHERE id = v_avail.id;
  IF p_promo_code IS NOT NULL AND (v_price->>'promo_id') IS NOT NULL THEN
    INSERT INTO public.promo_code_usages (promo_code_id, fan_id, transaction_id, discount_paise)
      VALUES ((v_price->>'promo_id')::uuid, p_fan, (v_res->>'transaction_id')::uuid, (v_price->>'discount_paise')::bigint);
    UPDATE public.promo_codes SET current_total_uses = current_total_uses+1 WHERE id=(v_price->>'promo_id')::uuid;
  END IF;
  RETURN jsonb_build_object('success',true,'booking_id',v_booking,'price_paise',v_final);
END $$;

-- ── Ask question: account-status + KYC-for-premium + server price (promo N/A to free windows) ──
CREATE OR REPLACE FUNCTION rpc_ask_question(p_fan uuid, p_partner uuid, p_text text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_conv uuid; v_win public.conversation_windows; v_wallet uuid;
        v_count int; v_any_window boolean; v_new_win uuid; v_res jsonb;
        v_premium boolean; v_kyc public.verification_status; v_price bigint;
BEGIN
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
      VALUES (v_new_win, v_conv, 'PAID', v_price, 'OPEN', now()+interval '48 hours',
        (v_res->>'transaction_id')::uuid, now()+interval '7 days');
  END IF;
  INSERT INTO public.messages (window_id, sender, body) VALUES (v_new_win,'FAN',p_text);
  UPDATE public.conversations SET last_activity_at=now() WHERE id=v_conv;
  RETURN jsonb_build_object('success',true,'window_id',v_new_win,
    'kind', CASE WHEN v_any_window THEN 'PAID' ELSE 'FREE' END, 'charged', v_any_window);
END $$;

-- ── Shout-out: account-status + KYC + server price ──
CREATE OR REPLACE FUNCTION rpc_request_shoutout(
  p_fan uuid, p_partner uuid, p_recipient text, p_message text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_wallet uuid; v_id uuid; v_res jsonb; v_price bigint;
        v_premium boolean; v_kyc public.verification_status;
BEGIN
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
      (v_res->>'transaction_id')::uuid, now()+interval '7 days');
  RETURN jsonb_build_object('success',true,'shoutout_id',v_id,'price_paise',v_price);
END $$;

-- ── Shout-out report: NOW actually offers a real refund path (admin-executed) ──
CREATE OR REPLACE FUNCTION rpc_admin_resolve_shoutout_report(
  p_admin uuid, p_shoutout uuid, p_action text, p_notes text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE r public.shout_out_requests; v_wallet uuid; v_res jsonb;
BEGIN
  SELECT * INTO r FROM public.shout_out_requests WHERE id=p_shoutout FOR UPDATE;
  IF NOT FOUND OR r.status <> 'ISSUE_REPORTED_BY_FAN' THEN
    RETURN jsonb_build_object('success',false,'error','NOT_FLAGGED'); END IF;

  IF p_action = 'REFUND' THEN
    IF now() > r.settle_at THEN
      RETURN jsonb_build_object('success',false,'error','PAST_REFUND_WINDOW'); END IF;
    SELECT id INTO v_wallet FROM public.wallets WHERE profile_id=r.fan_id;
    v_res := public.post_transaction('REFUND', r.price_paise, 'so-refund:'||r.id::text,
      jsonb_build_array(
        jsonb_build_object('account','booking_escrow','delta_paise',-r.price_paise),
        jsonb_build_object('wallet_id',v_wallet,'account','wallet','delta_paise',r.price_paise)),
      r.id::text);
    UPDATE public.transactions SET refund_reason='DISPUTE' WHERE id=(v_res->>'transaction_id')::uuid;
    UPDATE public.shout_out_requests SET status='REFUNDED_BY_ADMIN', admin_review_notes=p_notes, updated_at=now() WHERE id=p_shoutout;
    RETURN jsonb_build_object('success',true,'refunded',true);
  ELSIF p_action = 'REWORK' THEN
    UPDATE public.shout_out_requests SET status='AWAITING_PARTNER_VIDEO', admin_review_notes=p_notes, updated_at=now() WHERE id=p_shoutout;
    INSERT INTO public.notifications (recipient_id, event_type, title, message, related_entity_type, related_entity_id)
      VALUES (r.partner_id, 'SHOUTOUT_VIDEO_NEEDED_PARTNER', 'Rework needed',
              COALESCE(p_notes,'Please redo this shout-out video.'), 'shoutout', p_shoutout);
    RETURN jsonb_build_object('success',true,'reworked',true);
  ELSE -- DISMISS
    UPDATE public.shout_out_requests SET status='VIDEO_DELIVERED_TO_FAN', admin_review_notes=p_notes, updated_at=now() WHERE id=p_shoutout;
    RETURN jsonb_build_object('success',true,'dismissed',true);
  END IF;
END $$;

-- ── Referral crediting: BOUNDED by a real budget, no phantom liability ──
CREATE OR REPLACE FUNCTION rpc_credit_referral(p_referee uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE r public.referrals; v_referrer_amt bigint; v_referee_amt bigint;
        v_rw uuid; v_ew uuid; v_budget bigint; v_total bigint;
BEGIN
  SELECT * INTO r FROM public.referrals WHERE referee_id=p_referee AND status <> 'COMPLETED_REWARDED' FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('success',false,'error','NO_PENDING_REFERRAL'); END IF;

  SELECT referral_referrer_reward_paise, referral_referee_reward_paise, referral_budget_remaining_paise
    INTO v_referrer_amt, v_referee_amt, v_budget FROM public.platform_settings WHERE id=1 FOR UPDATE;
  v_total := v_referrer_amt + COALESCE(v_referee_amt,0);
  IF v_budget < v_total THEN
    RETURN jsonb_build_object('success',false,'error','REFERRAL_BUDGET_EXHAUSTED'); END IF;

  SELECT id INTO v_rw FROM public.wallets WHERE profile_id=r.referrer_id;
  SELECT id INTO v_ew FROM public.wallets WHERE profile_id=r.referee_id;

  PERFORM public.post_transaction('ADJUSTMENT', v_referrer_amt, 'ref-rr:'||r.id::text,
    jsonb_build_array(
      jsonb_build_object('wallet_id',v_rw,'account','wallet','delta_paise',v_referrer_amt,'bonus_delta_paise',v_referrer_amt),
      jsonb_build_object('account','referral_incentive','delta_paise',-v_referrer_amt)));
  IF v_ew IS NOT NULL THEN
    PERFORM public.post_transaction('ADJUSTMENT', v_referee_amt, 'ref-re:'||r.id::text,
      jsonb_build_array(
        jsonb_build_object('wallet_id',v_ew,'account','wallet','delta_paise',v_referee_amt,'bonus_delta_paise',v_referee_amt),
        jsonb_build_object('account','referral_incentive','delta_paise',-v_referee_amt)));
  END IF;

  UPDATE public.platform_settings SET referral_budget_remaining_paise = referral_budget_remaining_paise - v_total WHERE id=1;
  INSERT INTO public.credit_grants (profile_id, source, amount_paise, reference)
    VALUES (r.referrer_id,'REFERRAL',v_referrer_amt, r.id::text), (r.referee_id,'REFERRAL',v_referee_amt, r.id::text);
  UPDATE public.referrals SET status='COMPLETED_REWARDED', referrer_reward_paise=v_referrer_amt,
    referee_reward_paise=v_referee_amt, referrer_credited_at=now(), referee_credited_at=now(), updated_at=now()
    WHERE id=r.id;
  RETURN jsonb_build_object('success',true,'referrer_credited',v_referrer_amt,'referee_credited',v_referee_amt);
END $$;

-- ── Partner set-service now requires an ACTIVE partner ──
CREATE OR REPLACE FUNCTION rpc_partner_set_service(
  p_partner uuid, p_type service_type_enum, p_duration call_duration_options_enum,
  p_price_paise bigint, p_active boolean DEFAULT true)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_min bigint; v_status public.account_status;
BEGIN
  SELECT status INTO v_status FROM public.partner_profiles WHERE profile_id=p_partner;
  IF v_status IS DISTINCT FROM 'ACTIVE' THEN
    RETURN jsonb_build_object('success',false,'error','PARTNER_NOT_ACTIVE'); END IF;
  IF p_type = 'VIDEO_CALL' AND p_duration IS NULL THEN
    RETURN jsonb_build_object('success',false,'error','DURATION_REQUIRED'); END IF;
  IF p_type <> 'VIDEO_CALL' AND p_duration IS NOT NULL THEN
    RETURN jsonb_build_object('success',false,'error','DURATION_NOT_ALLOWED'); END IF;
  SELECT (min_service_prices->>p_type::text)::bigint INTO v_min FROM public.platform_settings WHERE id=1;
  IF p_active AND p_price_paise < v_min THEN
    RETURN jsonb_build_object('success',false,'error','BELOW_MIN_PRICE','min_paise',v_min); END IF;
  INSERT INTO public.partner_services (partner_id, service_type, duration, price_paise, is_active)
    VALUES (p_partner, p_type, p_duration, p_price_paise, p_active)
    ON CONFLICT (partner_id, service_type, duration) DO UPDATE
      SET price_paise = EXCLUDED.price_paise, is_active = EXCLUDED.is_active, updated_at = now();
  RETURN jsonb_build_object('success',true);
END $$;

REVOKE ALL ON FUNCTION resolve_price(uuid,service_type_enum,call_duration_options_enum,text,uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION rpc_admin_resolve_shoutout_report(uuid,uuid,text,text) FROM PUBLIC;

COMMIT;

-- 0020 · Category seed + the critical partner/booking features that were missing:
-- partner set-availability, partner set-service/pricing (with min-price floor),
-- and the KYC/premium gate on bookings.

BEGIN;

-- ── Partner categories (finance, healthcare, wellness, …) ──
INSERT INTO categories (slug, name, sort_order) VALUES
  ('finance','Finance',1), ('healthcare','Healthcare',2), ('wellness','Wellness',3),
  ('fitness','Fitness',4), ('fashion','Fashion & Beauty',5), ('education','Education',6),
  ('business','Business',7), ('technology','Technology',8), ('entertainment','Entertainment',9),
  ('music','Music',10), ('art','Art & Design',11), ('food','Food & Cooking',12),
  ('travel','Travel',13), ('gaming','Gaming',14), ('sports','Sports',15), ('lifestyle','Lifestyle',16)
ON CONFLICT (slug) DO NOTHING;

-- Per-service minimum price floors (paise) — config on platform_settings.
ALTER TABLE platform_settings
  ADD COLUMN IF NOT EXISTS min_service_prices jsonb NOT NULL
    DEFAULT '{"VIDEO_CALL":10000,"QUICK_QUESTION":5000,"SHOUT_OUT":20000}';

-- ── Partner sets availability for a date. Default is UNAVAILABLE; a partner must
--    explicitly open minutes. minutes=0 (or absent) → not bookable that day. ──
CREATE OR REPLACE FUNCTION rpc_partner_set_availability(p_partner uuid, p_date date, p_minutes int)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  IF p_minutes < 0 THEN RETURN jsonb_build_object('success',false,'error','INVALID_MINUTES'); END IF;
  INSERT INTO public.availability (partner_id, date, is_available, threshold_minutes)
    VALUES (p_partner, p_date, p_minutes > 0, p_minutes)
    ON CONFLICT (partner_id, date) DO UPDATE
      SET is_available = (p_minutes > 0), threshold_minutes = p_minutes, updated_at = now();
  RETURN jsonb_build_object('success',true,'date',p_date,'minutes',p_minutes,'available',p_minutes>0);
END $$;

-- ── Partner sets/updates a service offering + price (enforces the min floor). ──
CREATE OR REPLACE FUNCTION rpc_partner_set_service(
  p_partner uuid, p_type service_type_enum, p_duration call_duration_options_enum,
  p_price_paise bigint, p_active boolean DEFAULT true)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_min bigint;
BEGIN
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

-- ── Booking WITH the KYC/premium gate (recreated). Premium partner ⇒ fan must be
--    KYC-VERIFIED. Everything else identical to 0014. ──
CREATE OR REPLACE FUNCTION rpc_book_video_call(
  p_fan uuid, p_partner uuid, p_date date, p_duration call_duration_options_enum,
  p_price_paise bigint, p_note text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_wallet uuid; v_avail public.availability; v_mins int; v_booking uuid; v_res jsonb;
        v_premium boolean; v_kyc public.verification_status;
BEGIN
  -- premium partner requires the fan to be KYC-verified
  SELECT is_premium INTO v_premium FROM public.partner_profiles WHERE profile_id=p_partner;
  IF v_premium THEN
    SELECT verification_status INTO v_kyc FROM public.profiles WHERE id=p_fan;
    IF v_kyc IS DISTINCT FROM 'VERIFIED' THEN
      RETURN jsonb_build_object('success',false,'error','KYC_REQUIRED'); END IF;
  END IF;

  v_mins := (p_duration::text)::int;
  SELECT * INTO v_avail FROM public.availability
    WHERE partner_id=p_partner AND date=p_date FOR UPDATE;
  IF NOT FOUND OR NOT v_avail.is_available THEN
    RETURN jsonb_build_object('success',false,'error','NOT_AVAILABLE'); END IF;
  IF v_avail.booked_minutes + v_mins > v_avail.threshold_minutes THEN
    RETURN jsonb_build_object('success',false,'error','NO_CAPACITY',
      'minutes_left', v_avail.threshold_minutes - v_avail.booked_minutes); END IF;

  SELECT id INTO v_wallet FROM public.wallets WHERE profile_id=p_fan;
  v_booking := gen_random_uuid();
  v_res := public.post_transaction('BOOKING_DEBIT', p_price_paise, 'book:'||v_booking::text,
    jsonb_build_array(
      jsonb_build_object('wallet_id',v_wallet,'account','wallet','delta_paise',-p_price_paise),
      jsonb_build_object('account','booking_escrow','delta_paise',p_price_paise)),
    v_booking::text);
  INSERT INTO public.bookings (id, fan_id, partner_id, scheduled_date, selected_duration,
    price_paise, status, fan_note, escrow_txn_id, settle_at)
  VALUES (v_booking, p_fan, p_partner, p_date, p_duration, p_price_paise, 'BOOKED', p_note,
    (v_res->>'transaction_id')::uuid, now()+interval '7 days');
  UPDATE public.availability SET booked_minutes = booked_minutes + v_mins, updated_at=now()
    WHERE id = v_avail.id;
  RETURN jsonb_build_object('success',true,'booking_id',v_booking);
END $$;

REVOKE ALL ON FUNCTION rpc_partner_set_availability(uuid,date,int) FROM PUBLIC;
REVOKE ALL ON FUNCTION rpc_partner_set_service(uuid,service_type_enum,call_duration_options_enum,bigint,boolean) FROM PUBLIC;

COMMIT;

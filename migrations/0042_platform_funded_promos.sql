-- 0042 · Promo discounts become PLATFORM-funded (they were creator-funded).
--
-- resolve_price has always carried the comment "platform-funded: partner still
-- settles v_base" — but the implementation did the opposite. Escrow only ever
-- received the DISCOUNTED price, and rpc_settle_booking paid the creator
-- b.price_paise, i.e. the discounted amount. A ₹100 call under a 20% promo
-- earned the creator ₹80. The platform ran the promotion; the creator silently
-- paid for it. The ledger balanced, so nothing ever flagged it.
--
-- Confirming the intended model: the fan pays the discounted price, the
-- PLATFORM funds the difference, and the creator is settled the FULL list
-- price as if no promo existed.
--
-- Accounting, per booking (v_base = list, v_final = fan pays, v_disc = funded):
--   book    wallet          -v_final
--           promo_incentive -v_disc      (platform contributes; omitted if 0)
--           booking_escrow  +v_base      -> sums to 0
--   settle  booking_escrow  -v_base
--           partner_payable +v_base      -> creator gets full list price
--   refund  booking_escrow  -v_base
--           wallet          +v_final     (fan gets back exactly what they paid)
--           promo_incentive +v_disc      (platform reclaims its contribution)
--
-- `promo_incentive` mirrors the existing `referral_incentive` account: a
-- platform-funded incentive pool that goes negative as it is spent. account is
-- free text on ledger_entries, so no type change is needed.
--
-- WHO BENEFITED is already captured — rpc_book_video_call writes
-- promo_code_usages (promo_code_id, fan_id, transaction_id, discount_paise) on
-- every discounted booking. This migration adds vw_admin_promo_beneficiaries
-- so that record is actually readable, since nothing exposed it before.
--
-- transactions.amount_paise for a discounted booking now records the GROSS
-- (v_base) rather than the net. Verified safe: the fan's wallet history in the
-- app renders le.delta_paise (`wallet_delta`), which remains -v_final, so the
-- fan still sees exactly what they paid.
--
-- Function bodies below are the live pg_get_functiondef output with only the
-- money legs changed; no unrelated logic was retyped.

BEGIN;

-- ── Booking: fan pays net, platform funds the discount, escrow holds gross ──
CREATE OR REPLACE FUNCTION public.rpc_book_video_call(p_fan uuid, p_partner uuid, p_date date, p_duration call_duration_options_enum, p_note text DEFAULT NULL::text, p_promo_code text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE v_wallet uuid; v_avail public.availability; v_mins int; v_booking uuid; v_res jsonb;
        v_premium boolean; v_kyc public.verification_status; v_partner_status public.account_status;
        v_price jsonb; v_final bigint; v_base bigint; v_disc bigint; v_legs jsonb;
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
  v_base  := (v_price->>'base_paise')::bigint;
  v_disc  := COALESCE((v_price->>'discount_paise')::bigint, 0);

  v_mins := (p_duration::text)::int;
  SELECT * INTO v_avail FROM public.availability WHERE partner_id=p_partner AND date=p_date FOR UPDATE;
  IF NOT FOUND OR NOT v_avail.is_available THEN
    RETURN jsonb_build_object('success',false,'error','NOT_AVAILABLE'); END IF;
  IF v_avail.booked_minutes + v_mins > v_avail.threshold_minutes THEN
    RETURN jsonb_build_object('success',false,'error','NO_CAPACITY'); END IF;

  SELECT id INTO v_wallet FROM public.wallets WHERE profile_id=p_fan;
  v_booking := gen_random_uuid();

  -- Escrow always receives the FULL list price. The fan funds v_final of it;
  -- the platform funds the rest. The promo leg is omitted entirely when there
  -- is no discount, so undiscounted bookings post exactly as before.
  v_legs := jsonb_build_array(
      jsonb_build_object('wallet_id',v_wallet,'account','wallet','delta_paise',-v_final),
      jsonb_build_object('account','booking_escrow','delta_paise',v_base));
  IF v_disc > 0 THEN
    v_legs := v_legs || jsonb_build_array(
      jsonb_build_object('account','promo_incentive','delta_paise',-v_disc));
  END IF;

  v_res := public.post_transaction('BOOKING_DEBIT', v_base, 'book:'||v_booking::text, v_legs, v_booking::text);

  INSERT INTO public.bookings (id, fan_id, partner_id, scheduled_date, selected_duration,
    price_paise, original_price_paise, discount_paise, promo_code_id, status, fan_note, escrow_txn_id, settle_at)
  VALUES (v_booking, p_fan, p_partner, p_date, p_duration, v_final,
    v_base, v_disc,
    (v_price->>'promo_id')::uuid, 'BOOKED', p_note, (v_res->>'transaction_id')::uuid, now()+((SELECT settlement_window_days FROM public.platform_settings WHERE id=1) * interval '1 day'));
  UPDATE public.availability SET booked_minutes = booked_minutes + v_mins, updated_at=now() WHERE id = v_avail.id;
  IF p_promo_code IS NOT NULL AND (v_price->>'promo_id') IS NOT NULL THEN
    INSERT INTO public.promo_code_usages (promo_code_id, fan_id, transaction_id, discount_paise)
      VALUES ((v_price->>'promo_id')::uuid, p_fan, (v_res->>'transaction_id')::uuid, v_disc);
    UPDATE public.promo_codes SET current_total_uses = current_total_uses+1 WHERE id=(v_price->>'promo_id')::uuid;
  END IF;
  RETURN jsonb_build_object('success',true,'booking_id',v_booking,'price_paise',v_final);
END $function$;

-- ── Settlement: creator is paid the FULL list price, promo or not ──
CREATE OR REPLACE FUNCTION public.rpc_settle_booking(p_booking uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE b public.bookings; v_res jsonb; v_gross bigint;
BEGIN
  PERFORM public.assert_system();   -- settlement sweep job / admin only
  SELECT * INTO b FROM public.bookings WHERE id=p_booking FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('success',false,'error','NOT_FOUND'); END IF;

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

-- ── Refund: fan gets back what they paid; platform reclaims what it funded ──
CREATE OR REPLACE FUNCTION public.rpc_refund_booking(p_booking uuid, p_reason refund_reason)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE b public.bookings; v_wallet uuid; v_res jsonb; v_mins int;
        v_gross bigint; v_disc bigint; v_legs jsonb;
BEGIN
  SELECT * INTO b FROM public.bookings WHERE id=p_booking FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('success',false,'error','NOT_FOUND'); END IF;
  PERFORM public.assert_caller(b.fan_id);   -- fan self-service OR admin goodwill/dispute refund
  IF b.status NOT IN ('BOOKED') THEN
    RETURN jsonb_build_object('success',false,'error','NOT_REFUNDABLE','status',b.status); END IF;
  IF now() > b.settle_at THEN
    RETURN jsonb_build_object('success',false,'error','PAST_REFUND_WINDOW'); END IF;

  v_gross := COALESCE(b.original_price_paise, b.price_paise);
  v_disc  := COALESCE(b.discount_paise, 0);

  SELECT id INTO v_wallet FROM public.wallets WHERE profile_id=b.fan_id;

  -- Unwinds the booking legs exactly: escrow releases the gross, the fan is
  -- made whole for what they actually paid, and the platform's contribution
  -- returns to the incentive pool rather than becoming a windfall for the fan.
  v_legs := jsonb_build_array(
      jsonb_build_object('account','booking_escrow','delta_paise',-v_gross),
      jsonb_build_object('wallet_id',v_wallet,'account','wallet','delta_paise',b.price_paise));
  IF v_disc > 0 THEN
    v_legs := v_legs || jsonb_build_array(
      jsonb_build_object('account','promo_incentive','delta_paise',v_disc));
  END IF;

  v_res := public.post_transaction('REFUND', v_gross, 'refund:'||b.id::text, v_legs, b.id::text);

  UPDATE public.bookings SET status='CANCELLED_BY_FAN', cancellation_reason=p_reason::text, updated_at=now()
    WHERE id=b.id;
  UPDATE public.transactions SET refund_reason=p_reason WHERE id=(v_res->>'transaction_id')::uuid;
  v_mins := (b.selected_duration::text)::int;
  UPDATE public.availability SET booked_minutes = greatest(0, booked_minutes - v_mins)
    WHERE partner_id=b.partner_id AND date=b.scheduled_date;
  RETURN jsonb_build_object('success',true,'transaction_id',v_res->>'transaction_id');
END $function$;

-- ── Who benefited from promo cash (the record existed; nothing read it) ──
CREATE OR REPLACE VIEW vw_admin_promo_beneficiaries AS
SELECT u.id                AS usage_id,
       pc.code,
       pc.discount_type,
       u.fan_id,
       p.full_name         AS fan_name,
       p.email             AS fan_email,
       u.discount_paise,
       u.transaction_id,
       u.used_at,
       b.id                AS booking_id,
       b.status            AS booking_status,
       b.original_price_paise,
       b.price_paise       AS fan_paid_paise
  FROM public.promo_code_usages u
  JOIN public.promo_codes pc ON pc.id = u.promo_code_id
  JOIN public.profiles    p  ON p.id  = u.fan_id
  LEFT JOIN public.bookings b ON b.escrow_txn_id = u.transaction_id
 WHERE public.is_admin();

REVOKE ALL ON public.vw_admin_promo_beneficiaries FROM PUBLIC;
GRANT SELECT ON public.vw_admin_promo_beneficiaries TO zudue_app;

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

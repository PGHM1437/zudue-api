-- 0014 · Booking-flow RPCs (Supabase-native, self-sufficient). Clean reimplementations
-- of the decoded logic, on top of post_transaction. Fixes designed in:
--   • overbooking race → availability row locked (FOR UPDATE)
--   • money via the one atomic primitive; escrow model; commission NOT here
--   • 7-day settle = full amount to partner; refund only pre-settle

BEGIN;

-- Verify a Razorpay top-up (called after gateway confirms) → credit wallet + GST.
CREATE OR REPLACE FUNCTION rpc_verify_topup(
  p_razorpay_order_id text, p_razorpay_payment_id text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_order public.topup_orders; v_wallet uuid; v_res jsonb;
BEGIN
  SELECT * INTO v_order FROM public.topup_orders WHERE razorpay_order_id = p_razorpay_order_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('success',false,'error','ORDER_NOT_FOUND'); END IF;
  IF v_order.status = 'SUCCESSFUL' THEN
    RETURN jsonb_build_object('success',true,'replayed',true);   -- idempotent
  END IF;
  SELECT id INTO v_wallet FROM public.wallets WHERE profile_id = v_order.profile_id;

  v_res := public.post_transaction('TOPUP', v_order.amount_paise, 'topup:'||v_order.id::text,
    jsonb_build_array(
      jsonb_build_object('wallet_id',v_wallet,'account','wallet','delta_paise',v_order.credit_paise),
      jsonb_build_object('account','gst_payable','delta_paise',v_order.gst_paise),
      jsonb_build_object('account','razorpay_clearing','delta_paise',-v_order.amount_paise)),
    v_order.razorpay_order_id);

  UPDATE public.topup_orders SET status='SUCCESSFUL', razorpay_payment_id=p_razorpay_payment_id,
    transaction_id=(v_res->>'transaction_id')::uuid, updated_at=now() WHERE id=v_order.id;
  RETURN jsonb_build_object('success',true,'transaction_id',v_res->>'transaction_id');
END $$;

-- Book a video call: capacity check (LOCKED), escrow the price, create booking.
CREATE OR REPLACE FUNCTION rpc_book_video_call(
  p_fan uuid, p_partner uuid, p_date date, p_duration call_duration_options_enum,
  p_price_paise bigint, p_note text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_wallet uuid; v_avail public.availability; v_mins int; v_booking uuid; v_res jsonb;
BEGIN
  v_mins := (p_duration::text)::int;
  -- Capacity: lock the day's availability row so concurrent bookings can't overbook.
  SELECT * INTO v_avail FROM public.availability
    WHERE partner_id=p_partner AND date=p_date FOR UPDATE;
  IF NOT FOUND OR NOT v_avail.is_available THEN
    RETURN jsonb_build_object('success',false,'error','NOT_AVAILABLE'); END IF;
  IF v_avail.booked_minutes + v_mins > v_avail.threshold_minutes THEN
    RETURN jsonb_build_object('success',false,'error','NO_CAPACITY',
      'minutes_left', v_avail.threshold_minutes - v_avail.booked_minutes); END IF;

  SELECT id INTO v_wallet FROM public.wallets WHERE profile_id=p_fan;
  v_booking := gen_random_uuid();

  -- Escrow the full price (fails cleanly on insufficient funds via wallet CHECK).
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

  RETURN jsonb_build_object('success',true,'booking_id',v_booking,'transaction_id',v_res->>'transaction_id');
END $$;

-- Refund a booking to wallet (ONLY before settlement / within the 7-day window).
CREATE OR REPLACE FUNCTION rpc_refund_booking(p_booking uuid, p_reason refund_reason)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE b public.bookings; v_wallet uuid; v_res jsonb; v_mins int;
BEGIN
  SELECT * INTO b FROM public.bookings WHERE id=p_booking FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('success',false,'error','NOT_FOUND'); END IF;
  IF b.status NOT IN ('BOOKED') THEN
    RETURN jsonb_build_object('success',false,'error','NOT_REFUNDABLE','status',b.status); END IF;
  IF now() > b.settle_at THEN
    RETURN jsonb_build_object('success',false,'error','PAST_REFUND_WINDOW'); END IF;

  SELECT id INTO v_wallet FROM public.wallets WHERE profile_id=b.fan_id;
  v_res := public.post_transaction('REFUND', b.price_paise, 'refund:'||b.id::text,
    jsonb_build_array(
      jsonb_build_object('account','booking_escrow','delta_paise',-b.price_paise),
      jsonb_build_object('wallet_id',v_wallet,'account','wallet','delta_paise',b.price_paise)),
    b.id::text);

  UPDATE public.bookings SET status='CANCELLED_BY_FAN', cancellation_reason=p_reason::text, updated_at=now()
    WHERE id=b.id;
  UPDATE public.transactions SET refund_reason=p_reason WHERE id=(v_res->>'transaction_id')::uuid;
  -- release the reserved minutes
  v_mins := (b.selected_duration::text)::int;
  UPDATE public.availability SET booked_minutes = greatest(0, booked_minutes - v_mins)
    WHERE partner_id=b.partner_id AND date=b.scheduled_date;
  RETURN jsonb_build_object('success',true,'transaction_id',v_res->>'transaction_id');
END $$;

-- Settle a fulfilled booking at day-7: escrow → partner (FULL) + create earning.
-- Fan-fault non-fulfillment (no-show) also settles to partner (penalty). Called by a job.
CREATE OR REPLACE FUNCTION rpc_settle_booking(p_booking uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE b public.bookings; v_res jsonb;
BEGIN
  SELECT * INTO b FROM public.bookings WHERE id=p_booking FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('success',false,'error','NOT_FOUND'); END IF;

  v_res := public.post_transaction('PARTNER_EARNING', b.price_paise, 'settle:'||b.id::text,
    jsonb_build_array(
      jsonb_build_object('account','booking_escrow','delta_paise',-b.price_paise),
      jsonb_build_object('account','partner_payable','delta_paise',b.price_paise)),
    b.id::text);

  INSERT INTO public.partner_earnings (partner_id, transaction_id, service_type, service_id, amount_paise)
  VALUES (b.partner_id, (v_res->>'transaction_id')::uuid, 'VIDEO_CALL', b.id, b.price_paise);

  RETURN jsonb_build_object('success',true,'transaction_id',v_res->>'transaction_id');
END $$;

REVOKE ALL ON FUNCTION rpc_verify_topup(text,text) FROM PUBLIC;
REVOKE ALL ON FUNCTION rpc_book_video_call(uuid,uuid,date,call_duration_options_enum,bigint,text) FROM PUBLIC;
REVOKE ALL ON FUNCTION rpc_refund_booking(uuid,refund_reason) FROM PUBLIC;
REVOKE ALL ON FUNCTION rpc_settle_booking(uuid) FROM PUBLIC;

COMMIT;

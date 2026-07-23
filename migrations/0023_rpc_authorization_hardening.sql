-- 0023 · CRITICAL FIX: authorization bypass across the entire RPC surface.
--
-- Finding: every rpc_book_video_call/rpc_admin_*/rpc_process_payout/etc. takes
-- an actor uuid (p_fan, p_partner, p_admin) as a PARAMETER and never verifies
-- the calling session actually IS that actor. Because SECURITY DEFINER
-- functions bypass RLS entirely (they run as the table-owning role), RLS's
-- ownership checks never apply to anything routed through an RPC — and 100%
-- of the money-moving/state-changing logic in this schema IS routed through
-- RPCs. In practice this means: any caller who can invoke rpc_process_payout
-- can pay out ANY partner's payout (no admin check existed at all); any caller
-- can book/refund/message/shout-out AS any other fan or partner by passing
-- their uuid; any caller can invoke rpc_admin_* by passing a guessed or
-- observed admin uuid as p_admin, with zero role verification.
--
-- This is the same root cause as 0022's exploit (trust a caller-supplied
-- value instead of the verified session identity), just systemic instead of
-- isolated. Fix: every RPC now asserts the caller's verified current_user_id()
-- against the actor it claims to act as (or requires admin/service role).
-- All signatures are UNCHANGED — CREATE OR REPLACE is safe here, not an
-- overload (see 0022's guard, which still passes at the end of this file).

BEGIN;

-- ── Authorization primitives ────────────────────────────────────────────
-- is_service_role(): true only when the trusted API/job-runner explicitly
-- sets this GUC for a system-initiated action (webhook receipt, cron
-- settlement sweep). Never derived from anything user-controlled.
CREATE OR REPLACE FUNCTION is_service_role()
RETURNS boolean LANGUAGE sql STABLE AS $$
  SELECT COALESCE(current_setting('app.is_service_role', true), 'false')::boolean
$$;

-- is_admin_role(...): does the caller hold ONE OF the given admin tiers?
-- (admin_role/permissions on admin_profiles existed but were never read by
-- any policy or function — every admin had identical blanket power. This is
-- the first thing that actually enforces the tier.)
CREATE OR REPLACE FUNCTION is_admin_role(VARIADIC p_roles admin_role[])
RETURNS boolean LANGUAGE sql STABLE SET search_path = '' AS $$
  SELECT public.is_admin() AND EXISTS (
    SELECT 1 FROM public.admin_profiles ap
    WHERE ap.profile_id = public.current_user_id() AND ap.admin_role = ANY(p_roles)
  )
$$;

-- assert_caller_any(...): caller must BE one of the listed actors, OR be an
-- admin, OR be the trusted service role. This is the one rule applied
-- everywhere: "am I who I claim to act as, or am I privileged enough to act
-- on their behalf anyway?"
CREATE OR REPLACE FUNCTION assert_caller_any(VARIADIC p_actors uuid[])
RETURNS void LANGUAGE plpgsql STABLE SET search_path = '' AS $$
BEGIN
  IF public.current_user_id() = ANY(p_actors) THEN RETURN; END IF;
  IF public.is_admin() OR public.is_service_role() THEN RETURN; END IF;
  RAISE EXCEPTION 'FORBIDDEN: caller is not an authorized party' USING ERRCODE = '42501';
END $$;

CREATE OR REPLACE FUNCTION assert_caller(p_actor uuid)
RETURNS void LANGUAGE plpgsql STABLE SET search_path = '' AS $$
BEGIN
  PERFORM public.assert_caller_any(p_actor);
END $$;

CREATE OR REPLACE FUNCTION assert_admin()
RETURNS void LANGUAGE plpgsql STABLE SET search_path = '' AS $$
BEGIN
  IF NOT public.is_admin() THEN
    RAISE EXCEPTION 'FORBIDDEN: admin only' USING ERRCODE = '42501';
  END IF;
END $$;

CREATE OR REPLACE FUNCTION assert_admin_role(VARIADIC p_roles admin_role[])
RETURNS void LANGUAGE plpgsql STABLE SET search_path = '' AS $$
BEGIN
  IF NOT public.is_admin_role(VARIADIC p_roles) THEN
    RAISE EXCEPTION 'FORBIDDEN: requires admin role %', p_roles USING ERRCODE = '42501';
  END IF;
END $$;

-- assert_is_admin_actor(p_admin): the standard guard for every rpc_admin_*
-- function. p_admin is kept as an explicit parameter (for audit clarity /
-- signature stability) but is now a VERIFIED claim, not a trusted label —
-- it must equal the caller's own verified identity, and that identity must
-- actually be an admin. Prevents both impersonation AND a spoofed audit trail.
CREATE OR REPLACE FUNCTION assert_is_admin_actor(p_admin uuid)
RETURNS void LANGUAGE plpgsql STABLE SET search_path = '' AS $$
BEGIN
  IF p_admin IS DISTINCT FROM public.current_user_id() THEN
    RAISE EXCEPTION 'FORBIDDEN: p_admin does not match caller' USING ERRCODE = '42501';
  END IF;
  PERFORM public.assert_admin();
END $$;

CREATE OR REPLACE FUNCTION assert_system()
RETURNS void LANGUAGE plpgsql STABLE SET search_path = '' AS $$
BEGIN
  IF NOT (public.is_admin() OR public.is_service_role()) THEN
    RAISE EXCEPTION 'FORBIDDEN: system or admin only' USING ERRCODE = '42501';
  END IF;
END $$;

REVOKE ALL ON FUNCTION is_service_role() FROM PUBLIC;

-- ── Retrofit: money/topup/booking (0014) ────────────────────────────────
CREATE OR REPLACE FUNCTION rpc_verify_topup(
  p_razorpay_order_id text, p_razorpay_payment_id text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_order public.topup_orders; v_wallet uuid; v_res jsonb;
BEGIN
  PERFORM public.assert_system();   -- webhook/service-only: never end-user-invoked
  SELECT * INTO v_order FROM public.topup_orders WHERE razorpay_order_id = p_razorpay_order_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('success',false,'error','ORDER_NOT_FOUND'); END IF;
  IF v_order.status = 'SUCCESSFUL' THEN
    RETURN jsonb_build_object('success',true,'replayed',true);
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

CREATE OR REPLACE FUNCTION rpc_book_video_call(
  p_fan uuid, p_partner uuid, p_date date, p_duration call_duration_options_enum,
  p_note text DEFAULT NULL, p_promo_code text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
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
    (v_price->>'promo_id')::uuid, 'BOOKED', p_note, (v_res->>'transaction_id')::uuid, now()+interval '7 days');
  UPDATE public.availability SET booked_minutes = booked_minutes + v_mins, updated_at=now() WHERE id = v_avail.id;
  IF p_promo_code IS NOT NULL AND (v_price->>'promo_id') IS NOT NULL THEN
    INSERT INTO public.promo_code_usages (promo_code_id, fan_id, transaction_id, discount_paise)
      VALUES ((v_price->>'promo_id')::uuid, p_fan, (v_res->>'transaction_id')::uuid, (v_price->>'discount_paise')::bigint);
    UPDATE public.promo_codes SET current_total_uses = current_total_uses+1 WHERE id=(v_price->>'promo_id')::uuid;
  END IF;
  RETURN jsonb_build_object('success',true,'booking_id',v_booking,'price_paise',v_final);
END $$;

CREATE OR REPLACE FUNCTION rpc_refund_booking(p_booking uuid, p_reason refund_reason)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE b public.bookings; v_wallet uuid; v_res jsonb; v_mins int;
BEGIN
  SELECT * INTO b FROM public.bookings WHERE id=p_booking FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('success',false,'error','NOT_FOUND'); END IF;
  PERFORM public.assert_caller(b.fan_id);   -- fan self-service OR admin goodwill/dispute refund
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
  v_mins := (b.selected_duration::text)::int;
  UPDATE public.availability SET booked_minutes = greatest(0, booked_minutes - v_mins)
    WHERE partner_id=b.partner_id AND date=b.scheduled_date;
  RETURN jsonb_build_object('success',true,'transaction_id',v_res->>'transaction_id');
END $$;

CREATE OR REPLACE FUNCTION rpc_settle_booking(p_booking uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE b public.bookings; v_res jsonb;
BEGIN
  PERFORM public.assert_system();   -- settlement sweep job / admin only
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

-- ── Retrofit: call lifecycle (0015) ─────────────────────────────────────
CREATE OR REPLACE FUNCTION rpc_fan_signal_ready(p_booking uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_fan uuid;
BEGIN
  SELECT fan_id INTO v_fan FROM public.bookings WHERE id=p_booking;
  IF v_fan IS NULL THEN RETURN jsonb_build_object('success',false,'error','NOT_FOUND'); END IF;
  PERFORM public.assert_caller(v_fan);
  UPDATE public.bookings SET fan_ready_at = now(), updated_at = now()
   WHERE id = p_booking AND status = 'BOOKED';
  IF NOT FOUND THEN RETURN jsonb_build_object('success',false,'error','NOT_BOOKABLE'); END IF;
  RETURN jsonb_build_object('success',true);
END $$;

CREATE OR REPLACE FUNCTION rpc_partner_initiate_call(p_booking uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE b public.bookings; v_call uuid; v_meeting text;
BEGIN
  SELECT * INTO b FROM public.bookings WHERE id = p_booking FOR UPDATE;
  IF NOT FOUND OR b.status <> 'BOOKED' THEN
    RETURN jsonb_build_object('success',false,'error','NOT_BOOKABLE'); END IF;
  PERFORM public.assert_caller(b.partner_id);
  IF EXISTS (SELECT 1 FROM public.calls c WHERE c.booking_id=p_booking
       AND c.attempt_status='PARTNER_INITIATED' AND c.partner_initiated_at > now()-interval '60 seconds') THEN
    RETURN jsonb_build_object('success',false,'error','ALREADY_INITIATED'); END IF;

  v_meeting := COALESCE(b.meeting_id, 'zudue-'||gen_random_uuid()::text);
  UPDATE public.bookings SET meeting_id=v_meeting, attempts=attempts+1, updated_at=now() WHERE id=p_booking;

  INSERT INTO public.calls (booking_id, fan_id, partner_id, attempt_status, meeting_id, partner_initiated_at)
  VALUES (p_booking, b.fan_id, b.partner_id, 'PARTNER_INITIATED', v_meeting, now())
  RETURNING id INTO v_call;

  RETURN jsonb_build_object('success',true,'call_id',v_call,'meeting_id',v_meeting);
END $$;

CREATE OR REPLACE FUNCTION rpc_fan_join_call(p_booking uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE c public.calls; v_mins int;
BEGIN
  SELECT * INTO c FROM public.calls
    WHERE booking_id=p_booking AND attempt_status IN ('PARTNER_INITIATED','IN_PROGRESS')
    ORDER BY partner_initiated_at DESC LIMIT 1 FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('success',false,'error','NO_ACTIVE_CALL'); END IF;
  PERFORM public.assert_caller(c.fan_id);

  IF c.attempt_status = 'PARTNER_INITIATED' THEN
    SELECT (selected_duration::text)::int INTO v_mins FROM public.bookings WHERE id=p_booking;
    UPDATE public.calls SET attempt_status='IN_PROGRESS', fan_joined_at=now(),
      started_at=now(), deadline_at=now()+(v_mins||' minutes')::interval,
      fan_last_heartbeat_at=now(), updated_at=now()
    WHERE id=c.id;
  END IF;

  RETURN jsonb_build_object('success',true,'call_id',c.id,'meeting_id',c.meeting_id);
END $$;

CREATE OR REPLACE FUNCTION rpc_call_heartbeat(p_call uuid, p_actor text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE c public.calls; v_expected uuid;
BEGIN
  SELECT * INTO c FROM public.calls WHERE id=p_call;
  IF NOT FOUND THEN RETURN jsonb_build_object('success',false,'error','NOT_FOUND'); END IF;
  v_expected := CASE WHEN p_actor='FAN' THEN c.fan_id ELSE c.partner_id END;
  PERFORM public.assert_caller(v_expected);

  IF p_actor = 'FAN' THEN
    UPDATE public.calls SET fan_last_heartbeat_at=now(), heartbeat_count=heartbeat_count+1 WHERE id=p_call RETURNING * INTO c;
  ELSE
    UPDATE public.calls SET partner_last_heartbeat_at=now(), heartbeat_count=heartbeat_count+1 WHERE id=p_call RETURNING * INTO c;
  END IF;
  RETURN jsonb_build_object('success',true,
    'remaining_seconds', GREATEST(0, EXTRACT(epoch FROM c.deadline_at - now())::int));
END $$;

CREATE OR REPLACE FUNCTION rpc_complete_call(p_call uuid, p_auto boolean DEFAULT false)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE c public.calls;
BEGIN
  SELECT * INTO c FROM public.calls WHERE id=p_call FOR UPDATE;
  IF NOT FOUND OR c.attempt_status <> 'IN_PROGRESS' THEN
    RETURN jsonb_build_object('success',false,'error','NOT_IN_PROGRESS'); END IF;
  IF p_auto THEN
    PERFORM public.assert_system();
  ELSE
    PERFORM public.assert_caller_any(c.fan_id, c.partner_id);
  END IF;
  UPDATE public.calls SET attempt_status='COMPLETED_SUCCESSFUL', ended_at=now(),
    actual_duration_seconds = GREATEST(0, EXTRACT(epoch FROM now() - c.started_at)::int),
    termination_reason = CASE WHEN p_auto THEN 'auto_duration_complete' ELSE 'ended_by_participant' END,
    updated_at=now()
  WHERE id=p_call;
  RETURN jsonb_build_object('success',true);
END $$;

CREATE OR REPLACE FUNCTION rpc_mark_call_missed(p_call uuid, p_status call_status)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE c public.calls;
BEGIN
  IF p_status NOT IN ('MISSED_FAN_NO_JOIN','MISSED_FAN_DECLINED','DROPPED_TECHNICAL_ISSUE') THEN
    RETURN jsonb_build_object('success',false,'error','INVALID_STATUS'); END IF;
  SELECT * INTO c FROM public.calls WHERE id=p_call AND attempt_status IN ('PARTNER_INITIATED','IN_PROGRESS');
  IF NOT FOUND THEN RETURN jsonb_build_object('success',false,'error','NOT_ACTIVE'); END IF;
  PERFORM public.assert_caller_any(c.fan_id, c.partner_id);
  UPDATE public.calls SET attempt_status=p_status, ended_at=now(), updated_at=now() WHERE id=p_call;
  RETURN jsonb_build_object('success',true);
END $$;

-- ── Retrofit: messaging (0016 / 0021) ───────────────────────────────────
CREATE OR REPLACE FUNCTION rpc_ask_question(p_fan uuid, p_partner uuid, p_text text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
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
      VALUES (v_new_win, v_conv, 'PAID', v_price, 'OPEN', now()+interval '48 hours',
        (v_res->>'transaction_id')::uuid, now()+interval '7 days');
  END IF;
  INSERT INTO public.messages (window_id, sender, body) VALUES (v_new_win,'FAN',p_text);
  UPDATE public.conversations SET last_activity_at=now() WHERE id=v_conv;
  RETURN jsonb_build_object('success',true,'window_id',v_new_win,
    'kind', CASE WHEN v_any_window THEN 'PAID' ELSE 'FREE' END, 'charged', v_any_window);
END $$;

CREATE OR REPLACE FUNCTION rpc_partner_answer(p_partner uuid, p_conversation uuid, p_text text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_win public.conversation_windows; v_conv_partner uuid;
BEGIN
  SELECT partner_id INTO v_conv_partner FROM public.conversations WHERE id=p_conversation;
  IF v_conv_partner IS NULL THEN RETURN jsonb_build_object('success',false,'error','NOT_FOUND'); END IF;
  PERFORM public.assert_caller(v_conv_partner);
  IF p_partner IS DISTINCT FROM v_conv_partner THEN
    RETURN jsonb_build_object('success',false,'error','PARTNER_MISMATCH'); END IF;

  SELECT * INTO v_win FROM public.conversation_windows
    WHERE conversation_id=p_conversation AND status='OPEN' ORDER BY opened_at DESC LIMIT 1 FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('success',false,'error','NO_OPEN_WINDOW'); END IF;

  INSERT INTO public.messages (window_id, sender, body) VALUES (v_win.id,'PARTNER',p_text);
  UPDATE public.conversation_windows SET status='ANSWERED', closed_at=now() WHERE id=v_win.id;
  UPDATE public.conversations SET last_activity_at=now() WHERE id=p_conversation;
  RETURN jsonb_build_object('success',true,'window_id',v_win.id,'was_paid', v_win.kind='PAID');
END $$;

CREATE OR REPLACE FUNCTION rpc_settle_window(p_window uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE w public.conversation_windows; v_partner uuid; v_res jsonb;
BEGIN
  PERFORM public.assert_system();
  SELECT * INTO w FROM public.conversation_windows WHERE id=p_window FOR UPDATE;
  IF NOT FOUND OR w.kind<>'PAID' OR w.charge_paise=0 THEN
    RETURN jsonb_build_object('success',false,'error','NOT_SETTLEABLE'); END IF;
  SELECT partner_id INTO v_partner FROM public.conversations WHERE id=w.conversation_id;

  v_res := public.post_transaction('PARTNER_EARNING', w.charge_paise, 'settlewin:'||w.id::text,
    jsonb_build_array(
      jsonb_build_object('account','booking_escrow','delta_paise',-w.charge_paise),
      jsonb_build_object('account','partner_payable','delta_paise',w.charge_paise)),
    w.id::text);
  INSERT INTO public.partner_earnings (partner_id, transaction_id, service_type, service_id, amount_paise)
    VALUES (v_partner, (v_res->>'transaction_id')::uuid, 'QUICK_QUESTION', w.id, w.charge_paise);
  RETURN jsonb_build_object('success',true);
END $$;

-- ── Retrofit: shout-outs + payouts (0017 / 0021) ────────────────────────
CREATE OR REPLACE FUNCTION rpc_request_shoutout(
  p_fan uuid, p_partner uuid, p_recipient text, p_message text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
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
      (v_res->>'transaction_id')::uuid, now()+interval '7 days');
  RETURN jsonb_build_object('success',true,'shoutout_id',v_id,'price_paise',v_price);
END $$;

CREATE OR REPLACE FUNCTION rpc_upload_shoutout(p_id uuid, p_video_path text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE r public.shout_out_requests;
BEGIN
  SELECT * INTO r FROM public.shout_out_requests WHERE id=p_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('success',false,'error','NOT_FOUND'); END IF;
  PERFORM public.assert_caller(r.partner_id);
  UPDATE public.shout_out_requests
     SET partner_video_storage_path=p_video_path, partner_video_submitted_at=now(),
         delivered_video_link=p_video_path, delivered_at=now(),
         status='VIDEO_DELIVERED_TO_FAN', updated_at=now()
   WHERE id=p_id AND status='AWAITING_PARTNER_VIDEO';
  IF NOT FOUND THEN RETURN jsonb_build_object('success',false,'error','INVALID_STATE'); END IF;
  RETURN jsonb_build_object('success',true,'delivered',true);
END $$;

CREATE OR REPLACE FUNCTION rpc_report_shoutout(p_id uuid, p_reason text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE r public.shout_out_requests;
BEGIN
  SELECT * INTO r FROM public.shout_out_requests WHERE id=p_id FOR UPDATE;
  IF NOT FOUND OR r.status<>'VIDEO_DELIVERED_TO_FAN' THEN
    RETURN jsonb_build_object('success',false,'error','NOT_REPORTABLE'); END IF;
  PERFORM public.assert_caller(r.fan_id);
  UPDATE public.shout_out_requests SET status='ISSUE_REPORTED_BY_FAN', updated_at=now() WHERE id=p_id;
  INSERT INTO public.reports (reporter_id, target_type, target_id, reason)
    VALUES (r.fan_id, 'SHOUTOUT', p_id, p_reason);
  INSERT INTO public.notifications (recipient_id, event_type, title, message, related_entity_type, related_entity_id)
    SELECT p.id, 'PLATFORM_ANNOUNCEMENT', 'Shout-out flagged', 'A delivered shout-out was reported.', 'shoutout', p_id
    FROM public.profiles p WHERE p.role='ADMIN' LIMIT 1;
  RETURN jsonb_build_object('success',true);
END $$;

CREATE OR REPLACE FUNCTION rpc_create_payout_batch(p_partner uuid, p_method uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_sum bigint; v_payout uuid;
BEGIN
  PERFORM public.assert_caller(p_partner);
  IF NOT EXISTS (SELECT 1 FROM public.payout_methods WHERE id=p_method AND partner_id=p_partner AND is_verified) THEN
    RETURN jsonb_build_object('success',false,'error','UNVERIFIED_METHOD'); END IF;
  SELECT COALESCE(sum(amount_paise),0) INTO v_sum FROM public.partner_earnings
    WHERE partner_id=p_partner AND status='PENDING_PAYOUT';
  IF v_sum = 0 THEN RETURN jsonb_build_object('success',false,'error','NOTHING_TO_PAY'); END IF;

  INSERT INTO public.partner_payouts (partner_id, amount_paise, status, payout_method_id)
    VALUES (p_partner, v_sum, 'REQUESTED', p_method) RETURNING id INTO v_payout;
  UPDATE public.partner_earnings SET status='INCLUDED_IN_PAYOUT', payout_id=v_payout
    WHERE partner_id=p_partner AND status='PENDING_PAYOUT';
  RETURN jsonb_build_object('success',true,'payout_id',v_payout,'amount_paise',v_sum);
END $$;

-- The single most severe finding: this moved real money to ANY caller, no
-- authorization check existed at all. Now FINANCE/SUPER_ADMIN only.
CREATE OR REPLACE FUNCTION rpc_process_payout(p_payout uuid, p_approve boolean, p_reference text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE po public.partner_payouts; v_res jsonb;
BEGIN
  PERFORM public.assert_admin_role('FINANCE','SUPER_ADMIN');
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
    UPDATE public.partner_payouts SET status='REJECTED', processed_at=now() WHERE id=p_payout;
    UPDATE public.partner_earnings SET status='PENDING_PAYOUT', payout_id=NULL WHERE payout_id=p_payout;
    RETURN jsonb_build_object('success',true,'status','REJECTED','earnings_released',true);
  END IF;
END $$;

CREATE OR REPLACE FUNCTION rpc_admin_resolve_shoutout_report(
  p_admin uuid, p_shoutout uuid, p_action text, p_notes text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE r public.shout_out_requests; v_wallet uuid; v_res jsonb;
BEGIN
  PERFORM public.assert_is_admin_actor(p_admin);
  IF p_action = 'REFUND' THEN
    PERFORM public.assert_admin_role('FINANCE','SUPER_ADMIN');
  END IF;
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
    INSERT INTO public.audit_log (actor_id, actor_role, action, target_type, target_id, new_value)
      VALUES (p_admin,'ADMIN','RESOLVE_SHOUTOUT_REPORT','shout_out_request',p_shoutout, jsonb_build_object('action','REFUND'));
    RETURN jsonb_build_object('success',true,'refunded',true);
  ELSIF p_action = 'REWORK' THEN
    UPDATE public.shout_out_requests SET status='AWAITING_PARTNER_VIDEO', admin_review_notes=p_notes, updated_at=now() WHERE id=p_shoutout;
    INSERT INTO public.notifications (recipient_id, event_type, title, message, related_entity_type, related_entity_id)
      VALUES (r.partner_id, 'SHOUTOUT_VIDEO_NEEDED_PARTNER', 'Rework needed',
              COALESCE(p_notes,'Please redo this shout-out video.'), 'shoutout', p_shoutout);
    INSERT INTO public.audit_log (actor_id, actor_role, action, target_type, target_id, new_value)
      VALUES (p_admin,'ADMIN','RESOLVE_SHOUTOUT_REPORT','shout_out_request',p_shoutout, jsonb_build_object('action','REWORK'));
    RETURN jsonb_build_object('success',true,'reworked',true);
  ELSE
    UPDATE public.shout_out_requests SET status='VIDEO_DELIVERED_TO_FAN', admin_review_notes=p_notes, updated_at=now() WHERE id=p_shoutout;
    INSERT INTO public.audit_log (actor_id, actor_role, action, target_type, target_id, new_value)
      VALUES (p_admin,'ADMIN','RESOLVE_SHOUTOUT_REPORT','shout_out_request',p_shoutout, jsonb_build_object('action','DISMISS'));
    RETURN jsonb_build_object('success',true,'dismissed',true);
  END IF;
END $$;

-- ── Retrofit: blocking, referral, waitlist, partner self-service (0018/0020) ──
CREATE OR REPLACE FUNCTION rpc_block_user(p_blocker uuid, p_blocked uuid, p_scope block_scope DEFAULT 'ALL', p_by_admin boolean DEFAULT false, p_reason text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM public.assert_caller(p_blocker);
  INSERT INTO public.user_blocks (blocker_id, blocked_id, scope, reason, created_by_admin)
    VALUES (p_blocker, p_blocked, p_scope, p_reason, p_by_admin)
    ON CONFLICT (blocker_id, blocked_id, scope) DO NOTHING;
  RETURN jsonb_build_object('success',true);
END $$;

CREATE OR REPLACE FUNCTION rpc_unblock_user(p_blocker uuid, p_blocked uuid, p_scope block_scope DEFAULT 'ALL')
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM public.assert_caller(p_blocker);
  DELETE FROM public.user_blocks WHERE blocker_id=p_blocker AND blocked_id=p_blocked AND scope=p_scope;
  RETURN jsonb_build_object('success',true);
END $$;

CREATE OR REPLACE FUNCTION rpc_admin_set_account_status(p_admin uuid, p_user uuid, p_status user_account_status, p_reason text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM public.assert_is_admin_actor(p_admin);
  UPDATE public.profiles SET account_status=p_status, status_reason=p_reason,
    status_changed_at=now(), status_changed_by=p_admin, updated_at=now() WHERE id=p_user;
  IF NOT FOUND THEN RETURN jsonb_build_object('success',false,'error','USER_NOT_FOUND'); END IF;
  INSERT INTO public.audit_log (actor_id, actor_role, action, target_type, target_id, new_value)
    VALUES (p_admin,'ADMIN','SET_ACCOUNT_STATUS','profile',p_user, jsonb_build_object('status',p_status,'reason',p_reason));
  RETURN jsonb_build_object('success',true);
END $$;

CREATE OR REPLACE FUNCTION rpc_admin_approve_partner(p_admin uuid, p_partner uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM public.assert_is_admin_actor(p_admin);
  UPDATE public.partner_profiles SET status='ACTIVE', approved_by_admin_id=p_admin, approved_at=now(), updated_at=now()
    WHERE profile_id=p_partner;
  IF NOT FOUND THEN RETURN jsonb_build_object('success',false,'error','NOT_FOUND'); END IF;
  UPDATE public.profiles SET verification_status='VERIFIED', updated_at=now() WHERE id=p_partner;
  INSERT INTO public.audit_log (actor_id, actor_role, action, target_type, target_id)
    VALUES (p_admin,'ADMIN','APPROVE_PARTNER','partner_profile',p_partner);
  RETURN jsonb_build_object('success',true);
END $$;

CREATE OR REPLACE FUNCTION rpc_admin_manage_kyc(p_admin uuid, p_user uuid, p_verified boolean, p_reason text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM public.assert_is_admin_actor(p_admin);
  UPDATE public.profiles SET
    verification_status = CASE WHEN p_verified THEN 'VERIFIED'::public.verification_status ELSE 'REJECTED'::public.verification_status END,
    kyc_verified_at = CASE WHEN p_verified THEN now() END,
    kyc_verified_by_admin_id = p_admin, kyc_rejection_reason = CASE WHEN NOT p_verified THEN p_reason END,
    updated_at=now() WHERE id=p_user;
  IF NOT FOUND THEN RETURN jsonb_build_object('success',false,'error','NOT_FOUND'); END IF;
  INSERT INTO public.audit_log (actor_id, actor_role, action, target_type, target_id, new_value)
    VALUES (p_admin,'ADMIN','MANAGE_KYC','profile',p_user, jsonb_build_object('verified',p_verified,'reason',p_reason));
  RETURN jsonb_build_object('success',true);
END $$;

CREATE OR REPLACE FUNCTION rpc_admin_set_commission(p_admin uuid, p_partner uuid, p_rate numeric)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM public.assert_is_admin_actor(p_admin);
  PERFORM public.assert_admin_role('FINANCE','SUPER_ADMIN');
  UPDATE public.partner_profiles SET commission_rate=p_rate, updated_at=now() WHERE profile_id=p_partner;
  IF NOT FOUND THEN RETURN jsonb_build_object('success',false,'error','NOT_FOUND'); END IF;
  INSERT INTO public.audit_log (actor_id, actor_role, action, target_type, target_id, new_value)
    VALUES (p_admin,'ADMIN','SET_COMMISSION','partner_profile',p_partner, jsonb_build_object('rate',p_rate));
  RETURN jsonb_build_object('success',true);
END $$;

CREATE OR REPLACE FUNCTION rpc_admin_toggle_featured(p_admin uuid, p_partner uuid, p_on boolean, p_reason text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM public.assert_is_admin_actor(p_admin);
  UPDATE public.partner_profiles SET is_featured=p_on,
    featured_at = CASE WHEN p_on THEN now() END, featured_by_admin_id = CASE WHEN p_on THEN p_admin END,
    featured_reason = CASE WHEN p_on THEN p_reason END, updated_at=now() WHERE profile_id=p_partner;
  IF NOT FOUND THEN RETURN jsonb_build_object('success',false,'error','NOT_FOUND'); END IF;
  -- was missing audit_log entirely (inconsistent with every other admin RPC) — fixed
  INSERT INTO public.audit_log (actor_id, actor_role, action, target_type, target_id, new_value)
    VALUES (p_admin,'ADMIN','TOGGLE_FEATURED','partner_profile',p_partner, jsonb_build_object('on',p_on,'reason',p_reason));
  RETURN jsonb_build_object('success',true);
END $$;

CREATE OR REPLACE FUNCTION rpc_admin_create_promo(p_admin uuid, p_code text, p_type promo_code_discount_type_enum,
  p_value numeric, p_applies promo_code_service_applicability_enum DEFAULT 'ALL',
  p_max_total int DEFAULT NULL, p_max_per_user int DEFAULT NULL, p_expiry timestamptz DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_id uuid;
BEGIN
  PERFORM public.assert_is_admin_actor(p_admin);
  PERFORM public.assert_admin_role('FINANCE','SUPER_ADMIN');
  IF p_value <= 0 THEN RETURN jsonb_build_object('success',false,'error','INVALID_VALUE'); END IF;
  INSERT INTO public.promo_codes (code, discount_type, discount_value, applies_to, max_uses_total, max_uses_per_user, expiry_date, created_by_admin_id)
    VALUES (upper(p_code), p_type, p_value, p_applies, p_max_total, p_max_per_user, p_expiry, p_admin) RETURNING id INTO v_id;
  INSERT INTO public.audit_log (actor_id, actor_role, action, target_type, target_id, new_value)
    VALUES (p_admin,'ADMIN','CREATE_PROMO','promo_code',v_id, jsonb_build_object('code',upper(p_code),'value',p_value));
  RETURN jsonb_build_object('success',true,'promo_id',v_id);
END $$;

CREATE OR REPLACE FUNCTION rpc_credit_referral(p_referee uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE r public.referrals; v_referrer_amt bigint; v_referee_amt bigint;
        v_rw uuid; v_ew uuid; v_budget bigint; v_total bigint;
BEGIN
  PERFORM public.assert_system();   -- API-triggered on qualifying event, not user-invoked
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

CREATE OR REPLACE FUNCTION rpc_join_waitlist(p_fan uuid, p_partner uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM public.assert_caller(p_fan);
  INSERT INTO public.waitlist (fan_id, partner_id) VALUES (p_fan, p_partner)
    ON CONFLICT (fan_id, partner_id) DO NOTHING;
  RETURN jsonb_build_object('success',true);
END $$;

CREATE OR REPLACE FUNCTION rpc_notify_waitlist(p_partner uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_count int;
BEGIN
  PERFORM public.assert_caller(p_partner);   -- partner comes back online → triggers own fan-out; or system/admin
  INSERT INTO public.notifications (recipient_id, event_type, title, message, related_entity_type, related_entity_id)
    SELECT w.fan_id, 'PLATFORM_ANNOUNCEMENT', 'A creator is available',
           'A creator you follow is now available to book.', 'user_profile', p_partner
    FROM public.waitlist w WHERE w.partner_id=p_partner AND w.status='WAITING';
  GET DIAGNOSTICS v_count = ROW_COUNT;
  UPDATE public.waitlist SET status='NOTIFIED', notified_at=now()
    WHERE partner_id=p_partner AND status='WAITING';
  RETURN jsonb_build_object('success',true,'notified',v_count);
END $$;

CREATE OR REPLACE FUNCTION rpc_partner_set_availability(p_partner uuid, p_date date, p_minutes int)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM public.assert_caller(p_partner);
  IF p_minutes < 0 THEN RETURN jsonb_build_object('success',false,'error','INVALID_MINUTES'); END IF;
  INSERT INTO public.availability (partner_id, date, is_available, threshold_minutes)
    VALUES (p_partner, p_date, p_minutes > 0, p_minutes)
    ON CONFLICT (partner_id, date) DO UPDATE
      SET is_available = (p_minutes > 0), threshold_minutes = p_minutes, updated_at = now();
  RETURN jsonb_build_object('success',true,'date',p_date,'minutes',p_minutes,'available',p_minutes>0);
END $$;

CREATE OR REPLACE FUNCTION rpc_partner_set_service(
  p_partner uuid, p_type service_type_enum, p_duration call_duration_options_enum,
  p_price_paise bigint, p_active boolean DEFAULT true)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_min bigint; v_status public.account_status;
BEGIN
  PERFORM public.assert_caller(p_partner);
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

-- Re-assert the overload guard from 0022 — must still hold after all the
-- CREATE OR REPLACE calls above (same signatures throughout; this just proves it).
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

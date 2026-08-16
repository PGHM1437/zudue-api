-- Closes the two highest-severity gaps found in the 2026-08-17 notification
-- audit: (1) core booking/call lifecycle events create zero notifications —
-- of 14 live bookings, 5 completions, 4 fan cancellations, none produced a
-- single row; (2) 16 of 20 admin actions that change a fan's or partner's
-- state notify nobody through any channel — this migration covers the 4
-- most severe (account suspension/ban, KYC decision, both stages of partner
-- application review).
--
-- Every function here is already SECURITY DEFINER, owned by postgres with
-- rolbypassrls=true (verified live) — same as the working shoutout-notification
-- RPCs (rpc_admin_deliver_shoutout etc.), so these insert directly rather than
-- through rpc_create_notification; there is no RLS bypass needed inside an
-- already-bypassing function.
--
-- Not covered here (separate, larger follow-ups, not silently rolled in):
-- payment success/failure, payout notifications already exist and work,
-- welcome message, call reminders, the Questions feature (whose write-side
-- backend the research couldn't even confirm exists), and 12 of the 16
-- admin-action gaps (commission changes, payout-method reset, dispute/report
-- refunds, force-settle, partial-call resolution, featured/premium toggle,
-- social-link approval).

-- ── rpc_book_video_call: confirm the fan, alert the partner ──
create or replace function public.rpc_book_video_call(p_fan uuid, p_partner uuid, p_date date, p_duration call_duration_options_enum, p_note text DEFAULT NULL::text, p_promo_code text DEFAULT NULL::text)
 returns jsonb
 language plpgsql
 security definer
 set search_path to ''
as $function$
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

  -- Booking can only be created once per id, so ON CONFLICT here is belt and
  -- suspenders, not an expected path.
  INSERT INTO public.notifications (recipient_id, actor_id, event_type, title, message, related_entity_type, related_entity_id, metadata)
  SELECT p_fan, p_partner, 'VIDEO_CALL_BOOKING_CONFIRMED_FAN'::public.notification_event_type_enum,
         'Booking confirmed',
         'Your ' || v_mins || '-minute call with ' || COALESCE(pp.display_name, 'the creator') || ' on ' || to_char(p_date, 'FMDD Mon') || ' is confirmed.',
         'booking'::public.notification_related_entity_type_enum, v_booking,
         jsonb_build_object('bookingId', v_booking, 'scheduledDate', p_date)
  FROM public.partner_profiles pp WHERE pp.profile_id = p_partner
  ON CONFLICT (recipient_id, event_type, related_entity_type, related_entity_id) DO NOTHING;

  INSERT INTO public.notifications (recipient_id, actor_id, event_type, title, message, related_entity_type, related_entity_id, metadata)
  SELECT p_partner, p_fan, 'VIDEO_CALL_BOOKING_NEW_PARTNER'::public.notification_event_type_enum,
         'New booking',
         COALESCE(fp.full_name, 'A fan') || ' booked a ' || v_mins || '-minute call with you on ' || to_char(p_date, 'FMDD Mon') || '.',
         'booking'::public.notification_related_entity_type_enum, v_booking,
         jsonb_build_object('bookingId', v_booking, 'scheduledDate', p_date)
  FROM public.profiles fp WHERE fp.id = p_fan
  ON CONFLICT (recipient_id, event_type, related_entity_type, related_entity_id) DO NOTHING;

  RETURN jsonb_build_object('success',true,'booking_id',v_booking,'price_paise',v_final);
END $function$;

-- ── rpc_complete_call: tell both parties, whether the completion was a live
-- action or the automated deadline sweep (p_auto) ──
create or replace function public.rpc_complete_call(p_call uuid, p_auto boolean DEFAULT false)
 returns jsonb
 language plpgsql
 security definer
 set search_path to ''
as $function$
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

  INSERT INTO public.notifications (recipient_id, actor_id, event_type, title, message, related_entity_type, related_entity_id, metadata)
  VALUES
    (c.fan_id, c.partner_id, 'VIDEO_CALL_COMPLETED_FAN'::public.notification_event_type_enum, 'Call completed',
     'Your call has ended. We hope it was great!', 'call'::public.notification_related_entity_type_enum, c.id,
     jsonb_build_object('callId', c.id, 'bookingId', c.booking_id)),
    (c.partner_id, c.fan_id, 'VIDEO_CALL_COMPLETED_PARTNER'::public.notification_event_type_enum, 'Call completed',
     'Your call has ended. Earnings will be released after the review window.', 'call'::public.notification_related_entity_type_enum, c.id,
     jsonb_build_object('callId', c.id, 'bookingId', c.booking_id))
  ON CONFLICT (recipient_id, event_type, related_entity_type, related_entity_id) DO NOTHING;

  RETURN jsonb_build_object('success',true);
END $function$;

-- ── rpc_refund_booking: fan already sees the refund succeed in-app; the
-- gap was the partner never being told their booking fell through ──
create or replace function public.rpc_refund_booking(p_booking uuid, p_reason refund_reason)
 returns jsonb
 language plpgsql
 security definer
 set search_path to ''
as $function$
DECLARE b public.bookings; v_wallet uuid; v_res jsonb; v_mins int;
        v_gross bigint; v_disc bigint; v_legs jsonb;
BEGIN
  SELECT * INTO b FROM public.bookings WHERE id=p_booking FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('success',false,'error','NOT_FOUND'); END IF;
  PERFORM public.assert_caller(b.fan_id);
  IF b.status NOT IN ('BOOKED') THEN
    RETURN jsonb_build_object('success',false,'error','NOT_REFUNDABLE','status',b.status); END IF;
  IF now() > b.settle_at THEN
    RETURN jsonb_build_object('success',false,'error','PAST_REFUND_WINDOW'); END IF;

  v_gross := COALESCE(b.original_price_paise, b.price_paise);
  v_disc  := COALESCE(b.discount_paise, 0);

  SELECT id INTO v_wallet FROM public.wallets WHERE profile_id=b.fan_id;

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

  INSERT INTO public.notifications (recipient_id, actor_id, event_type, title, message, related_entity_type, related_entity_id, metadata)
  SELECT b.partner_id, b.fan_id, 'VIDEO_CALL_CANCELLED_PARTNER'::public.notification_event_type_enum,
         'Booking cancelled',
         COALESCE(fp.full_name, 'A fan') || ' cancelled their booking for ' || to_char(b.scheduled_date, 'FMDD Mon') || '.',
         'booking'::public.notification_related_entity_type_enum, b.id,
         jsonb_build_object('bookingId', b.id)
  FROM public.profiles fp WHERE fp.id = b.fan_id
  ON CONFLICT (recipient_id, event_type, related_entity_type, related_entity_id) DO NOTHING;

  RETURN jsonb_build_object('success',true,'transaction_id',v_res->>'transaction_id');
END $function$;

-- ── rpc_admin_set_account_status: no existing enum value fits "your account
-- status changed" precisely — PLATFORM_ANNOUNCEMENT is the closest honest
-- fit without adding a new enum value in this same migration (ALTER TYPE ADD
-- VALUE can't be used in the same transaction as its own use). Falls to the
-- client's generic bell icon, which is a reasonable default, not a mismatch. ──
create or replace function public.rpc_admin_set_account_status(p_admin uuid, p_user uuid, p_status user_account_status, p_reason text DEFAULT NULL::text)
 returns jsonb
 language plpgsql
 security definer
 set search_path to ''
as $function$
BEGIN
  PERFORM public.assert_is_admin_actor(p_admin);
  UPDATE public.profiles SET account_status=p_status, status_reason=p_reason,
    status_changed_at=now(), status_changed_by=p_admin, updated_at=now() WHERE id=p_user;
  IF NOT FOUND THEN RETURN jsonb_build_object('success',false,'error','USER_NOT_FOUND'); END IF;
  INSERT INTO public.audit_log (actor_id, actor_role, action, target_type, target_id, new_value)
    VALUES (p_admin,'ADMIN','SET_ACCOUNT_STATUS','profile',p_user, jsonb_build_object('status',p_status,'reason',p_reason));

  INSERT INTO public.notifications (recipient_id, actor_id, event_type, title, message, related_entity_type, related_entity_id, metadata)
  VALUES (p_user, p_admin, 'PLATFORM_ANNOUNCEMENT'::public.notification_event_type_enum,
    CASE WHEN p_status = 'ACTIVE' THEN 'Account reactivated' ELSE 'Account status changed' END,
    CASE WHEN p_status = 'ACTIVE' THEN 'Your account has been reactivated.'
         ELSE 'Your account status has changed to ' || p_status::text || '.' || COALESCE(' Reason: ' || p_reason, '') END,
    'user_profile'::public.notification_related_entity_type_enum, p_user,
    jsonb_build_object('status', p_status, 'reason', p_reason))
  ON CONFLICT (recipient_id, event_type, related_entity_type, related_entity_id)
  DO UPDATE SET is_read=false, created_at=now(), message=excluded.message, metadata=excluded.metadata;

  RETURN jsonb_build_object('success',true);
END $function$;

-- ── rpc_admin_manage_kyc: KYC_STATUS_UPDATE already exists in the enum,
-- exactly fits, and has simply never been used until now ──
create or replace function public.rpc_admin_manage_kyc(p_admin uuid, p_user uuid, p_verified boolean, p_reason text DEFAULT NULL::text)
 returns jsonb
 language plpgsql
 security definer
 set search_path to ''
as $function$
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

  INSERT INTO public.notifications (recipient_id, actor_id, event_type, title, message, related_entity_type, related_entity_id, metadata)
  VALUES (p_user, p_admin, 'KYC_STATUS_UPDATE'::public.notification_event_type_enum,
    CASE WHEN p_verified THEN 'KYC verified' ELSE 'KYC verification rejected' END,
    CASE WHEN p_verified THEN 'Your identity verification is complete.'
         ELSE 'Your KYC submission was rejected.' || COALESCE(' Reason: ' || p_reason, ' Please review and resubmit.') END,
    'user_profile'::public.notification_related_entity_type_enum, p_user,
    jsonb_build_object('verified', p_verified, 'reason', p_reason))
  ON CONFLICT (recipient_id, event_type, related_entity_type, related_entity_id)
  DO UPDATE SET is_read=false, created_at=now(), message=excluded.message, metadata=excluded.metadata;

  RETURN jsonb_build_object('success',true);
END $function$;

-- ── rpc_admin_review_application (stage 1) and rpc_admin_final_approve_partner
-- (stage 3): PARTNER_APPLICATION_STATUS_UPDATE already exists and already has
-- exactly one live row (from the unrelated role-toggle RPC) — this wires the
-- actual application flow into the same, correctly-named event type. ──
create or replace function public.rpc_admin_review_application(p_admin uuid, p_application uuid, p_decision text, p_reason text DEFAULT NULL::text)
 returns jsonb
 language plpgsql
 security definer
 set search_path to ''
as $function$
DECLARE a public.partner_applications;
BEGIN
  PERFORM public.assert_is_admin_actor(p_admin);
  SELECT * INTO a FROM public.partner_applications WHERE id = p_application FOR UPDATE;
  IF NOT FOUND OR a.status <> 'PENDING_INITIAL_REVIEW' THEN
    RETURN jsonb_build_object('success',false,'error','NOT_IN_INITIAL_REVIEW'); END IF;

  UPDATE public.partner_applications
     SET status = CASE WHEN p_decision='APPROVE' THEN 'AWAITING_KYC_AND_PROFILE_COMPLETION'::public.partner_application_status_enum
                       ELSE 'REJECTED_INITIAL'::public.partner_application_status_enum END,
         admin_notes = p_reason, initial_review_at = now(), initial_reviewed_by_admin_id = p_admin, updated_at = now()
   WHERE id = p_application;
  INSERT INTO public.audit_log (actor_id, actor_role, action, target_type, target_id, new_value)
    VALUES (p_admin,'ADMIN','REVIEW_APPLICATION_INITIAL','partner_application',p_application,
      jsonb_build_object('decision',p_decision,'reason',p_reason));

  IF a.profile_id IS NOT NULL THEN
    INSERT INTO public.notifications (recipient_id, actor_id, event_type, title, message, related_entity_type, related_entity_id, metadata)
    VALUES (a.profile_id, p_admin, 'PARTNER_APPLICATION_STATUS_UPDATE'::public.notification_event_type_enum,
      CASE WHEN p_decision='APPROVE' THEN 'Application moving forward' ELSE 'Application update' END,
      CASE WHEN p_decision='APPROVE' THEN 'Your creator application passed initial review — complete your KYC and profile to continue.'
           ELSE 'Your creator application was not approved at this stage.' || COALESCE(' Reason: ' || p_reason, '') END,
      'user_profile'::public.notification_related_entity_type_enum, a.profile_id,
      jsonb_build_object('applicationId', p_application, 'decision', p_decision, 'reason', p_reason))
    ON CONFLICT (recipient_id, event_type, related_entity_type, related_entity_id)
    DO UPDATE SET is_read=false, created_at=now(), message=excluded.message, metadata=excluded.metadata;
  END IF;

  RETURN jsonb_build_object('success',true,'decision',p_decision);
END $function$;

create or replace function public.rpc_admin_final_approve_partner(p_admin uuid, p_application uuid, p_decision text, p_reason text DEFAULT NULL::text)
 returns jsonb
 language plpgsql
 security definer
 set search_path to ''
as $function$
DECLARE a public.partner_applications;
BEGIN
  PERFORM public.assert_is_admin_actor(p_admin);
  SELECT * INTO a FROM public.partner_applications WHERE id = p_application FOR UPDATE;
  IF NOT FOUND OR a.status <> 'PENDING_FINAL_ADMIN_APPROVAL' THEN
    RETURN jsonb_build_object('success',false,'error','NOT_IN_FINAL_REVIEW'); END IF;

  IF p_decision = 'APPROVE' THEN
    UPDATE public.partner_applications SET status='ACTIVE', final_review_at=now(),
      final_reviewed_by_admin_id=p_admin, updated_at=now() WHERE id=p_application;
    IF a.profile_id IS NOT NULL THEN
      UPDATE public.partner_profiles SET status='ACTIVE', approved_by_admin_id=p_admin, approved_at=now(), updated_at=now()
        WHERE profile_id=a.profile_id;
      UPDATE public.profiles SET verification_status='VERIFIED', updated_at=now() WHERE id=a.profile_id;
    END IF;
  ELSE
    UPDATE public.partner_applications SET status='REJECTED_FINAL', admin_notes=p_reason,
      final_review_at=now(), final_reviewed_by_admin_id=p_admin, updated_at=now() WHERE id=p_application;
    IF a.profile_id IS NOT NULL THEN
      UPDATE public.partner_profiles SET status='REJECTED_ONBOARDING', rejection_reason=p_reason, updated_at=now()
        WHERE profile_id=a.profile_id;
    END IF;
  END IF;
  INSERT INTO public.audit_log (actor_id, actor_role, action, target_type, target_id, new_value)
    VALUES (p_admin,'ADMIN','REVIEW_APPLICATION_FINAL','partner_application',p_application,
      jsonb_build_object('decision',p_decision,'reason',p_reason));

  IF a.profile_id IS NOT NULL THEN
    INSERT INTO public.notifications (recipient_id, actor_id, event_type, title, message, related_entity_type, related_entity_id, metadata)
    VALUES (a.profile_id, p_admin, 'PARTNER_APPLICATION_STATUS_UPDATE'::public.notification_event_type_enum,
      CASE WHEN p_decision='APPROVE' THEN 'You''re a creator on Zudue!' ELSE 'Application update' END,
      CASE WHEN p_decision='APPROVE' THEN 'Your creator application was approved. Set up your services and availability to start earning.'
           ELSE 'Your creator application was not approved.' || COALESCE(' Reason: ' || p_reason, '') END,
      'user_profile'::public.notification_related_entity_type_enum, a.profile_id,
      jsonb_build_object('applicationId', p_application, 'decision', p_decision, 'reason', p_reason))
    ON CONFLICT (recipient_id, event_type, related_entity_type, related_entity_id)
    DO UPDATE SET is_read=false, created_at=now(), message=excluded.message, metadata=excluded.metadata;
  END IF;

  RETURN jsonb_build_object('success',true,'decision',p_decision);
END $function$;

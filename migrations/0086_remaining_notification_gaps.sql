-- Second and final batch closing the 2026-08-17 notification audit's
-- remaining gaps: wallet top-up success/failure, welcome message, the
-- Questions (paid-DM) lifecycle, and 8 more admin actions.
--
-- Every function is SECURITY DEFINER, owned by postgres, rolbypassrls=true
-- (verified live) — inserts go direct, same as 0085.
--
-- Deliberately NOT included, with reasons (not silently skipped):
--   - rpc_settle_booking / rpc_settle_window / rpc_settle_shoutout (and by
--     extension rpc_admin_force_settle_*, which call these) — "your earnings
--     were released from escrow" has no fitting event_type. PAYOUT_PROCESSED_PARTNER
--     means money left the platform to the partner's bank, a materially later
--     and different step (rpc_process_payout) — using it here would tell a
--     partner they were paid when they weren't yet. Needs a new enum value
--     (EARNINGS_AVAILABLE_PARTNER or similar) in its own migration, since
--     ALTER TYPE ADD VALUE cannot be used in the same transaction as its use.
--   - rpc_admin_resolve_dispute — checked disputes' live schema: it has no
--     fan_id/partner_id/profile_id column, only transaction_id. There is no
--     reliable way to identify "the affected user" without guessing, and a
--     Razorpay-level chargeback is arguably a platform-vs-processor event the
--     fan/partner has no action to take on anyway (their own transaction
--     already resolved through the normal booking/refund notifications).
--   - Call/question reminder types (VIDEO_CALL_REMINDER_*, QUESTION_ANSWER_REMINDER_PARTNER)
--     — these are time-based, not event-triggered, and would need a NEW scheduled
--     job to fire them. BullMQ is confirmed not running; code that only a
--     non-running scheduler could ever invoke is dead code, not a real fix.

-- ── rpc_verify_topup: wallet top-up succeeded ──
create or replace function public.rpc_verify_topup(p_razorpay_order_id text, p_razorpay_payment_id text)
 returns jsonb
 language plpgsql
 security definer
 set search_path to ''
as $function$
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

  INSERT INTO public.notifications (recipient_id, event_type, title, message, related_entity_type, related_entity_id, metadata)
  VALUES (v_order.profile_id, 'PAYMENT_SUCCESSFUL_FAN'::public.notification_event_type_enum,
    'Top-up successful',
    'Your wallet has been credited.',
    'system'::public.notification_related_entity_type_enum, v_order.id,
    jsonb_build_object('topupOrderId', v_order.id, 'creditPaise', v_order.credit_paise))
  ON CONFLICT (recipient_id, event_type, related_entity_type, related_entity_id) DO NOTHING;

  RETURN jsonb_build_object('success',true,'transaction_id',v_res->>'transaction_id');
END $function$;

-- ── rpc_cleanup_abandoned_topups: wallet top-up abandoned/failed. Restructured
-- from a bulk UPDATE to a FOR-loop over UPDATE...RETURNING so each abandoned
-- order gets its own notification — v_count still counts exactly the rows
-- updated, same as before, this is not a behaviour change to the return value. ──
create or replace function public.rpc_cleanup_abandoned_topups()
 returns jsonb
 language plpgsql
 security definer
 set search_path to ''
as $function$
DECLARE v_count int := 0; r record;
BEGIN
  PERFORM public.assert_system();

  FOR r IN
    UPDATE public.topup_orders
       SET status = 'FAILED',
           error_message = COALESCE(error_message, 'Abandoned: no payment confirmation within 24 hours'),
           updated_at = now()
     WHERE status = 'PENDING'
       AND created_at < now() - interval '24 hours'
    RETURNING id, profile_id, amount_paise
  LOOP
    v_count := v_count + 1;
    INSERT INTO public.notifications (recipient_id, event_type, title, message, related_entity_type, related_entity_id, metadata)
    VALUES (r.profile_id, 'PAYMENT_FAILED_FAN'::public.notification_event_type_enum,
      'Top-up not completed',
      'Your wallet top-up attempt did not go through and has been cancelled. No amount was charged.',
      'system'::public.notification_related_entity_type_enum, r.id,
      jsonb_build_object('topupOrderId', r.id, 'amountPaise', r.amount_paise))
    ON CONFLICT (recipient_id, event_type, related_entity_type, related_entity_id) DO NOTHING;
  END LOOP;

  RETURN jsonb_build_object('success', true, 'marked_failed', v_count);
END $function$;

-- ── rpc_ask_question: notify the partner only when a NEW window opens (first
-- question, or first paid follow-up after a prior window closed) — not on
-- every message within an already-open window, matching what
-- QUESTION_NEW_REQUEST_PARTNER actually names. ──
create or replace function public.rpc_ask_question(p_fan uuid, p_partner uuid, p_text text)
 returns jsonb
 language plpgsql
 security definer
 set search_path to ''
as $function$
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

  INSERT INTO public.notifications (recipient_id, actor_id, event_type, title, message, related_entity_type, related_entity_id, metadata)
  SELECT p_partner, p_fan, 'QUESTION_NEW_REQUEST_PARTNER'::public.notification_event_type_enum,
         'New question',
         COALESCE(fp.full_name, 'A fan') || ' asked you a question.',
         'question'::public.notification_related_entity_type_enum, v_new_win,
         jsonb_build_object('conversationId', v_conv, 'windowId', v_new_win)
  FROM public.profiles fp WHERE fp.id = p_fan
  ON CONFLICT (recipient_id, event_type, related_entity_type, related_entity_id) DO NOTHING;

  RETURN jsonb_build_object('success',true,'window_id',v_new_win,
    'kind', CASE WHEN v_any_window THEN 'PAID' ELSE 'FREE' END, 'charged', v_any_window);
END $function$;

-- ── rpc_partner_answer: notify the fan only on the FIRST reply that closes
-- the OPEN window (matches QUESTION_ANSWERED_BY_PARTNER_FAN's own name — a
-- later follow-up into an already-ANSWERED window isn't "the answer" again). ──
create or replace function public.rpc_partner_answer(p_partner uuid, p_conversation uuid, p_text text)
 returns jsonb
 language plpgsql
 security definer
 set search_path to ''
as $function$
DECLARE
  v_win public.conversation_windows;
  v_conv_partner uuid;
  v_conv_fan uuid;
  v_settlement_days int;
  v_was_open boolean;
BEGIN
  SELECT partner_id, fan_id INTO v_conv_partner, v_conv_fan FROM public.conversations WHERE id=p_conversation;
  IF v_conv_partner IS NULL THEN RETURN jsonb_build_object('success',false,'error','NOT_FOUND'); END IF;
  PERFORM public.assert_caller(v_conv_partner);
  IF p_partner IS DISTINCT FROM v_conv_partner THEN
    RETURN jsonb_build_object('success',false,'error','PARTNER_MISMATCH'); END IF;

  -- Reply into the latest window whether it is still OPEN or already ANSWERED:
  -- the partner keeps talking until the fan opens a new paid window. Only a
  -- conversation the fan never opened (no window at all) is rejected.
  SELECT * INTO v_win FROM public.conversation_windows
    WHERE conversation_id=p_conversation AND status IN ('OPEN','ANSWERED')
    ORDER BY opened_at DESC LIMIT 1 FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('success',false,'error','NO_WINDOW',
      'hint','the fan has not opened a paid conversation yet'); END IF;

  INSERT INTO public.messages (window_id, sender, body) VALUES (v_win.id,'PARTNER',p_text);

  -- First reply to an OPEN window consumes the fan's paid turn. The settle job
  -- captures escrow off ANSWERED, so flip it exactly once; later replies leave
  -- it ANSWERED (no double settle).
  -- Uses platform_settings.settlement_window_days for consistency with other services.
  v_was_open := (v_win.status = 'OPEN');
  IF v_was_open THEN
    SELECT settlement_window_days INTO v_settlement_days FROM public.platform_settings WHERE id=1;

    UPDATE public.conversation_windows
    SET status='ANSWERED',
        closed_at=now(),
        settle_at=now() + (v_settlement_days * interval '1 day')
    WHERE id=v_win.id;
  END IF;

  UPDATE public.conversations SET last_activity_at=now() WHERE id=p_conversation;

  IF v_was_open THEN
    INSERT INTO public.notifications (recipient_id, actor_id, event_type, title, message, related_entity_type, related_entity_id, metadata)
    SELECT v_conv_fan, p_partner, 'QUESTION_ANSWERED_BY_PARTNER_FAN'::public.notification_event_type_enum,
           'Your question was answered',
           COALESCE(pp.display_name, 'The creator') || ' replied to your question.',
           'question'::public.notification_related_entity_type_enum, v_win.id,
           jsonb_build_object('conversationId', p_conversation, 'windowId', v_win.id)
    FROM public.partner_profiles pp WHERE pp.profile_id = p_partner
    ON CONFLICT (recipient_id, event_type, related_entity_type, related_entity_id) DO NOTHING;
  END IF;

  RETURN jsonb_build_object('success',true,'window_id',v_win.id);
END $function$;

-- ── rpc_admin_toggle_featured / _premium / _set_commission / _approve_social_link
-- / _reset_payout_methods: all partner-facing, all PLATFORM_ANNOUNCEMENT —
-- none of these map to a more specific existing event_type. ──
create or replace function public.rpc_admin_toggle_featured(p_admin uuid, p_partner uuid, p_on boolean, p_reason text DEFAULT NULL::text)
 returns jsonb
 language plpgsql
 security definer
 set search_path to ''
as $function$
BEGIN
  PERFORM public.assert_is_admin_actor(p_admin);
  UPDATE public.partner_profiles SET is_featured=p_on,
    featured_at = CASE WHEN p_on THEN now() END, featured_by_admin_id = CASE WHEN p_on THEN p_admin END,
    featured_reason = CASE WHEN p_on THEN p_reason END, updated_at=now() WHERE profile_id=p_partner;
  IF NOT FOUND THEN RETURN jsonb_build_object('success',false,'error','NOT_FOUND'); END IF;
  -- was missing audit_log entirely (inconsistent with every other admin RPC) — fixed
  INSERT INTO public.audit_log (actor_id, actor_role, action, target_type, target_id, new_value)
    VALUES (p_admin,'ADMIN','TOGGLE_FEATURED','partner_profile',p_partner, jsonb_build_object('on',p_on,'reason',p_reason));

  INSERT INTO public.notifications (recipient_id, actor_id, event_type, title, message, related_entity_type, related_entity_id, metadata)
  VALUES (p_partner, p_admin, 'PLATFORM_ANNOUNCEMENT'::public.notification_event_type_enum,
    CASE WHEN p_on THEN 'You''re featured!' ELSE 'Featured status removed' END,
    CASE WHEN p_on THEN 'Your profile is now featured on Discover.' ELSE 'Your profile is no longer featured.' END,
    'user_profile'::public.notification_related_entity_type_enum, p_partner,
    jsonb_build_object('featured', p_on))
  ON CONFLICT (recipient_id, event_type, related_entity_type, related_entity_id)
  DO UPDATE SET is_read=false, created_at=now(), message=excluded.message, metadata=excluded.metadata;

  RETURN jsonb_build_object('success',true);
END $function$;

create or replace function public.rpc_admin_toggle_premium(p_admin uuid, p_partner uuid, p_on boolean, p_reason text DEFAULT NULL::text)
 returns jsonb
 language plpgsql
 security definer
 set search_path to ''
as $function$
BEGIN
  PERFORM public.assert_is_admin_actor(p_admin);
  UPDATE public.partner_profiles SET is_premium=p_on,
    premium_at = CASE WHEN p_on THEN now() END, premium_by_admin_id = CASE WHEN p_on THEN p_admin END,
    premium_reason = CASE WHEN p_on THEN p_reason END, updated_at=now() WHERE profile_id=p_partner;
  IF NOT FOUND THEN RETURN jsonb_build_object('success',false,'error','NOT_FOUND'); END IF;
  INSERT INTO public.audit_log (actor_id, actor_role, action, target_type, target_id, new_value)
    VALUES (p_admin,'ADMIN','TOGGLE_PREMIUM','partner_profile',p_partner, jsonb_build_object('on',p_on,'reason',p_reason));

  INSERT INTO public.notifications (recipient_id, actor_id, event_type, title, message, related_entity_type, related_entity_id, metadata)
  VALUES (p_partner, p_admin, 'PLATFORM_ANNOUNCEMENT'::public.notification_event_type_enum,
    CASE WHEN p_on THEN 'Premium status granted' ELSE 'Premium status removed' END,
    CASE WHEN p_on THEN 'Your profile now has premium status.' ELSE 'Your premium status has been removed.' END,
    'user_profile'::public.notification_related_entity_type_enum, p_partner,
    jsonb_build_object('premium', p_on))
  ON CONFLICT (recipient_id, event_type, related_entity_type, related_entity_id)
  DO UPDATE SET is_read=false, created_at=now(), message=excluded.message, metadata=excluded.metadata;

  RETURN jsonb_build_object('success',true);
END $function$;

create or replace function public.rpc_admin_set_commission(p_admin uuid, p_partner uuid, p_rate numeric)
 returns jsonb
 language plpgsql
 security definer
 set search_path to ''
as $function$
BEGIN
  PERFORM public.assert_is_admin_actor(p_admin);
  PERFORM public.assert_admin_role('FINANCE','SUPER_ADMIN');
  UPDATE public.partner_profiles SET commission_rate=p_rate, updated_at=now() WHERE profile_id=p_partner;
  IF NOT FOUND THEN RETURN jsonb_build_object('success',false,'error','NOT_FOUND'); END IF;
  INSERT INTO public.audit_log (actor_id, actor_role, action, target_type, target_id, new_value)
    VALUES (p_admin,'ADMIN','SET_COMMISSION','partner_profile',p_partner, jsonb_build_object('rate',p_rate));

  INSERT INTO public.notifications (recipient_id, actor_id, event_type, title, message, related_entity_type, related_entity_id, metadata)
  VALUES (p_partner, p_admin, 'PLATFORM_ANNOUNCEMENT'::public.notification_event_type_enum,
    'Commission rate updated',
    'Your commission rate has been updated to ' || p_rate || '%.',
    'user_profile'::public.notification_related_entity_type_enum, p_partner,
    jsonb_build_object('rate', p_rate))
  ON CONFLICT (recipient_id, event_type, related_entity_type, related_entity_id)
  DO UPDATE SET is_read=false, created_at=now(), message=excluded.message, metadata=excluded.metadata;

  RETURN jsonb_build_object('success',true);
END $function$;

create or replace function public.rpc_admin_approve_social_link(p_admin uuid, p_link uuid, p_approved boolean)
 returns jsonb
 language plpgsql
 security definer
 set search_path to ''
as $function$
DECLARE v_partner uuid;
BEGIN
  PERFORM public.assert_is_admin_actor(p_admin);
  UPDATE public.partner_social_links SET is_approved=p_approved,
    approved_by_admin_id = CASE WHEN p_approved THEN p_admin END, updated_at=now()
    WHERE id=p_link
    RETURNING partner_id INTO v_partner;
  IF NOT FOUND THEN RETURN jsonb_build_object('success',false,'error','NOT_FOUND'); END IF;
  INSERT INTO public.audit_log (actor_id, actor_role, action, target_type, target_id, new_value)
    VALUES (p_admin,'ADMIN','APPROVE_SOCIAL_LINK','partner_social_link',p_link, jsonb_build_object('approved',p_approved));

  INSERT INTO public.notifications (recipient_id, actor_id, event_type, title, message, related_entity_type, related_entity_id, metadata)
  VALUES (v_partner, p_admin, 'PLATFORM_ANNOUNCEMENT'::public.notification_event_type_enum,
    CASE WHEN p_approved THEN 'Social link approved' ELSE 'Social link rejected' END,
    CASE WHEN p_approved THEN 'Your social link is now visible on your profile.' ELSE 'Your social link submission was rejected.' END,
    'user_profile'::public.notification_related_entity_type_enum, v_partner,
    jsonb_build_object('linkId', p_link, 'approved', p_approved))
  ON CONFLICT (recipient_id, event_type, related_entity_type, related_entity_id)
  DO UPDATE SET is_read=false, created_at=now(), message=excluded.message, metadata=excluded.metadata;

  RETURN jsonb_build_object('success',true);
END $function$;

create or replace function public.rpc_admin_reset_payout_methods(p_admin uuid, p_partner uuid)
 returns jsonb
 language plpgsql
 security definer
 set search_path to ''
as $function$
DECLARE v_count int;
BEGIN
  PERFORM public.assert_is_admin_actor(p_admin);
  UPDATE public.payout_methods
     SET is_verified = false, verified_by_admin_id = NULL, verified_at = NULL, updated_at = now()
   WHERE partner_id = p_partner AND is_verified;
  GET DIAGNOSTICS v_count = ROW_COUNT;
  INSERT INTO public.audit_log (actor_id, actor_role, action, target_type, target_id, new_value)
    VALUES (p_admin,'ADMIN','RESET_PAYOUT_METHODS','partner_profile',p_partner,
      jsonb_build_object('methods_reset', v_count));

  IF v_count > 0 THEN
    INSERT INTO public.notifications (recipient_id, actor_id, event_type, title, message, related_entity_type, related_entity_id, metadata)
    VALUES (p_partner, p_admin, 'PLATFORM_ANNOUNCEMENT'::public.notification_event_type_enum,
      'Payout method needs re-verification',
      v_count || ' of your payout method(s) need to be re-verified before you can withdraw.',
      'user_profile'::public.notification_related_entity_type_enum, p_partner,
      jsonb_build_object('methodsReset', v_count))
    ON CONFLICT (recipient_id, event_type, related_entity_type, related_entity_id)
    DO UPDATE SET is_read=false, created_at=now(), message=excluded.message, metadata=excluded.metadata;
  END IF;

  RETURN jsonb_build_object('success', true, 'methods_reset', v_count,
    'message', v_count || ' payout method(s) marked unverified; partner must resubmit.');
END $function$;

-- ── rpc_admin_resolve_report: the reporter is told their report was resolved
-- (PLATFORM_ANNOUNCEMENT — no report-specific type exists); if money moved,
-- the refunded fan ALSO gets REFUND_PROCESSED_FAN, a clean, exact fit. ──
create or replace function public.rpc_admin_resolve_report(p_admin uuid, p_report uuid, p_status report_status, p_resolution text DEFAULT NULL::text, p_refund_paise bigint DEFAULT NULL::bigint)
 returns jsonb
 language plpgsql
 security definer
 set search_path to ''
as $function$
DECLARE rep public.reports; v_wallet uuid; v_res jsonb; v_amt bigint;
        v_window public.conversation_windows; v_call public.calls; v_booking public.bookings;
        v_refund_fan uuid;
BEGIN
  PERFORM public.assert_is_admin_actor(p_admin);
  SELECT * INTO rep FROM public.reports WHERE id=p_report FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('success',false,'error','NOT_FOUND'); END IF;

  IF p_refund_paise IS NOT NULL AND p_refund_paise > 0 THEN
    PERFORM public.assert_admin_role('FINANCE','SUPER_ADMIN');

    IF rep.target_type = 'CALL' THEN
      SELECT * INTO v_call FROM public.calls WHERE id=rep.target_id;
      IF NOT FOUND THEN RETURN jsonb_build_object('success',false,'error','CALL_NOT_FOUND'); END IF;
      SELECT * INTO v_booking FROM public.bookings WHERE id=v_call.booking_id FOR UPDATE;
      IF NOT FOUND OR v_booking.status <> 'COMPLETED_SUCCESSFUL' OR now() > v_booking.settle_at THEN
        RETURN jsonb_build_object('success',false,'error','NOT_REFUNDABLE',
          'hint','use rpc_refund_booking for a pre-settlement cancellation instead'); END IF;
      v_amt := least(p_refund_paise, v_booking.price_paise);
      v_refund_fan := v_booking.fan_id;
      SELECT id INTO v_wallet FROM public.wallets WHERE profile_id=v_booking.fan_id;
      v_res := public.post_transaction('REFUND', v_amt, 'report-refund:'||rep.id::text,
        jsonb_build_array(
          jsonb_build_object('account','booking_escrow','delta_paise',-v_amt),
          jsonb_build_object('wallet_id',v_wallet,'account','wallet','delta_paise',v_amt)),
        rep.id::text);
      UPDATE public.transactions SET refund_reason='DISPUTE' WHERE id=(v_res->>'transaction_id')::uuid;
      UPDATE public.bookings SET status='CANCELLED_BY_ADMIN', updated_at=now() WHERE id=v_booking.id;

    ELSIF rep.target_type = 'DM' THEN
      SELECT * INTO v_window FROM public.conversation_windows WHERE id=rep.target_id FOR UPDATE;
      IF NOT FOUND OR v_window.kind <> 'PAID' OR v_window.status = 'REFUNDED' OR now() > v_window.settle_at THEN
        RETURN jsonb_build_object('success',false,'error','NOT_REFUNDABLE'); END IF;
      v_amt := least(p_refund_paise, v_window.charge_paise);
      SELECT c.fan_id, w.id INTO v_refund_fan, v_wallet
        FROM public.conversations c JOIN public.wallets w ON w.profile_id = c.fan_id
        WHERE c.id = v_window.conversation_id;
      v_res := public.post_transaction('REFUND', v_amt, 'report-refund:'||rep.id::text,
        jsonb_build_array(
          jsonb_build_object('account','booking_escrow','delta_paise',-v_amt),
          jsonb_build_object('wallet_id',v_wallet,'account','wallet','delta_paise',v_amt)),
        rep.id::text);
      UPDATE public.transactions SET refund_reason='DISPUTE' WHERE id=(v_res->>'transaction_id')::uuid;
      UPDATE public.conversation_windows SET status='REFUNDED', updated_at=now() WHERE id=v_window.id;

    ELSE
      RETURN jsonb_build_object('success',false,'error','REFUND_NOT_SUPPORTED_FOR_TARGET_TYPE');
    END IF;

    INSERT INTO public.notifications (recipient_id, actor_id, event_type, title, message, related_entity_type, related_entity_id, metadata)
    VALUES (v_refund_fan, p_admin, 'REFUND_PROCESSED_FAN'::public.notification_event_type_enum,
      'Refund processed',
      'You''ve been refunded following a review of your report.',
      'system'::public.notification_related_entity_type_enum, p_report,
      jsonb_build_object('reportId', p_report, 'amountPaise', v_amt))
    ON CONFLICT (recipient_id, event_type, related_entity_type, related_entity_id) DO NOTHING;
  END IF;

  UPDATE public.reports SET status=p_status, resolution=p_resolution,
    refund_paise = COALESCE(p_refund_paise, refund_paise),
    resolved_by=p_admin, resolved_at=now() WHERE id=p_report;
  INSERT INTO public.audit_log (actor_id, actor_role, action, target_type, target_id, new_value)
    VALUES (p_admin,'ADMIN','RESOLVE_REPORT','report',p_report,
      jsonb_build_object('status',p_status,'resolution',p_resolution,'refund_paise',p_refund_paise));

  INSERT INTO public.notifications (recipient_id, actor_id, event_type, title, message, related_entity_type, related_entity_id, metadata)
  VALUES (rep.reporter_id, p_admin, 'PLATFORM_ANNOUNCEMENT'::public.notification_event_type_enum,
    'Your report was reviewed',
    'Our team has reviewed the report you filed.' || COALESCE(' ' || p_resolution, ''),
    'system'::public.notification_related_entity_type_enum, p_report,
    jsonb_build_object('reportId', p_report, 'status', p_status))
  ON CONFLICT (recipient_id, event_type, related_entity_type, related_entity_id)
  DO UPDATE SET is_read=false, created_at=now(), message=excluded.message, metadata=excluded.metadata;

  RETURN jsonb_build_object('success',true);
END $function$;

-- ── rpc_admin_expire_booking: refund path uses the exact-fit REFUND_PROCESSED_FAN.
-- The COMPLETED_SUCCESSFUL branch (admin manually confirming a call happened)
-- is left unnotified — VIDEO_CALL_COMPLETED_PARTNER names an actual call
-- ending, not an admin override with no call event behind it; forcing that
-- fit would misdescribe what happened. ──
create or replace function public.rpc_admin_expire_booking(p_admin uuid, p_booking uuid, p_status booking_status)
 returns jsonb
 language plpgsql
 security definer
 set search_path to ''
as $function$
DECLARE
  v_booking RECORD;
  v_gross bigint;
  v_disc bigint;
  v_wallet uuid;
  v_legs jsonb;
  v_mins int;
BEGIN
  -- Only FINANCE or SUPER_ADMIN can manually expire bookings (money operation).
  PERFORM public.assert_admin_role('FINANCE', 'SUPER_ADMIN');

  -- Validate the target status is a terminal state.
  IF p_status NOT IN ('COMPLETED_SUCCESSFUL', 'EXPIRED_PARTNER_NO_SHOW',
                       'EXPIRED_FAN_NO_JOIN', 'EXPIRED_FAN_DECLINED', 'EXPIRED_TECHNICAL_ISSUE') THEN
    RETURN jsonb_build_object('success', false, 'error', 'INVALID_STATUS');
  END IF;

  -- Fetch booking details for refund processing.
  SELECT
    id, fan_id, price_paise, original_price_paise, discount_paise,
    selected_duration, partner_id, scheduled_date, status
  INTO v_booking
  FROM public.bookings
  WHERE id = p_booking
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'NOT_FOUND');
  END IF;

  -- Refund if EXPIRED_* status (not COMPLETED_SUCCESSFUL).
  -- This mirrors the automated expiry logic exactly.
  IF p_status <> 'COMPLETED_SUCCESSFUL' THEN
    v_gross := COALESCE(v_booking.original_price_paise, v_booking.price_paise);
    v_disc := COALESCE(v_booking.discount_paise, 0);

    SELECT id INTO v_wallet FROM public.wallets WHERE profile_id = v_booking.fan_id;
    IF v_wallet IS NULL THEN
      RETURN jsonb_build_object('success', false, 'error', 'WALLET_NOT_FOUND');
    END IF;

    -- Build refund legs: escrow → fan wallet + (optionally) promo pool.
    v_legs := jsonb_build_array(
      jsonb_build_object('account', 'booking_escrow', 'delta_paise', -v_gross),
      jsonb_build_object('wallet_id', v_wallet, 'account', 'wallet', 'delta_paise', v_booking.price_paise)
    );
    IF v_disc > 0 THEN
      v_legs := v_legs || jsonb_build_array(
        jsonb_build_object('account', 'promo_incentive', 'delta_paise', v_disc)
      );
    END IF;

    -- Post the refund transaction.
    PERFORM public.post_transaction('REFUND', v_gross, 'admin-expire:'||p_booking::text, v_legs, p_booking::text);

    -- Release partner capacity.
    v_mins := (v_booking.selected_duration::text)::int;
    UPDATE public.availability
    SET booked_minutes = GREATEST(0, booked_minutes - v_mins)
    WHERE partner_id = v_booking.partner_id AND date = v_booking.scheduled_date;

    INSERT INTO public.notifications (recipient_id, actor_id, event_type, title, message, related_entity_type, related_entity_id, metadata)
    VALUES (v_booking.fan_id, p_admin, 'REFUND_PROCESSED_FAN'::public.notification_event_type_enum,
      'Refund processed',
      'Your booking was refunded following an admin review.',
      'booking'::public.notification_related_entity_type_enum, p_booking,
      jsonb_build_object('bookingId', p_booking, 'amountPaise', v_gross))
    ON CONFLICT (recipient_id, event_type, related_entity_type, related_entity_id) DO NOTHING;
  END IF;

  -- Update booking to terminal status.
  UPDATE public.bookings
  SET status = p_status, updated_at = now()
  WHERE id = p_booking;

  -- Audit log (matches existing admin RPC pattern).
  INSERT INTO public.audit_log (actor_id, actor_role, action, target_type, target_id, old_value, new_value)
  VALUES (p_admin, 'ADMIN', 'EXPIRE_BOOKING', 'BOOKING', p_booking,
          jsonb_build_object('status', v_booking.status),
          jsonb_build_object('status', p_status));

  RETURN jsonb_build_object('success', true, 'status', p_status);
END $function$;

-- ── rpc_admin_recover_call: rare admin action, no fitting specific type for
-- either party — PLATFORM_ANNOUNCEMENT, worded plainly for each recipient. ──
create or replace function public.rpc_admin_recover_call(p_admin uuid, p_booking_id uuid, p_reason text DEFAULT 'Admin manual recovery'::text)
 returns jsonb
 language plpgsql
 security definer
 set search_path to ''
as $function$
DECLARE
  v_call_id uuid;
  v_call_status public.call_status;
  v_booking_status public.booking_status;
  v_partner_id uuid;
  v_fan_id uuid;
BEGIN
  -- Only SUPER_ADMIN or SUPPORT can recover stuck calls.
  PERFORM public.assert_admin_role('SUPER_ADMIN', 'SUPPORT');

  -- Validate booking exists and is in a recoverable state.
  SELECT status, partner_id, fan_id
    INTO v_booking_status, v_partner_id, v_fan_id
    FROM public.bookings
   WHERE id = p_booking_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'BOOKING_NOT_FOUND');
  END IF;

  -- Only recover bookings that are still BOOKED or in a stuck terminal state.
  -- Already-settled bookings (COMPLETED_SUCCESSFUL, etc.) should not be touched.
  IF v_booking_status NOT IN ('BOOKED', 'EXPIRED_TECHNICAL_ISSUE', 'EXPIRED_PARTNER_NO_SHOW') THEN
    RETURN jsonb_build_object('success', false, 'error', 'NOT_RECOVERABLE',
            'booking_status', v_booking_status);
  END IF;

  -- Find active call (if any) for this booking.
  SELECT id, attempt_status INTO v_call_id, v_call_status
    FROM public.calls
   WHERE booking_id = p_booking_id
     AND attempt_status IN ('PARTNER_INITIATED', 'IN_PROGRESS')
   ORDER BY created_at DESC
   LIMIT 1;

  -- If there's an active call, mark it as dropped.
  IF v_call_id IS NOT NULL THEN
    UPDATE public.calls
       SET attempt_status = 'DROPPED_TECHNICAL_ISSUE',
           ended_at = now(),
           termination_reason = p_reason,
           updated_at = now()
     WHERE id = v_call_id;
  END IF;

  -- Set booking to EXPIRED_TECHNICAL_ISSUE.
  UPDATE public.bookings
     SET status = 'EXPIRED_TECHNICAL_ISSUE',
         cancellation_reason = p_reason,
         updated_at = now()
   WHERE id = p_booking_id
     AND status IN ('BOOKED', 'EXPIRED_TECHNICAL_ISSUE', 'EXPIRED_PARTNER_NO_SHOW');

  -- Audit log — matches the existing admin RPC pattern.
  INSERT INTO public.audit_log (actor_id, actor_role, action, target_type, target_id, old_value, new_value)
  VALUES (p_admin, 'ADMIN', 'ADMIN_CALL_RECOVERY', 'BOOKING', p_booking_id,
          jsonb_build_object(
            'booking_status', v_booking_status,
            'call_id', v_call_id,
            'call_status', v_call_status
          ),
          jsonb_build_object(
            'booking_status', 'EXPIRED_TECHNICAL_ISSUE',
            'call_status', CASE WHEN v_call_id IS NOT NULL THEN 'DROPPED_TECHNICAL_ISSUE' ELSE 'NO_CALL' END,
            'reason', p_reason
          ));

  INSERT INTO public.notifications (recipient_id, actor_id, event_type, title, message, related_entity_type, related_entity_id, metadata)
  VALUES
    (v_fan_id, p_admin, 'PLATFORM_ANNOUNCEMENT'::public.notification_event_type_enum, 'Call issue resolved',
     'We''ve resolved a technical issue with your call and refunded it per our policy.',
     'booking'::public.notification_related_entity_type_enum, p_booking_id,
     jsonb_build_object('bookingId', p_booking_id, 'reason', p_reason)),
    (v_partner_id, p_admin, 'PLATFORM_ANNOUNCEMENT'::public.notification_event_type_enum, 'Call issue resolved',
     'We''ve resolved a technical issue with a call on your queue.',
     'booking'::public.notification_related_entity_type_enum, p_booking_id,
     jsonb_build_object('bookingId', p_booking_id, 'reason', p_reason))
  ON CONFLICT (recipient_id, event_type, related_entity_type, related_entity_id)
  DO UPDATE SET is_read=false, created_at=now(), message=excluded.message, metadata=excluded.metadata;

  RETURN jsonb_build_object(
    'success', true,
    'booking_id', p_booking_id,
    'call_id', v_call_id,
    'call_dropped', v_call_id IS NOT NULL,
    'booking_status', 'EXPIRED_TECHNICAL_ISSUE'
  );
END $function$;

-- ── rpc_admin_resolve_partial_call: fan's portion is an exact REFUND_PROCESSED_FAN
-- fit; partner's portion has no specific "partial earning" type, PLATFORM_ANNOUNCEMENT. ──
create or replace function public.rpc_admin_resolve_partial_call(p_admin uuid, p_booking uuid, p_partner_paise bigint, p_fan_refund_paise bigint, p_notes text)
 returns jsonb
 language plpgsql
 security definer
 set search_path to ''
as $function$
DECLARE
  b public.bookings;
  v_wallet uuid;
  v_total bigint;
  v_partner_txn jsonb;
  v_refund_txn jsonb;
BEGIN
  PERFORM public.assert_is_admin_actor(p_admin);
  PERFORM public.assert_admin_role('FINANCE', 'SUPER_ADMIN');

  SELECT * INTO b FROM public.bookings WHERE id = p_booking FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'NOT_FOUND');
  END IF;

  IF b.status <> 'REQUIRES_ADMIN_REVIEW' THEN
    RETURN jsonb_build_object('success', false, 'error', 'INVALID_STATUS', 'status', b.status);
  END IF;

  -- Validate split adds up to original price
  v_total := COALESCE(b.original_price_paise, b.price_paise);
  IF p_partner_paise + p_fan_refund_paise <> v_total THEN
    RETURN jsonb_build_object('success', false, 'error', 'SPLIT_MISMATCH',
      'required_total', v_total, 'provided_total', p_partner_paise + p_fan_refund_paise);
  END IF;

  -- Idempotency check
  IF EXISTS (SELECT 1 FROM public.partner_earnings WHERE service_id = p_booking) THEN
    RETURN jsonb_build_object('success', true, 'already_resolved', true);
  END IF;

  -- Move partner portion from escrow to partner_payable
  IF p_partner_paise > 0 THEN
    v_partner_txn := public.post_transaction('PARTNER_EARNING', p_partner_paise,
      'partial-settle:' || b.id::text,
      jsonb_build_array(
        jsonb_build_object('account', 'booking_escrow', 'delta_paise', -p_partner_paise),
        jsonb_build_object('account', 'partner_payable', 'delta_paise', p_partner_paise)
      ),
      b.id::text);

    INSERT INTO public.partner_earnings (partner_id, transaction_id, service_type, service_id, amount_paise)
    VALUES (b.partner_id, (v_partner_txn->>'transaction_id')::uuid, 'VIDEO_CALL', b.id, p_partner_paise);

    INSERT INTO public.notifications (recipient_id, actor_id, event_type, title, message, related_entity_type, related_entity_id, metadata)
    VALUES (b.partner_id, p_admin, 'PLATFORM_ANNOUNCEMENT'::public.notification_event_type_enum,
      'Partial payment resolved',
      'A partially-completed call was reviewed — you''ve been paid your portion.',
      'booking'::public.notification_related_entity_type_enum, p_booking,
      jsonb_build_object('bookingId', p_booking, 'amountPaise', p_partner_paise))
    ON CONFLICT (recipient_id, event_type, related_entity_type, related_entity_id)
    DO UPDATE SET is_read=false, created_at=now(), message=excluded.message, metadata=excluded.metadata;
  END IF;

  -- Refund fan portion from escrow to fan wallet
  IF p_fan_refund_paise > 0 THEN
    SELECT id INTO v_wallet FROM public.wallets WHERE profile_id = b.fan_id;
    IF v_wallet IS NULL THEN
      RAISE EXCEPTION 'Wallet not found for fan %', b.fan_id;
    END IF;

    v_refund_txn := public.post_transaction('REFUND', p_fan_refund_paise,
      'partial-refund:' || b.id::text,
      jsonb_build_array(
        jsonb_build_object('account', 'booking_escrow', 'delta_paise', -p_fan_refund_paise),
        jsonb_build_object('wallet_id', v_wallet, 'account', 'wallet', 'delta_paise', p_fan_refund_paise)
      ),
      b.id::text);

    INSERT INTO public.notifications (recipient_id, actor_id, event_type, title, message, related_entity_type, related_entity_id, metadata)
    VALUES (b.fan_id, p_admin, 'REFUND_PROCESSED_FAN'::public.notification_event_type_enum,
      'Partial refund processed',
      'A partially-completed call was reviewed — you''ve been refunded your portion.',
      'booking'::public.notification_related_entity_type_enum, p_booking,
      jsonb_build_object('bookingId', p_booking, 'amountPaise', p_fan_refund_paise))
    ON CONFLICT (recipient_id, event_type, related_entity_type, related_entity_id) DO NOTHING;
  END IF;

  -- Mark booking as resolved
  UPDATE public.bookings
  SET status = 'COMPLETED_SUCCESSFUL',
      updated_at = now()
  WHERE id = p_booking;

  -- Log admin action
  INSERT INTO public.audit_log (actor_id, actor_role, action, target_type, target_id, new_value)
  VALUES (p_admin, 'ADMIN', 'RESOLVE_PARTIAL_CALL', 'booking', p_booking,
    jsonb_build_object(
      'partner_paise', p_partner_paise,
      'fan_refund_paise', p_fan_refund_paise,
      'notes', p_notes
    ));

  RETURN jsonb_build_object(
    'success', true,
    'partner_paise', p_partner_paise,
    'fan_refund_paise', p_fan_refund_paise,
    'partner_txn_id', v_partner_txn->>'transaction_id',
    'refund_txn_id', v_refund_txn->>'transaction_id'
  );
END $function$;

-- ── createProfile (identity.module.ts) needs a matching backend hook for
-- WELCOME_MESSAGE — added as a small callable RPC so the TS layer can invoke
-- it right after the profile insert without another raw cross-user insert. ──
create or replace function public.rpc_send_welcome_notification(p_user uuid)
 returns jsonb
 language plpgsql
 security definer
 set search_path to ''
as $function$
BEGIN
  INSERT INTO public.notifications (recipient_id, event_type, title, message, related_entity_type, related_entity_id, metadata)
  VALUES (p_user, 'WELCOME_MESSAGE'::public.notification_event_type_enum,
    'Welcome to Zudue',
    'Browse creators, book a call, or ask a question to get started.',
    'user_profile'::public.notification_related_entity_type_enum, p_user,
    '{}'::jsonb)
  ON CONFLICT (recipient_id, event_type, related_entity_type, related_entity_id) DO NOTHING;
  RETURN jsonb_build_object('success', true);
END $function$;

-- 0095 · Give each admin action its own notification row.
--
-- WHY
-- notifications_unique_active_event is UNIQUE on
--   (recipient_id, event_type, related_entity_type, related_entity_id).
-- Six admin RPCs write PLATFORM_ANNOUNCEMENT / user_profile notifications
-- keyed on the RECIPIENT's own id -- so every one of them produces the
-- identical tuple (creatorId, 'PLATFORM_ANNOUNCEMENT', 'user_profile',
-- creatorId). Because they use ON CONFLICT ... DO UPDATE, the SECOND admin
-- action against a creator mutates the FIRST notification's row in place, and
-- since DO UPDATE sets message/metadata but not title, the survivor is a
-- splice: old headline, new body ("You're featured!" over "Your account has
-- been suspended"). No error, no log.
--
--   rpc_admin_set_account_status, rpc_admin_set_commission,
--   rpc_admin_toggle_featured, rpc_admin_toggle_premium,
--   rpc_admin_reset_payout_methods, rpc_admin_approve_social_link
--
-- rpc_admin_review_application + rpc_admin_final_approve_partner have the same
-- problem on PARTNER_APPLICATION_STATUS_UPDATE: stage-1's "passed initial
-- review" notice is overwritten by stage-3's "you're approved".
--
-- FIX
-- The key must identify the EVENT, not the recipient. Every one of these
-- functions already writes an audit_log row (uuid PK, gen_random_uuid()
-- default). Capture that id and use it as related_entity_id, with
-- related_entity_type = 'system'. Each action is now its own row; the
-- ON CONFLICT clause is dropped as unreachable. The client is unaffected --
-- GET /notifications returns only id/event_type/title/message/is_read/
-- created_at; the entity columns are server-only, and 0084's clear-trigger
-- only touches the three VIDEO_CALL_* prompt types, none changed here.
--
-- rpc_admin_manage_kyc is left keyed as-is (KYC has one legitimate transition,
-- rejected -> verified, where "latest status wins" is correct) -- it only
-- gains `title = excluded.title` so the headline stops lagging the message.
--
-- Live state: 0 PLATFORM_ANNOUNCEMENT rows, so nothing has collided yet.

BEGIN;

-- ── rpc_admin_set_account_status ─────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.rpc_admin_set_account_status(p_admin uuid, p_user uuid, p_status user_account_status, p_reason text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE v_audit_id uuid;
BEGIN
  PERFORM public.assert_is_admin_actor(p_admin);
  UPDATE public.profiles SET account_status=p_status, status_reason=p_reason,
    status_changed_at=now(), status_changed_by=p_admin, updated_at=now() WHERE id=p_user;
  IF NOT FOUND THEN RETURN jsonb_build_object('success',false,'error','USER_NOT_FOUND'); END IF;
  INSERT INTO public.audit_log (actor_id, actor_role, action, target_type, target_id, new_value)
    VALUES (p_admin,'ADMIN','SET_ACCOUNT_STATUS','profile',p_user, jsonb_build_object('status',p_status,'reason',p_reason))
    RETURNING id INTO v_audit_id;

  INSERT INTO public.notifications (recipient_id, actor_id, event_type, title, message, related_entity_type, related_entity_id, metadata)
  VALUES (p_user, p_admin, 'PLATFORM_ANNOUNCEMENT'::public.notification_event_type_enum,
    CASE WHEN p_status = 'ACTIVE' THEN 'Account reactivated' ELSE 'Account status changed' END,
    CASE WHEN p_status = 'ACTIVE' THEN 'Your account has been reactivated.'
         ELSE 'Your account status has changed to ' || p_status::text || '.' || COALESCE(' Reason: ' || p_reason, '') END,
    'system'::public.notification_related_entity_type_enum, v_audit_id,
    jsonb_build_object('status', p_status, 'reason', p_reason));

  RETURN jsonb_build_object('success',true);
END $function$;

-- ── rpc_admin_set_commission ─────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.rpc_admin_set_commission(p_admin uuid, p_partner uuid, p_rate numeric)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE v_audit_id uuid;
BEGIN
  PERFORM public.assert_is_admin_actor(p_admin);
  PERFORM public.assert_admin_role('FINANCE','SUPER_ADMIN');
  UPDATE public.partner_profiles SET commission_rate=p_rate, updated_at=now() WHERE profile_id=p_partner;
  IF NOT FOUND THEN RETURN jsonb_build_object('success',false,'error','NOT_FOUND'); END IF;
  INSERT INTO public.audit_log (actor_id, actor_role, action, target_type, target_id, new_value)
    VALUES (p_admin,'ADMIN','SET_COMMISSION','partner_profile',p_partner, jsonb_build_object('rate',p_rate))
    RETURNING id INTO v_audit_id;

  INSERT INTO public.notifications (recipient_id, actor_id, event_type, title, message, related_entity_type, related_entity_id, metadata)
  VALUES (p_partner, p_admin, 'PLATFORM_ANNOUNCEMENT'::public.notification_event_type_enum,
    'Commission rate updated',
    'Your commission rate has been updated to ' || p_rate || '%.',
    'system'::public.notification_related_entity_type_enum, v_audit_id,
    jsonb_build_object('rate', p_rate));

  RETURN jsonb_build_object('success',true);
END $function$;

-- ── rpc_admin_toggle_featured ────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.rpc_admin_toggle_featured(p_admin uuid, p_partner uuid, p_on boolean, p_reason text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE v_audit_id uuid;
BEGIN
  PERFORM public.assert_is_admin_actor(p_admin);
  UPDATE public.partner_profiles SET is_featured=p_on,
    featured_at = CASE WHEN p_on THEN now() END, featured_by_admin_id = CASE WHEN p_on THEN p_admin END,
    featured_reason = CASE WHEN p_on THEN p_reason END, updated_at=now() WHERE profile_id=p_partner;
  IF NOT FOUND THEN RETURN jsonb_build_object('success',false,'error','NOT_FOUND'); END IF;
  INSERT INTO public.audit_log (actor_id, actor_role, action, target_type, target_id, new_value)
    VALUES (p_admin,'ADMIN','TOGGLE_FEATURED','partner_profile',p_partner, jsonb_build_object('on',p_on,'reason',p_reason))
    RETURNING id INTO v_audit_id;

  INSERT INTO public.notifications (recipient_id, actor_id, event_type, title, message, related_entity_type, related_entity_id, metadata)
  VALUES (p_partner, p_admin, 'PLATFORM_ANNOUNCEMENT'::public.notification_event_type_enum,
    CASE WHEN p_on THEN 'You''re featured!' ELSE 'Featured status removed' END,
    CASE WHEN p_on THEN 'Your profile is now featured on Discover.' ELSE 'Your profile is no longer featured.' END,
    'system'::public.notification_related_entity_type_enum, v_audit_id,
    jsonb_build_object('featured', p_on));

  RETURN jsonb_build_object('success',true);
END $function$;

-- ── rpc_admin_toggle_premium ─────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.rpc_admin_toggle_premium(p_admin uuid, p_partner uuid, p_on boolean, p_reason text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE v_audit_id uuid;
BEGIN
  PERFORM public.assert_is_admin_actor(p_admin);
  UPDATE public.partner_profiles SET is_premium=p_on,
    premium_at = CASE WHEN p_on THEN now() END, premium_by_admin_id = CASE WHEN p_on THEN p_admin END,
    premium_reason = CASE WHEN p_on THEN p_reason END, updated_at=now() WHERE profile_id=p_partner;
  IF NOT FOUND THEN RETURN jsonb_build_object('success',false,'error','NOT_FOUND'); END IF;
  INSERT INTO public.audit_log (actor_id, actor_role, action, target_type, target_id, new_value)
    VALUES (p_admin,'ADMIN','TOGGLE_PREMIUM','partner_profile',p_partner, jsonb_build_object('on',p_on,'reason',p_reason))
    RETURNING id INTO v_audit_id;

  INSERT INTO public.notifications (recipient_id, actor_id, event_type, title, message, related_entity_type, related_entity_id, metadata)
  VALUES (p_partner, p_admin, 'PLATFORM_ANNOUNCEMENT'::public.notification_event_type_enum,
    CASE WHEN p_on THEN 'Premium status granted' ELSE 'Premium status removed' END,
    CASE WHEN p_on THEN 'Your profile now has premium status.' ELSE 'Your premium status has been removed.' END,
    'system'::public.notification_related_entity_type_enum, v_audit_id,
    jsonb_build_object('premium', p_on));

  RETURN jsonb_build_object('success',true);
END $function$;

-- ── rpc_admin_reset_payout_methods ───────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.rpc_admin_reset_payout_methods(p_admin uuid, p_partner uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE v_count int; v_audit_id uuid;
BEGIN
  PERFORM public.assert_is_admin_actor(p_admin);
  UPDATE public.payout_methods
     SET is_verified = false, verified_by_admin_id = NULL, verified_at = NULL, updated_at = now()
   WHERE partner_id = p_partner AND is_verified;
  GET DIAGNOSTICS v_count = ROW_COUNT;
  INSERT INTO public.audit_log (actor_id, actor_role, action, target_type, target_id, new_value)
    VALUES (p_admin,'ADMIN','RESET_PAYOUT_METHODS','partner_profile',p_partner,
      jsonb_build_object('methods_reset', v_count))
    RETURNING id INTO v_audit_id;

  IF v_count > 0 THEN
    INSERT INTO public.notifications (recipient_id, actor_id, event_type, title, message, related_entity_type, related_entity_id, metadata)
    VALUES (p_partner, p_admin, 'PLATFORM_ANNOUNCEMENT'::public.notification_event_type_enum,
      'Payout method needs re-verification',
      v_count || ' of your payout method(s) need to be re-verified before you can withdraw.',
      'system'::public.notification_related_entity_type_enum, v_audit_id,
      jsonb_build_object('methodsReset', v_count));
  END IF;

  RETURN jsonb_build_object('success', true, 'methods_reset', v_count,
    'message', v_count || ' payout method(s) marked unverified; partner must resubmit.');
END $function$;

-- ── rpc_admin_approve_social_link ────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.rpc_admin_approve_social_link(p_admin uuid, p_link uuid, p_approved boolean)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE v_partner uuid; v_audit_id uuid;
BEGIN
  PERFORM public.assert_is_admin_actor(p_admin);
  UPDATE public.partner_social_links SET is_approved=p_approved,
    approved_by_admin_id = CASE WHEN p_approved THEN p_admin END, updated_at=now()
    WHERE id=p_link
    RETURNING partner_id INTO v_partner;
  IF NOT FOUND THEN RETURN jsonb_build_object('success',false,'error','NOT_FOUND'); END IF;
  INSERT INTO public.audit_log (actor_id, actor_role, action, target_type, target_id, new_value)
    VALUES (p_admin,'ADMIN','APPROVE_SOCIAL_LINK','partner_social_link',p_link, jsonb_build_object('approved',p_approved))
    RETURNING id INTO v_audit_id;

  INSERT INTO public.notifications (recipient_id, actor_id, event_type, title, message, related_entity_type, related_entity_id, metadata)
  VALUES (v_partner, p_admin, 'PLATFORM_ANNOUNCEMENT'::public.notification_event_type_enum,
    CASE WHEN p_approved THEN 'Social link approved' ELSE 'Social link rejected' END,
    CASE WHEN p_approved THEN 'Your social link is now visible on your profile.' ELSE 'Your social link submission was rejected.' END,
    'system'::public.notification_related_entity_type_enum, v_audit_id,
    jsonb_build_object('linkId', p_link, 'approved', p_approved));

  RETURN jsonb_build_object('success',true);
END $function$;

-- ── rpc_admin_review_application (stage 1) ───────────────────────────────────
CREATE OR REPLACE FUNCTION public.rpc_admin_review_application(p_admin uuid, p_application uuid, p_decision text, p_reason text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE a public.partner_applications; v_audit_id uuid;
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
      jsonb_build_object('decision',p_decision,'reason',p_reason))
    RETURNING id INTO v_audit_id;

  IF a.profile_id IS NOT NULL THEN
    INSERT INTO public.notifications (recipient_id, actor_id, event_type, title, message, related_entity_type, related_entity_id, metadata)
    VALUES (a.profile_id, p_admin, 'PARTNER_APPLICATION_STATUS_UPDATE'::public.notification_event_type_enum,
      CASE WHEN p_decision='APPROVE' THEN 'Application moving forward' ELSE 'Application update' END,
      CASE WHEN p_decision='APPROVE' THEN 'Your creator application passed initial review — complete your KYC and profile to continue.'
           ELSE 'Your creator application was not approved at this stage.' || COALESCE(' Reason: ' || p_reason, '') END,
      'system'::public.notification_related_entity_type_enum, v_audit_id,
      jsonb_build_object('applicationId', p_application, 'decision', p_decision, 'reason', p_reason));
  END IF;

  RETURN jsonb_build_object('success',true,'decision',p_decision);
END $function$;

-- ── rpc_admin_final_approve_partner (stage 3) ───────────────────────────────
CREATE OR REPLACE FUNCTION public.rpc_admin_final_approve_partner(p_admin uuid, p_application uuid, p_decision text, p_reason text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE a public.partner_applications; v_audit_id uuid;
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
      jsonb_build_object('decision',p_decision,'reason',p_reason))
    RETURNING id INTO v_audit_id;

  IF a.profile_id IS NOT NULL THEN
    INSERT INTO public.notifications (recipient_id, actor_id, event_type, title, message, related_entity_type, related_entity_id, metadata)
    VALUES (a.profile_id, p_admin, 'PARTNER_APPLICATION_STATUS_UPDATE'::public.notification_event_type_enum,
      CASE WHEN p_decision='APPROVE' THEN 'You''re a creator on Zudue!' ELSE 'Application update' END,
      CASE WHEN p_decision='APPROVE' THEN 'Your creator application was approved. Set up your services and availability to start earning.'
           ELSE 'Your creator application was not approved.' || COALESCE(' Reason: ' || p_reason, '') END,
      'system'::public.notification_related_entity_type_enum, v_audit_id,
      jsonb_build_object('applicationId', p_application, 'decision', p_decision, 'reason', p_reason));
  END IF;

  RETURN jsonb_build_object('success',true,'decision',p_decision);
END $function$;

-- ── rpc_admin_manage_kyc  (kept keyed; headline now tracks the message) ──────
CREATE OR REPLACE FUNCTION public.rpc_admin_manage_kyc(p_admin uuid, p_user uuid, p_verified boolean, p_reason text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
  DO UPDATE SET is_read=false, created_at=now(), title=excluded.title, message=excluded.message, metadata=excluded.metadata;

  RETURN jsonb_build_object('success',true);
END $function$;

INSERT INTO _migrations (name) VALUES ('0095_notification_admin_event_keying.sql') ON CONFLICT (name) DO NOTHING;

COMMIT;

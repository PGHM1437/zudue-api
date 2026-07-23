-- 0053 · Admin promotes a fan to creator (and back), replacing self-signup.
--
-- The public "Become a creator" page duplicated the whole signup form — name,
-- email, mobile AND a password — to create a second account, then filed an
-- application. It was broken (the password grant 400'd), it let anyone spam
-- applications, and it made role a thing users assert about themselves.
--
-- Roles are an operator decision, so an operator sets them. A creator now
-- signs up as a normal fan, and an admin promotes them. Applications are no
-- longer a public write path, which is the spam control.
--
-- Promotion sets partner_profiles.status = ACTIVE directly rather than
-- PENDING_APPROVAL: the admin performing this action IS the approval. Leaving
-- it pending would strand the user on the "awaiting approval" screen with
-- nothing to wait for, since the two-stage application flow is no longer how
-- anyone becomes a creator.
--
-- Demotion keeps the partner_profiles row (status INACTIVE, is_active false)
-- instead of deleting it: partner_earnings, payouts and bookings reference the
-- creator, and deleting the row would either cascade real financial history
-- away or fail on a foreign key.

BEGIN;

CREATE OR REPLACE FUNCTION rpc_admin_set_user_role(
  p_admin  uuid,
  p_target uuid,
  p_role   user_role,
  p_reason text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_old public.user_role; v_name text;
BEGIN
  PERFORM public.assert_is_admin_actor(p_admin);
  -- SUPPORT deliberately excluded: creating creators is a commercial decision,
  -- not a support action.
  PERFORM public.assert_admin_role('SUPER_ADMIN');

  IF p_role NOT IN ('FAN','PARTNER') THEN
    RETURN jsonb_build_object('success',false,'error','ROLE_NOT_ASSIGNABLE'); END IF;

  SELECT role, full_name INTO v_old, v_name FROM public.profiles WHERE id = p_target;
  IF v_old IS NULL THEN RETURN jsonb_build_object('success',false,'error','NOT_FOUND'); END IF;

  -- Never let this path touch an admin account: admin membership is managed by
  -- rpc_admin_create_admin / _revoke_admin, and silently demoting an admin here
  -- would strip their access with no audit of the privilege change itself.
  IF v_old = 'ADMIN' THEN
    RETURN jsonb_build_object('success',false,'error','CANNOT_CHANGE_ADMIN_ROLE'); END IF;

  IF v_old = p_role THEN
    RETURN jsonb_build_object('success',true,'unchanged',true,'role',p_role); END IF;

  UPDATE public.profiles SET role = p_role, updated_at = now() WHERE id = p_target;

  IF p_role = 'PARTNER' THEN
    INSERT INTO public.partner_profiles (profile_id, display_name, status, is_active, approved_at, approved_by_admin_id)
      VALUES (p_target, COALESCE(NULLIF(btrim(v_name),''), 'Creator'), 'ACTIVE', true, now(), p_admin)
    ON CONFLICT (profile_id) DO UPDATE
      SET status = 'ACTIVE', is_active = true, approved_at = now(),
          approved_by_admin_id = p_admin, updated_at = now();

    INSERT INTO public.notifications (recipient_id, event_type, title, message)
      VALUES (p_target,'PARTNER_APPLICATION_STATUS_UPDATE','You are now a creator',
              'Your account can now offer video calls, questions and shout-outs. Set your services to start earning.');
  ELSE
    -- Demotion: retain the row, remove them from discovery.
    UPDATE public.partner_profiles
       SET status = 'INACTIVE', is_active = false,
           deactivation_reason = COALESCE(p_reason,'Role changed to fan by admin'), updated_at = now()
     WHERE profile_id = p_target;

    INSERT INTO public.notifications (recipient_id, event_type, title, message)
      VALUES (p_target,'PARTNER_APPLICATION_STATUS_UPDATE','Creator access removed',
              COALESCE(p_reason,'Your account no longer has creator access.'));
  END IF;

  INSERT INTO public.audit_log (actor_id, actor_role, action, target_type, target_id, old_value, new_value)
    VALUES (p_admin,'ADMIN','SET_USER_ROLE','profile',p_target,
            jsonb_build_object('role',v_old),
            jsonb_build_object('role',p_role,'reason',p_reason));

  RETURN jsonb_build_object('success',true,'role',p_role,'previous_role',v_old);
END $$;

REVOKE ALL ON FUNCTION rpc_admin_set_user_role(uuid,uuid,user_role,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION rpc_admin_set_user_role(uuid,uuid,user_role,text) TO zudue_app;

INSERT INTO _migrations (name) VALUES ('0053_admin_set_user_role.sql')
  ON CONFLICT (name) DO NOTHING;

COMMIT;

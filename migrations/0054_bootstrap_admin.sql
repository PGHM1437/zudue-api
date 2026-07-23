-- 0054 · Owner-only escape hatch for granting admin access.
--
-- THE DEADLOCK
-- profiles.role is protected by the guard_protected_columns trigger, which
-- allows a change only when one of three things is true:
--    1. is_admin()                              — no admin exists yet
--    2. inside a SECURITY DEFINER function      — nothing offered one
--    3. session_user is a superuser             — Supabase's `postgres` is NOT
-- On a fresh Supabase project all three are false, so `UPDATE profiles SET
-- role='ADMIN'` fails even for the database owner:
--    FORBIDDEN: column role is admin-only and cannot be changed by the row owner
-- and rpc_admin_create_admin needs an existing SUPER_ADMIN, so the app cannot
-- mint the first one either. Admin access was unreachable by any route.
--
-- THE FIX
-- A SECURITY DEFINER function satisfies hatch #2. Access is restricted to the
-- database OWNER: EXECUTE is revoked from PUBLIC and never granted to
-- zudue_app, so the API — and therefore any user, request or token — can never
-- reach it. The only caller is someone already holding the migration
-- credential, who by definition can do anything anyway. This widens no
-- meaningful attack surface; it just makes an impossible task possible.
--
-- Grants BOTH halves of admin, because they are separate and both required:
--   profiles.role='ADMIN'        -> what is_admin() reads (RLS, view gating)
--   admin_profiles.admin_role    -> the tier assert_admin_role() reads
-- Setting one without the other yields a half-admin that passes RLS but fails
-- every tiered RPC, which is a genuinely confusing state to debug.

BEGIN;

CREATE OR REPLACE FUNCTION bootstrap_admin(
  p_email  text,
  p_tier   admin_role DEFAULT 'SUPER_ADMIN',
  p_revoke boolean     DEFAULT false)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_id uuid; v_old public.user_role; v_name text;
BEGIN
  SELECT id, role, full_name INTO v_id, v_old, v_name
    FROM public.profiles WHERE lower(email) = lower(btrim(p_email)) LIMIT 1;

  IF v_id IS NULL THEN
    RETURN jsonb_build_object('success',false,'error','NO_SUCH_PROFILE','email',p_email);
  END IF;

  IF p_revoke THEN
    DELETE FROM public.admin_profiles WHERE profile_id = v_id;
    UPDATE public.profiles SET role = 'FAN', updated_at = now() WHERE id = v_id;
    INSERT INTO public.audit_log (actor_id, actor_role, action, target_type, target_id, old_value, new_value)
      VALUES (v_id,'ADMIN','REVOKE_ADMIN_BOOTSTRAP','profile',v_id,
              jsonb_build_object('role',v_old),
              jsonb_build_object('role','FAN','via','bootstrap_admin'));
    RETURN jsonb_build_object('success',true,'email',p_email,'role','FAN');
  END IF;

  UPDATE public.profiles SET role = 'ADMIN', updated_at = now() WHERE id = v_id;

  INSERT INTO public.admin_profiles (profile_id, admin_role)
    VALUES (v_id, p_tier)
  ON CONFLICT (profile_id) DO UPDATE SET admin_role = excluded.admin_role, updated_at = now();

  -- Self-attributed: during a bootstrap there is no other admin to attribute
  -- it to, but the privilege change must still leave a trace.
  INSERT INTO public.audit_log (actor_id, actor_role, action, target_type, target_id, old_value, new_value)
    VALUES (v_id,'ADMIN','GRANT_ADMIN_BOOTSTRAP','profile',v_id,
            jsonb_build_object('role',v_old),
            jsonb_build_object('role','ADMIN','tier',p_tier,'via','bootstrap_admin'));

  RETURN jsonb_build_object('success',true,'email',p_email,'name',v_name,
                            'role','ADMIN','tier',p_tier,'previous_role',v_old);
END $$;

-- Owner-only. The API must never be able to escalate anyone, so this stays
-- unreachable from every request path.
--
-- Revoking from PUBLIC alone is NOT sufficient here: this schema carries a
-- DEFAULT ACL that grants the app role on newly-created objects, so zudue_app
-- came out of CREATE FUNCTION already holding EXECUTE. Verified with
-- has_function_privilege() — it returned true until the explicit revoke below.
-- A privilege this sharp has to be asserted, not assumed.
REVOKE ALL ON FUNCTION bootstrap_admin(text, admin_role, boolean) FROM PUBLIC;
REVOKE ALL ON FUNCTION bootstrap_admin(text, admin_role, boolean) FROM zudue_app;

INSERT INTO _migrations (name) VALUES ('0054_bootstrap_admin.sql')
  ON CONFLICT (name) DO NOTHING;

COMMIT;

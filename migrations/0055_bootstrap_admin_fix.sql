-- 0055 · Make bootstrap_admin actually work.
--
-- 0054 assumed SECURITY DEFINER would satisfy guard_protected_columns' second
-- escape hatch:
--     IF public.is_admin() OR current_user IS DISTINCT FROM session_user
-- It does not. bootstrap_admin is owned by `postgres` and the bootstrap runs
-- AS `postgres`, so current_user and session_user are the same role and the
-- condition is false. The grant still failed with:
--     FORBIDDEN: column role is admin-only and cannot be changed by the row owner
-- That hatch only opens when the function owner differs from the caller.
--
-- All three hatches are therefore shut on a fresh Supabase project:
--   is_admin()      false — no admin exists yet (the very deadlock)
--   definer context false — same owner as caller
--   rolsuper        false — Supabase's `postgres` is not a superuser
--
-- Fix: suppress the trigger for the single UPDATE using
-- session_replication_role='replica', which is how Postgres itself disables
-- user triggers. Chosen over ALTER TABLE ... DISABLE TRIGGER because that takes
-- an ACCESS EXCLUSIVE lock on `profiles` and is visible to every other session;
-- this is scoped to the current TRANSACTION (set_config with is_local=true), so
-- concurrent connections are unaffected and it reverts automatically even if
-- the function raises.
--
-- It is switched back to 'origin' immediately after the one statement that
-- needs it, so the admin_profiles upsert and the audit_log insert still fire
-- their normal triggers. Verified: profiles.updated_at is set explicitly here,
-- and the wallet-provisioning triggers are irrelevant to a role change on an
-- account that already has a wallet.

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

    PERFORM set_config('session_replication_role','replica',true);
    UPDATE public.profiles SET role = 'FAN', updated_at = now() WHERE id = v_id;
    PERFORM set_config('session_replication_role','origin',true);

    INSERT INTO public.audit_log (actor_id, actor_role, action, target_type, target_id, old_value, new_value)
      VALUES (v_id,'ADMIN','REVOKE_ADMIN_BOOTSTRAP','profile',v_id,
              jsonb_build_object('role',v_old),
              jsonb_build_object('role','FAN','via','bootstrap_admin'));
    RETURN jsonb_build_object('success',true,'email',p_email,'role','FAN');
  END IF;

  -- Transaction-scoped trigger suppression, re-enabled on the very next line.
  PERFORM set_config('session_replication_role','replica',true);
  UPDATE public.profiles SET role = 'ADMIN', updated_at = now() WHERE id = v_id;
  PERFORM set_config('session_replication_role','origin',true);

  INSERT INTO public.admin_profiles (profile_id, admin_role)
    VALUES (v_id, p_tier)
  ON CONFLICT (profile_id) DO UPDATE SET admin_role = excluded.admin_role, updated_at = now();

  -- Self-attributed: during a bootstrap there is no other admin to attribute it
  -- to, but the privilege change must still leave a trace.
  INSERT INTO public.audit_log (actor_id, actor_role, action, target_type, target_id, old_value, new_value)
    VALUES (v_id,'ADMIN','GRANT_ADMIN_BOOTSTRAP','profile',v_id,
            jsonb_build_object('role',v_old),
            jsonb_build_object('role','ADMIN','tier',p_tier,'via','bootstrap_admin'));

  RETURN jsonb_build_object('success',true,'email',p_email,'name',v_name,
                            'role','ADMIN','tier',p_tier,'previous_role',v_old);
END $$;

-- Re-assert after CREATE OR REPLACE: the schema's default ACL grants the app
-- role EXECUTE on newly-created functions, so this must be revoked explicitly
-- every time the function is (re)defined, not just once.
REVOKE ALL ON FUNCTION bootstrap_admin(text, admin_role, boolean) FROM PUBLIC;
REVOKE ALL ON FUNCTION bootstrap_admin(text, admin_role, boolean) FROM zudue_app;

INSERT INTO _migrations (name) VALUES ('0055_bootstrap_admin_fix.sql')
  ON CONFLICT (name) DO NOTHING;

COMMIT;

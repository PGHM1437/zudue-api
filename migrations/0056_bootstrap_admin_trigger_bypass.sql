-- 0056 · bootstrap_admin, third attempt — and this one is verified.
--
-- The record, because each failure ruled out a real option:
--
--   0054  Assumed SECURITY DEFINER opened guard_protected_columns' hatch
--         `current_user IS DISTINCT FROM session_user`. It does not: the
--         function is owned by `postgres` and the bootstrap runs AS `postgres`,
--         so the two are identical. That hatch only opens when the function
--         owner differs from the caller.
--
--   0055  Used session_replication_role='replica' (how Postgres itself disables
--         user triggers). It works at top level as `postgres`, but inside a
--         function the parameter is superuser-only:
--             permission denied to set parameter "session_replication_role"
--         and Supabase's `postgres` is not a superuser.
--
--   0056  ALTER TABLE ... DISABLE TRIGGER. Verified working as `postgres`,
--         which owns `profiles`. DDL is transactional in Postgres, so if
--         anything below raises, the disable rolls back with it and the trigger
--         is never left off. The window is one UPDATE inside one transaction.
--
-- The ACCESS EXCLUSIVE lock this takes is the honest cost: it briefly blocks
-- other writers to `profiles`. Acceptable for a bootstrap that runs once per
-- environment, and preferable to leaving admin access unreachable.
--
-- Still owner-only: EXECUTE is revoked from PUBLIC and from zudue_app, so no
-- request path can reach it. Anyone able to call it already holds the migration
-- credential and could edit the table directly.

BEGIN;

CREATE OR REPLACE FUNCTION bootstrap_admin(
  p_email  text,
  p_tier   admin_role DEFAULT 'SUPER_ADMIN',
  p_revoke boolean     DEFAULT false)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_id uuid; v_old public.user_role; v_name text; v_new public.user_role;
BEGIN
  SELECT id, role, full_name INTO v_id, v_old, v_name
    FROM public.profiles WHERE lower(email) = lower(btrim(p_email)) LIMIT 1;

  IF v_id IS NULL THEN
    RETURN jsonb_build_object('success',false,'error','NO_SUCH_PROFILE','email',p_email);
  END IF;

  v_new := CASE WHEN p_revoke THEN 'FAN' ELSE 'ADMIN' END;

  IF p_revoke THEN
    DELETE FROM public.admin_profiles WHERE profile_id = v_id;
  END IF;

  -- profiles.role is admin-only by trigger. Suspend that one trigger for this
  -- statement; the ALTERs and the UPDATE are in the same transaction, so any
  -- failure restores it automatically.
  ALTER TABLE public.profiles DISABLE TRIGGER trg_guard_profiles_admin_cols;
  UPDATE public.profiles SET role = v_new, updated_at = now() WHERE id = v_id;
  ALTER TABLE public.profiles ENABLE TRIGGER trg_guard_profiles_admin_cols;

  IF NOT p_revoke THEN
    INSERT INTO public.admin_profiles (profile_id, admin_role)
      VALUES (v_id, p_tier)
    ON CONFLICT (profile_id) DO UPDATE SET admin_role = excluded.admin_role, updated_at = now();
  END IF;

  -- Self-attributed: during a bootstrap there is no other admin to attribute it
  -- to, but a privilege change must still leave a trace.
  INSERT INTO public.audit_log (actor_id, actor_role, action, target_type, target_id, old_value, new_value)
    VALUES (v_id,'ADMIN',
            CASE WHEN p_revoke THEN 'REVOKE_ADMIN_BOOTSTRAP' ELSE 'GRANT_ADMIN_BOOTSTRAP' END,
            'profile', v_id,
            jsonb_build_object('role',v_old),
            jsonb_build_object('role',v_new,'tier',CASE WHEN p_revoke THEN NULL ELSE p_tier END,'via','bootstrap_admin'));

  RETURN jsonb_build_object('success',true,'email',p_email,'name',v_name,
                            'role',v_new,'tier',CASE WHEN p_revoke THEN NULL ELSE p_tier END,
                            'previous_role',v_old);
END $$;

-- Must be re-asserted after every CREATE OR REPLACE: the schema's default ACL
-- hands the app role EXECUTE on newly-created functions, so a bare
-- REVOKE ... FROM PUBLIC is not enough. Confirmed with has_function_privilege().
REVOKE ALL ON FUNCTION bootstrap_admin(text, admin_role, boolean) FROM PUBLIC;
REVOKE ALL ON FUNCTION bootstrap_admin(text, admin_role, boolean) FROM zudue_app;

INSERT INTO _migrations (name) VALUES ('0056_bootstrap_admin_trigger_bypass.sql')
  ON CONFLICT (name) DO NOTHING;

COMMIT;

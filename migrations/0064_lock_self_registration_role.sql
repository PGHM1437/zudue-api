-- ═══════════════════════════════════════════════════════════════════════════
-- Migration 0064: Lock self-registration to role=FAN
-- ═══════════════════════════════════════════════════════════════════════════
-- Closes a privilege-escalation hole: profiles_self_insert (0028) only checks
-- id = current_user_id() — it has no opinion on `role`. The one and only INSERT
-- path (POST /me, now fixed in application code to always send 'FAN') used to
-- insert whatever role string the client sent, unvalidated, and 'ADMIN' is a
-- valid user_role value. trg_guard_profiles_admin_cols already protects `role`
-- from being changed via UPDATE (0024) — this migration adds the missing
-- INSERT-side guard, so the protection does not depend solely on the API layer
-- remembering to enforce it.
--
-- Same bypass shape as guard_protected_columns: admins, and anything running
-- inside a SECURITY DEFINER RPC (current_user <> session_user — e.g. a future
-- admin-provisioning RPC), pass through untouched. Every other caller is
-- forced to role='FAN' on insert; becoming PARTNER or ADMIN stays exclusively
-- an admin action (rpc_admin_set_user_role, the application-review RPCs, or
-- rpc_admin_create_admin).
-- ═══════════════════════════════════════════════════════════════════════════

BEGIN;

CREATE OR REPLACE FUNCTION public.guard_profile_role_on_insert()
RETURNS trigger LANGUAGE plpgsql SET search_path = '' AS $$
BEGIN
  IF public.is_admin() OR current_user IS DISTINCT FROM session_user THEN
    RETURN NEW;                       -- admin, or inside a SECURITY DEFINER RPC
  END IF;
  IF (SELECT rolsuper FROM pg_roles WHERE rolname = session_user) THEN
    RETURN NEW;                       -- superuser session (migrations, ops)
  END IF;
  IF NEW.role <> 'FAN' THEN
    RAISE EXCEPTION 'FORBIDDEN: self-registration must be role=FAN; PARTNER/ADMIN require an admin action'
      USING ERRCODE = '42501';
  END IF;
  RETURN NEW;
END $$;

CREATE TRIGGER trg_guard_profile_role_insert BEFORE INSERT ON public.profiles
  FOR EACH ROW EXECUTE FUNCTION public.guard_profile_role_on_insert();

COMMIT;

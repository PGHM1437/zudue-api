-- 0051 · CRITICAL: account deletion was broken on production only.
--
-- Found by fingerprinting the whole schema on both databases and diffing.
-- The ONLY structural difference between local and prod was where pgcrypto
-- lives:
--     local  →  pgcrypto in schema `public`   (plain Postgres, CREATE EXTENSION default)
--     prod   →  pgcrypto in schema `extensions` (Supabase's convention)
--
-- rpc_request_account_deletion built its confirm token with
--     encode(public.gen_random_bytes(16),'hex')
-- and the function runs with SET search_path = '', so the hard-coded `public.`
-- qualifier is the only resolution path. On production that function does not
-- exist in `public`, so every call failed outright:
--
--     ERROR: function public.gen_random_bytes(integer) does not exist
--
-- Verified live on both: the identical call SUCCEEDS on local and ERRORS on
-- prod. This is the textbook works-on-my-machine failure — no amount of local
-- testing would ever have surfaced it, because local is the environment where
-- it works.
--
-- Impact: account deletion was 100% non-functional in production. That is also
-- a compliance exposure, not just a bug — Google Play and India's DPDP Act both
-- require a working account-deletion path, and the app's own UI promises one.
--
-- Fix: stop depending on pgcrypto for this at all. gen_random_uuid() has been
-- a pg_catalog BUILT-IN since PostgreSQL 13, so it resolves identically on
-- both databases regardless of search_path or which schema holds the
-- extensions. Explicitly pg_catalog-qualified because prod has two candidates
-- (pg_catalog and extensions) and ambiguity here is what caused the outage.
--
-- Token shape is preserved: 32 lowercase hex characters, as encode(16 bytes)
-- produced. Entropy is 122 bits vs 128 — immaterial for a single-use,
-- 30-day-lifetime confirmation token.
--
-- rpc_request_account_deletion is the ONLY function in the schema that touches
-- pgcrypto; verified by scanning every function body on prod for
-- gen_random_bytes/digest/crypt/hmac/pgp_sym_*/armor.

BEGIN;

CREATE OR REPLACE FUNCTION public.rpc_request_account_deletion(p_reason text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE v_me uuid := public.current_user_id(); v_id uuid; v_role public.user_role;
BEGIN
  IF v_me IS NULL THEN RETURN jsonb_build_object('success',false,'error','NO_IDENTITY'); END IF;
  IF EXISTS (SELECT 1 FROM public.deletion_requests WHERE profile_id=v_me AND status IN ('REQUESTED','CONFIRMED')) THEN
    RETURN jsonb_build_object('success',false,'error','ALREADY_REQUESTED'); END IF;

  INSERT INTO public.deletion_requests (profile_id, reason, status, confirm_token, scheduled_purge_at)
    VALUES (v_me, p_reason, 'REQUESTED',
            -- pg_catalog built-in: resolves on any Postgres, any search_path,
            -- irrespective of which schema holds pgcrypto. See header.
            replace(pg_catalog.gen_random_uuid()::text, '-', ''),
            now() + interval '30 days')
    RETURNING id INTO v_id;

  -- During the grace period a partner is pulled from discovery (owner-settable col).
  SELECT role INTO v_role FROM public.profiles WHERE id=v_me;
  IF v_role = 'PARTNER' THEN
    UPDATE public.partner_profiles SET is_active=false,
      deactivation_reason=COALESCE(deactivation_reason,'Pending account deletion'), updated_at=now()
      WHERE profile_id=v_me;
  END IF;
  RETURN jsonb_build_object('success',true,'deletion_request_id',v_id,'purge_after', (now()+interval '30 days'));
END $function$;

INSERT INTO _migrations (name) VALUES ('0051_fix_pgcrypto_schema_dependency.sql')
  ON CONFLICT (name) DO NOTHING;

COMMIT;

-- 0033 · rpc_admin_reset_payout_methods — the one confirmed admin gap from the
-- screen validation. Legacy dialogue (Partners.tsx): "mark all of {partner}'s
-- payout methods as unverified, allowing them to resubmit their details."
-- Used when a partner's bank/UPI details are wrong or suspicious and the admin
-- wants a clean re-submission. Governed + audited, same shape as
-- rpc_admin_verify_payout_method.

BEGIN;

CREATE OR REPLACE FUNCTION rpc_admin_reset_payout_methods(p_admin uuid, p_partner uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
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
  RETURN jsonb_build_object('success', true, 'methods_reset', v_count,
    'message', v_count || ' payout method(s) marked unverified; partner must resubmit.');
END $$;

REVOKE ALL ON FUNCTION rpc_admin_reset_payout_methods(uuid,uuid) FROM PUBLIC;

DO $$
DECLARE v_dupes text;
BEGIN
  SELECT string_agg(DISTINCT p.proname, ', ') INTO v_dupes
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname LIKE 'rpc_%'
  GROUP BY p.proname HAVING count(*) > 1;
  IF v_dupes IS NOT NULL THEN
    RAISE EXCEPTION 'Duplicate RPC overloads detected: %', v_dupes;
  END IF;
END $$;

COMMIT;

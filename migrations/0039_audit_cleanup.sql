-- 0039 · Audit cleanup: three verified defects from the full-schema audit.
--
-- Scope note: this migration ONLY fixes defects that are unambiguous and
-- behaviour-preserving. The audit also surfaced four judgment calls (dead
-- config knobs, the dead partner_tags table, the unused PROMO_DISCOUNT
-- txn_type + who funds promo discounts, and three fully-built-but-unwired
-- RPCs). Those are product decisions, not defects, and are deliberately
-- left alone here rather than resolved unilaterally.

BEGIN;

-- ── Finding 1 · Duplicate indexes ────────────────────────────────────────
-- Both pairs are byte-for-byte identical column sets where a UNIQUE index
-- already exists; the plain duplicate can serve no query the unique one
-- can't, so it is pure write-amplification and storage cost.
--   availability_unique       UNIQUE (partner_id, date)   <- keep
--   availability_partner_date_idx    (partner_id, date)   <- drop
--   profiles_referral_code_key UNIQUE (referral_code)     <- keep
--   profiles_referral_idx            (referral_code)      <- drop
DROP INDEX IF EXISTS public.availability_partner_date_idx;
DROP INDEX IF EXISTS public.profiles_referral_idx;

-- ── Finding 2 · Superseded partner-approval RPCs ─────────────────────────
-- 0034 replaced single-stage approval with the two-stage application flow
-- (rpc_admin_review_application -> rpc_partner_submit_for_review ->
-- rpc_admin_final_approve_partner). These two are the pre-0034 single-stage
-- versions. Verified unreferenced: no API call site, and no other function
-- body in the database mentions them.
--
-- They are not merely redundant but actively unsafe to leave callable:
-- rpc_admin_approve_partner flips partner_profiles.status to ACTIVE while
-- leaving partner_applications.status untouched, which would desync the
-- application state machine that the /me partner_lifecycle derivation and
-- the onboarding gate both read.
DROP FUNCTION IF EXISTS public.rpc_admin_approve_partner(uuid, uuid);
DROP FUNCTION IF EXISTS public.rpc_admin_reject_partner(uuid, uuid, text);

-- ── Finding 3 · Promo preview promised a discount checkout won't honour ──
-- rpc_preview_price delegates to resolve_price for ANY service type, so a
-- promo scoped to QUICK_QUESTION or SHOUT_OUT previews a discounted price.
-- But rpc_ask_question and rpc_request_shoutout never call resolve_price —
-- they read partner_services.price_paise directly and charge full price.
-- A fan would be quoted one price and debited another.
--
-- Currently unreachable (neither the API nor the mobile client passes a
-- promo code for those two flows), so this is a latent bug, not a live
-- incident. Fixing it in preview rather than in the two checkout RPCs is
-- deliberate: making those honour promos would need discount/original-price
-- columns on conversation_windows and shout_out_requests plus matching
-- promo_code_usages accounting — a feature, not a fix. Failing loudly here
-- keeps the quote honest and surfaces the gap instead of hiding it.
CREATE OR REPLACE FUNCTION rpc_preview_price(
  p_partner uuid, p_type service_type_enum,
  p_duration call_duration_options_enum DEFAULT NULL, p_promo_code text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  -- Only VIDEO_CALL checkout applies promos; never quote a discount that
  -- rpc_ask_question / rpc_request_shoutout will not actually honour.
  IF p_promo_code IS NOT NULL AND p_type <> 'VIDEO_CALL' THEN
    RETURN jsonb_build_object('error','PROMO_NOT_SUPPORTED_FOR_SERVICE');
  END IF;
  RETURN public.resolve_price(p_partner, p_type, p_duration, p_promo_code, public.current_user_id());
END $$;

REVOKE ALL ON FUNCTION rpc_preview_price(uuid,service_type_enum,call_duration_options_enum,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION rpc_preview_price(uuid,service_type_enum,call_duration_options_enum,text) TO zudue_app;

-- Re-assert the no-overload guard (same invariant 0021/0023 enforce): a
-- CREATE OR REPLACE with a drifted signature would silently add an overload
-- rather than replace, and ambiguous money RPCs are exactly what that guard
-- exists to prevent.
DO $$
DECLARE v_dupes text;
BEGIN
  SELECT string_agg(DISTINCT p.proname, ', ') INTO v_dupes
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname LIKE 'rpc_%'
  GROUP BY p.proname HAVING count(*) > 1;
  IF v_dupes IS NOT NULL THEN
    RAISE EXCEPTION 'Duplicate RPC overloads detected (fix before deploy): %', v_dupes;
  END IF;
END $$;

COMMIT;

-- 0048 · Platform settings editor, plus two dead knobs made real.
--
-- SETTINGS EDITOR — 23 tunables existed with no way to change them except raw
-- SQL against production. This adds a validated, role-gated RPC rather than
-- letting the admin app UPDATE the row directly, because these values move
-- money: gst_rate prices every top-up, referral rewards spend the incentive
-- budget, min_service_prices floors what every creator may charge. Range
-- checks belong next to the data, not in a React form.
--
-- PRIVILEGE FIX — the settings_admin RLS policy allowed WRITE to is_admin(),
-- i.e. ANY admin tier. A MODERATOR (whose job is reviewing reports) could
-- change gst_rate or drain the referral budget. Both the policy and the RPC
-- now require SUPER_ADMIN/FINANCE, matching how every other money control in
-- 0023/0024 is gated.
--
-- TWO DEAD KNOBS WIRED — the audit found 14 settings that nothing reads. Most
-- are genuinely decorative, but two encode real controls and are cheap to
-- honour:
--
--   min_withdrawal_paise  — rpc_create_payout_batch only rejected a ZERO
--     balance, so a creator could request a ₹3 payout that costs more in bank
--     charges than it transfers, and still needs a human to send it and record
--     a UTR.
--   max_wallet_balance_paise — a prepaid balance cap. India's PPI rules cap
--     wallet balances, and there was no ceiling at all. Enforced at top-up
--     ORDER creation (in the API, before the fan pays) rather than at capture,
--     because rejecting after money is captured means an immediate refund.
--
-- The remaining dead knobs are deliberately NOT surfaced in the editor. A
-- control panel whose switches do nothing is worse than no panel — that was
-- the original finding, and exposing them would recreate it.

BEGIN;

-- ── Privilege fix ───────────────────────────────────────────────────────
DROP POLICY IF EXISTS settings_admin ON platform_settings;
CREATE POLICY settings_admin ON platform_settings FOR UPDATE
  USING (is_admin_role('SUPER_ADMIN','FINANCE'))
  WITH CHECK (is_admin_role('SUPER_ADMIN','FINANCE'));

-- ── Validated settings update ───────────────────────────────────────────
-- Takes a partial patch; only whitelisted keys are applied, so a stray field
-- in the request body can never reach a column. The
-- audit_platform_settings_change trigger records old/new automatically.
CREATE OR REPLACE FUNCTION rpc_admin_update_settings(p_patch jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_num numeric;
BEGIN
  PERFORM public.assert_admin_role('SUPER_ADMIN','FINANCE');
  IF p_patch IS NULL OR jsonb_typeof(p_patch) <> 'object' THEN
    RETURN jsonb_build_object('success',false,'error','INVALID_PATCH'); END IF;

  -- Validate anything present. Absent keys are left untouched.
  IF p_patch ? 'gst_rate' THEN
    v_num := (p_patch->>'gst_rate')::numeric;
    IF v_num < 0 OR v_num > 1 THEN RETURN jsonb_build_object('success',false,'error','GST_RATE_OUT_OF_RANGE'); END IF;
  END IF;
  IF p_patch ? 'default_commission_rate' THEN
    v_num := (p_patch->>'default_commission_rate')::numeric;
    IF v_num < 0 OR v_num > 1 THEN RETURN jsonb_build_object('success',false,'error','COMMISSION_OUT_OF_RANGE'); END IF;
  END IF;
  IF p_patch ? 'settlement_window_days' THEN
    v_num := (p_patch->>'settlement_window_days')::numeric;
    IF v_num < 1 OR v_num > 90 THEN RETURN jsonb_build_object('success',false,'error','SETTLEMENT_WINDOW_OUT_OF_RANGE'); END IF;
  END IF;
  IF p_patch ? 'question_sla_hours' THEN
    v_num := (p_patch->>'question_sla_hours')::numeric;
    IF v_num < 1 OR v_num > 720 THEN RETURN jsonb_build_object('success',false,'error','SLA_OUT_OF_RANGE'); END IF;
  END IF;
  IF p_patch ? 'payout_day_of_month' THEN
    v_num := (p_patch->>'payout_day_of_month')::numeric;
    -- 28 is the highest day every month actually has.
    IF v_num < 1 OR v_num > 28 THEN RETURN jsonb_build_object('success',false,'error','PAYOUT_DAY_OUT_OF_RANGE'); END IF;
  END IF;

  UPDATE public.platform_settings SET
    gst_rate                        = COALESCE((p_patch->>'gst_rate')::numeric, gst_rate),
    default_commission_rate         = COALESCE((p_patch->>'default_commission_rate')::numeric, default_commission_rate),
    min_wallet_topup_paise          = COALESCE((p_patch->>'min_wallet_topup_paise')::bigint, min_wallet_topup_paise),
    max_wallet_topup_paise          = COALESCE((p_patch->>'max_wallet_topup_paise')::bigint, max_wallet_topup_paise),
    max_wallet_balance_paise        = COALESCE((p_patch->>'max_wallet_balance_paise')::bigint, max_wallet_balance_paise),
    min_withdrawal_paise            = COALESCE((p_patch->>'min_withdrawal_paise')::bigint, min_withdrawal_paise),
    settlement_window_days          = COALESCE((p_patch->>'settlement_window_days')::int, settlement_window_days),
    question_sla_hours              = COALESCE((p_patch->>'question_sla_hours')::int, question_sla_hours),
    payout_day_of_month             = COALESCE((p_patch->>'payout_day_of_month')::int, payout_day_of_month),
    referral_referrer_reward_paise  = COALESCE((p_patch->>'referral_referrer_reward_paise')::bigint, referral_referrer_reward_paise),
    referral_referee_reward_paise   = COALESCE((p_patch->>'referral_referee_reward_paise')::bigint, referral_referee_reward_paise),
    referral_budget_remaining_paise = COALESCE((p_patch->>'referral_budget_remaining_paise')::bigint, referral_budget_remaining_paise),
    is_referral_program_active      = COALESCE((p_patch->>'is_referral_program_active')::boolean, is_referral_program_active),
    min_service_prices              = COALESCE(p_patch->'min_service_prices', min_service_prices),
    updated_at = now()
  WHERE id = 1;

  -- Cross-field checks after the write, inside the same transaction, so an
  -- inconsistent pair (min above max) aborts rather than persisting.
  IF EXISTS (SELECT 1 FROM public.platform_settings
              WHERE id=1 AND min_wallet_topup_paise > max_wallet_topup_paise) THEN
    RAISE EXCEPTION 'MIN_TOPUP_ABOVE_MAX';
  END IF;
  IF EXISTS (SELECT 1 FROM public.platform_settings
              WHERE id=1 AND max_wallet_balance_paise IS NOT NULL
                AND max_wallet_balance_paise < max_wallet_topup_paise) THEN
    RAISE EXCEPTION 'BALANCE_CAP_BELOW_MAX_TOPUP';
  END IF;

  RETURN jsonb_build_object('success',true);
END $$;

REVOKE ALL ON FUNCTION rpc_admin_update_settings(jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION rpc_admin_update_settings(jsonb) TO zudue_app;

-- ── min_withdrawal_paise made real ──────────────────────────────────────
CREATE OR REPLACE FUNCTION rpc_create_payout_batch(p_partner uuid, p_method uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_sum bigint; v_payout uuid; v_min bigint;
BEGIN
  PERFORM public.assert_caller(p_partner);
  IF NOT EXISTS (SELECT 1 FROM public.payout_methods WHERE id=p_method AND partner_id=p_partner AND is_verified) THEN
    RETURN jsonb_build_object('success',false,'error','UNVERIFIED_METHOD'); END IF;
  SELECT COALESCE(sum(amount_paise),0) INTO v_sum FROM public.partner_earnings
    WHERE partner_id=p_partner AND status='PENDING_PAYOUT';
  IF v_sum = 0 THEN RETURN jsonb_build_object('success',false,'error','NOTHING_TO_PAY'); END IF;

  -- Payouts are sent by hand and each needs a UTR recorded, so a trivial
  -- withdrawal costs more in operator time and bank charges than it moves.
  SELECT min_withdrawal_paise INTO v_min FROM public.platform_settings WHERE id=1;
  IF v_min IS NOT NULL AND v_sum < v_min THEN
    RETURN jsonb_build_object('success',false,'error','BELOW_MIN_WITHDRAWAL',
      'min_paise', v_min, 'available_paise', v_sum); END IF;

  INSERT INTO public.partner_payouts (partner_id, amount_paise, status, payout_method_id)
    VALUES (p_partner, v_sum, 'REQUESTED', p_method) RETURNING id INTO v_payout;
  UPDATE public.partner_earnings SET status='INCLUDED_IN_PAYOUT', payout_id=v_payout
    WHERE partner_id=p_partner AND status='PENDING_PAYOUT';
  RETURN jsonb_build_object('success',true,'payout_id',v_payout,'amount_paise',v_sum);
END $$;

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

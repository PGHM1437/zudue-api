-- 0024 · Real admin administration: close every gap found while auditing the
-- admin surface against the actual admin panel (Manage Partners, Manage Fans,
-- KYC, Video Calls, DMs, Shout-Outs, Payments, Withdrawals, Reports, Promo &
-- Referrals, Settings).
--
-- Findings fixed here:
--  1. God-row self-escalation: RLS gave owners row-level UPDATE on tables that
--     mix self-editable columns with admin-only columns (profiles.role/
--     account_status/verification_status, partner_profiles.is_premium/
--     is_featured/status/commission_rate, partner_social_links.is_approved,
--     payout_methods.is_verified, partner_services.is_available_for_platform).
--     RLS is row-level only — nothing stopped a user UPDATE-ing their OWN row
--     and flipping an admin-only column. Fixed with a generic BEFORE UPDATE
--     guard trigger.
--  2. reports table (the generic PROFILE/CALL/DM/MESSAGE moderation queue) had
--     no admin write policy AND no resolution RPC — reports could be filed but
--     never acted on. Fixed.
--  3. disputes table had RLS write access but no business-logic RPC — an admin
--     UPDATE of disputes.status='LOST' would not actually move any money or
--     leave an audit trail. Fixed.
--  4. admin_profiles (admin_role/permissions) was 100% decorative: is_admin()
--     only ever checked profiles.role='ADMIN', never admin_profiles at all, so
--     every admin had identical blanket power and there was no governed path
--     to create/revoke an admin in the first place. Fixed with is_admin_role()
--     tiering (already wired into 0023's money-moving RPCs) and a create/revoke
--     RPC pair.
--  5. is_premium had no admin RPC or audit columns (asymmetric with
--     is_featured, which had both).
--  6. No manual goodwill/adjustment credit tool, no promo activate/deactivate,
--     no partner-application reject, no payout-method/social-link verification
--     RPC, no platform_settings change audit.

BEGIN;

-- ── 1. God-row column guard ──────────────────────────────────────────────
CREATE OR REPLACE FUNCTION guard_protected_columns()
RETURNS trigger LANGUAGE plpgsql SET search_path = '' AS $$
DECLARE v_col text;
BEGIN
  IF public.is_admin() THEN RETURN NEW; END IF;
  FOREACH v_col IN ARRAY TG_ARGV LOOP
    IF to_jsonb(NEW) -> v_col IS DISTINCT FROM to_jsonb(OLD) -> v_col THEN
      RAISE EXCEPTION 'FORBIDDEN: column % is admin-only and cannot be changed by the row owner', v_col
        USING ERRCODE = '42501';
    END IF;
  END LOOP;
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS trg_guard_profiles_admin_cols ON profiles;
CREATE TRIGGER trg_guard_profiles_admin_cols BEFORE UPDATE ON profiles
  FOR EACH ROW EXECUTE FUNCTION guard_protected_columns(
    'role','account_status','status_reason','status_changed_at','status_changed_by',
    'verification_status','kyc_verified_at','kyc_verified_by_admin_id','kyc_rejection_reason');

-- (premium_at/premium_by_admin_id/premium_reason added below, before this trigger needs them)
ALTER TABLE partner_profiles
  ADD COLUMN IF NOT EXISTS premium_at timestamptz,
  ADD COLUMN IF NOT EXISTS premium_by_admin_id uuid,
  ADD COLUMN IF NOT EXISTS premium_reason text;

DROP TRIGGER IF EXISTS trg_guard_partner_profiles_admin_cols ON partner_profiles;
CREATE TRIGGER trg_guard_partner_profiles_admin_cols BEFORE UPDATE ON partner_profiles
  FOR EACH ROW EXECUTE FUNCTION guard_protected_columns(
    'status','approved_by_admin_id','approved_at','rejection_reason',
    'is_premium','premium_at','premium_by_admin_id','premium_reason',
    'is_featured','featured_at','featured_by_admin_id','featured_reason',
    'commission_rate');

DROP TRIGGER IF EXISTS trg_guard_social_links_admin_cols ON partner_social_links;
CREATE TRIGGER trg_guard_social_links_admin_cols BEFORE UPDATE ON partner_social_links
  FOR EACH ROW EXECUTE FUNCTION guard_protected_columns('is_approved','approved_by_admin_id');

DROP TRIGGER IF EXISTS trg_guard_payout_methods_admin_cols ON payout_methods;
CREATE TRIGGER trg_guard_payout_methods_admin_cols BEFORE UPDATE ON payout_methods
  FOR EACH ROW EXECUTE FUNCTION guard_protected_columns('is_verified','verified_by_admin_id','verified_at');

DROP TRIGGER IF EXISTS trg_guard_partner_services_admin_cols ON partner_services;
CREATE TRIGGER trg_guard_partner_services_admin_cols BEFORE UPDATE ON partner_services
  FOR EACH ROW EXECUTE FUNCTION guard_protected_columns('is_available_for_platform');

-- ── 2. RLS: reports resolvable, applications advanceable by admin ──────────
CREATE POLICY report_admin_update ON reports FOR UPDATE USING (is_admin());
CREATE POLICY application_admin_update ON partner_applications FOR UPDATE USING (is_admin());

-- ── 3. Generic report resolution (PROFILE/CALL/DM/MESSAGE; SHOUTOUT uses its
--      own dedicated flow — rpc_admin_resolve_shoutout_report). Refund is
--      wired only where the target maps unambiguously to a live escrow
--      (CALL → its booking; DM → its conversation window); other target
--      types reject a refund attempt explicitly rather than guess. ──
CREATE OR REPLACE FUNCTION rpc_admin_resolve_report(
  p_admin uuid, p_report uuid, p_status report_status, p_resolution text DEFAULT NULL,
  p_refund_paise bigint DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE rep public.reports; v_wallet uuid; v_res jsonb; v_amt bigint;
        v_window public.conversation_windows; v_call public.calls; v_booking public.bookings;
BEGIN
  PERFORM public.assert_is_admin_actor(p_admin);
  SELECT * INTO rep FROM public.reports WHERE id=p_report FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('success',false,'error','NOT_FOUND'); END IF;

  IF p_refund_paise IS NOT NULL AND p_refund_paise > 0 THEN
    PERFORM public.assert_admin_role('FINANCE','SUPER_ADMIN');

    IF rep.target_type = 'CALL' THEN
      SELECT * INTO v_call FROM public.calls WHERE id=rep.target_id;
      IF NOT FOUND THEN RETURN jsonb_build_object('success',false,'error','CALL_NOT_FOUND'); END IF;
      SELECT * INTO v_booking FROM public.bookings WHERE id=v_call.booking_id FOR UPDATE;
      IF NOT FOUND OR v_booking.status <> 'COMPLETED_SUCCESSFUL' OR now() > v_booking.settle_at THEN
        RETURN jsonb_build_object('success',false,'error','NOT_REFUNDABLE',
          'hint','use rpc_refund_booking for a pre-settlement cancellation instead'); END IF;
      v_amt := least(p_refund_paise, v_booking.price_paise);
      SELECT id INTO v_wallet FROM public.wallets WHERE profile_id=v_booking.fan_id;
      v_res := public.post_transaction('REFUND', v_amt, 'report-refund:'||rep.id::text,
        jsonb_build_array(
          jsonb_build_object('account','booking_escrow','delta_paise',-v_amt),
          jsonb_build_object('wallet_id',v_wallet,'account','wallet','delta_paise',v_amt)),
        rep.id::text);
      UPDATE public.transactions SET refund_reason='DISPUTE' WHERE id=(v_res->>'transaction_id')::uuid;
      UPDATE public.bookings SET status='CANCELLED_BY_ADMIN', updated_at=now() WHERE id=v_booking.id;

    ELSIF rep.target_type = 'DM' THEN
      SELECT * INTO v_window FROM public.conversation_windows WHERE id=rep.target_id FOR UPDATE;
      IF NOT FOUND OR v_window.kind <> 'PAID' OR v_window.status = 'REFUNDED' OR now() > v_window.settle_at THEN
        RETURN jsonb_build_object('success',false,'error','NOT_REFUNDABLE'); END IF;
      v_amt := least(p_refund_paise, v_window.charge_paise);
      SELECT w.id INTO v_wallet FROM public.wallets w JOIN public.conversations c ON c.fan_id = w.profile_id
        WHERE c.id = v_window.conversation_id;
      v_res := public.post_transaction('REFUND', v_amt, 'report-refund:'||rep.id::text,
        jsonb_build_array(
          jsonb_build_object('account','booking_escrow','delta_paise',-v_amt),
          jsonb_build_object('wallet_id',v_wallet,'account','wallet','delta_paise',v_amt)),
        rep.id::text);
      UPDATE public.transactions SET refund_reason='DISPUTE' WHERE id=(v_res->>'transaction_id')::uuid;
      UPDATE public.conversation_windows SET status='REFUNDED', updated_at=now() WHERE id=v_window.id;

    ELSE
      RETURN jsonb_build_object('success',false,'error','REFUND_NOT_SUPPORTED_FOR_TARGET_TYPE');
    END IF;
  END IF;

  UPDATE public.reports SET status=p_status, resolution=p_resolution,
    refund_paise = COALESCE(p_refund_paise, refund_paise),
    resolved_by=p_admin, resolved_at=now() WHERE id=p_report;
  INSERT INTO public.audit_log (actor_id, actor_role, action, target_type, target_id, new_value)
    VALUES (p_admin,'ADMIN','RESOLVE_REPORT','report',p_report,
      jsonb_build_object('status',p_status,'resolution',p_resolution,'refund_paise',p_refund_paise));
  RETURN jsonb_build_object('success',true);
END $$;

-- ── 4. Dispute resolution (Razorpay chargebacks). LOST records the platform
--      absorbing the loss into a dedicated 'dispute_losses' ledger account —
--      it does NOT attempt to claw back an already-paid partner settlement;
--      whether/how to recover a chargeback loss from a partner is a business
--      policy decision, not something to decide silently in a DB migration. ──
CREATE OR REPLACE FUNCTION rpc_admin_resolve_dispute(p_admin uuid, p_dispute uuid, p_status dispute_status, p_notes text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE d public.disputes; v_res jsonb;
BEGIN
  PERFORM public.assert_is_admin_actor(p_admin);
  PERFORM public.assert_admin_role('FINANCE','SUPER_ADMIN');
  SELECT * INTO d FROM public.disputes WHERE id=p_dispute FOR UPDATE;
  IF NOT FOUND OR d.status NOT IN ('OPEN','UNDER_REVIEW') THEN
    RETURN jsonb_build_object('success',false,'error','INVALID_STATE'); END IF;

  IF p_status = 'LOST' THEN
    v_res := public.post_transaction('ADJUSTMENT', d.amount_paise, 'dispute-lost:'||d.id::text,
      jsonb_build_array(
        jsonb_build_object('account','razorpay_clearing','delta_paise',-d.amount_paise),
        jsonb_build_object('account','dispute_losses','delta_paise',d.amount_paise)));
    IF d.transaction_id IS NOT NULL THEN
      UPDATE public.transactions SET status='REVERSED' WHERE id=d.transaction_id;
    END IF;
  END IF;

  UPDATE public.disputes SET status=p_status, resolved_at=now() WHERE id=p_dispute;
  INSERT INTO public.audit_log (actor_id, actor_role, action, target_type, target_id, new_value)
    VALUES (p_admin,'ADMIN','RESOLVE_DISPUTE','dispute',p_dispute, jsonb_build_object('status',p_status,'notes',p_notes));
  RETURN jsonb_build_object('success',true);
END $$;

-- ── 5. Admin user management (was completely ungoverned) ───────────────────
CREATE OR REPLACE FUNCTION rpc_admin_create_admin(p_admin uuid, p_target uuid, p_role admin_role, p_permissions jsonb DEFAULT '{}')
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM public.assert_is_admin_actor(p_admin);
  PERFORM public.assert_admin_role('SUPER_ADMIN');
  IF NOT EXISTS (SELECT 1 FROM public.profiles WHERE id=p_target) THEN
    RETURN jsonb_build_object('success',false,'error','PROFILE_NOT_FOUND'); END IF;
  UPDATE public.profiles SET role='ADMIN', updated_at=now() WHERE id=p_target;
  INSERT INTO public.admin_profiles (profile_id, admin_role, permissions)
    VALUES (p_target, p_role, p_permissions)
    ON CONFLICT (profile_id) DO UPDATE SET admin_role=p_role, permissions=p_permissions, updated_at=now();
  INSERT INTO public.audit_log (actor_id, actor_role, action, target_type, target_id, new_value)
    VALUES (p_admin,'ADMIN','CREATE_ADMIN','profile',p_target, jsonb_build_object('admin_role',p_role));
  RETURN jsonb_build_object('success',true);
END $$;

CREATE OR REPLACE FUNCTION rpc_admin_revoke_admin(p_admin uuid, p_target uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_was_partner boolean;
BEGIN
  PERFORM public.assert_is_admin_actor(p_admin);
  PERFORM public.assert_admin_role('SUPER_ADMIN');
  IF p_target = p_admin THEN
    RETURN jsonb_build_object('success',false,'error','CANNOT_REVOKE_SELF'); END IF;
  DELETE FROM public.admin_profiles WHERE profile_id=p_target;
  IF NOT FOUND THEN RETURN jsonb_build_object('success',false,'error','NOT_AN_ADMIN'); END IF;
  -- is_admin() checks profiles.role alone, so the role flip (not just the
  -- admin_profiles delete) is what actually revokes blanket admin power.
  SELECT EXISTS(SELECT 1 FROM public.partner_profiles WHERE profile_id=p_target) INTO v_was_partner;
  UPDATE public.profiles SET role = CASE WHEN v_was_partner THEN 'PARTNER' ELSE 'FAN' END, updated_at=now()
    WHERE id=p_target;
  INSERT INTO public.audit_log (actor_id, actor_role, action, target_type, target_id)
    VALUES (p_admin,'ADMIN','REVOKE_ADMIN','profile',p_target);
  RETURN jsonb_build_object('success',true);
END $$;

-- ── 6. is_premium parity with is_featured (RPC + audit trail + audit_log) ──
CREATE OR REPLACE FUNCTION rpc_admin_toggle_premium(p_admin uuid, p_partner uuid, p_on boolean, p_reason text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM public.assert_is_admin_actor(p_admin);
  UPDATE public.partner_profiles SET is_premium=p_on,
    premium_at = CASE WHEN p_on THEN now() END, premium_by_admin_id = CASE WHEN p_on THEN p_admin END,
    premium_reason = CASE WHEN p_on THEN p_reason END, updated_at=now() WHERE profile_id=p_partner;
  IF NOT FOUND THEN RETURN jsonb_build_object('success',false,'error','NOT_FOUND'); END IF;
  INSERT INTO public.audit_log (actor_id, actor_role, action, target_type, target_id, new_value)
    VALUES (p_admin,'ADMIN','TOGGLE_PREMIUM','partner_profile',p_partner, jsonb_build_object('on',p_on,'reason',p_reason));
  RETURN jsonb_build_object('success',true);
END $$;

-- ── 7. Partner application reject (approve already existed; reject didn't) ──
CREATE OR REPLACE FUNCTION rpc_admin_reject_partner(p_admin uuid, p_partner uuid, p_reason text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM public.assert_is_admin_actor(p_admin);
  UPDATE public.partner_profiles SET status='REJECTED_ONBOARDING', rejection_reason=p_reason, updated_at=now()
    WHERE profile_id=p_partner;
  IF NOT FOUND THEN RETURN jsonb_build_object('success',false,'error','NOT_FOUND'); END IF;
  INSERT INTO public.audit_log (actor_id, actor_role, action, target_type, target_id, new_value)
    VALUES (p_admin,'ADMIN','REJECT_PARTNER','partner_profile',p_partner, jsonb_build_object('reason',p_reason));
  RETURN jsonb_build_object('success',true);
END $$;

-- ── 8. Payout-method and social-link verification (columns already existed,
--      no RPC ever set them — the "Manage Partners" verification step). ──
CREATE OR REPLACE FUNCTION rpc_admin_verify_payout_method(p_admin uuid, p_method uuid, p_verified boolean)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM public.assert_is_admin_actor(p_admin);
  UPDATE public.payout_methods SET is_verified=p_verified,
    verified_by_admin_id = CASE WHEN p_verified THEN p_admin END,
    verified_at = CASE WHEN p_verified THEN now() END, updated_at=now()
    WHERE id=p_method;
  IF NOT FOUND THEN RETURN jsonb_build_object('success',false,'error','NOT_FOUND'); END IF;
  INSERT INTO public.audit_log (actor_id, actor_role, action, target_type, target_id, new_value)
    VALUES (p_admin,'ADMIN','VERIFY_PAYOUT_METHOD','payout_method',p_method, jsonb_build_object('verified',p_verified));
  RETURN jsonb_build_object('success',true);
END $$;

CREATE OR REPLACE FUNCTION rpc_admin_approve_social_link(p_admin uuid, p_link uuid, p_approved boolean)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM public.assert_is_admin_actor(p_admin);
  UPDATE public.partner_social_links SET is_approved=p_approved,
    approved_by_admin_id = CASE WHEN p_approved THEN p_admin END, updated_at=now()
    WHERE id=p_link;
  IF NOT FOUND THEN RETURN jsonb_build_object('success',false,'error','NOT_FOUND'); END IF;
  INSERT INTO public.audit_log (actor_id, actor_role, action, target_type, target_id, new_value)
    VALUES (p_admin,'ADMIN','APPROVE_SOCIAL_LINK','partner_social_link',p_link, jsonb_build_object('approved',p_approved));
  RETURN jsonb_build_object('success',true);
END $$;

CREATE OR REPLACE FUNCTION rpc_admin_set_service_platform_availability(p_admin uuid, p_service uuid, p_available boolean)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM public.assert_is_admin_actor(p_admin);
  UPDATE public.partner_services SET is_available_for_platform=p_available, updated_at=now() WHERE id=p_service;
  IF NOT FOUND THEN RETURN jsonb_build_object('success',false,'error','NOT_FOUND'); END IF;
  INSERT INTO public.audit_log (actor_id, actor_role, action, target_type, target_id, new_value)
    VALUES (p_admin,'ADMIN','SET_SERVICE_PLATFORM_AVAILABILITY','partner_service',p_service, jsonb_build_object('available',p_available));
  RETURN jsonb_build_object('success',true);
END $$;

-- ── 9. Promo activate/deactivate (create existed; toggling didn't) ─────────
CREATE OR REPLACE FUNCTION rpc_admin_set_promo_active(p_admin uuid, p_promo uuid, p_active boolean)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM public.assert_is_admin_actor(p_admin);
  PERFORM public.assert_admin_role('FINANCE','SUPER_ADMIN');
  UPDATE public.promo_codes SET is_active=p_active, updated_at=now() WHERE id=p_promo;
  IF NOT FOUND THEN RETURN jsonb_build_object('success',false,'error','NOT_FOUND'); END IF;
  INSERT INTO public.audit_log (actor_id, actor_role, action, target_type, target_id, new_value)
    VALUES (p_admin,'ADMIN','SET_PROMO_ACTIVE','promo_code',p_promo, jsonb_build_object('active',p_active));
  RETURN jsonb_build_object('success',true);
END $$;

-- ── 10. Manual goodwill / adjustment credit (support compensating a fan) ───
CREATE OR REPLACE FUNCTION rpc_admin_grant_credit(p_admin uuid, p_profile uuid, p_amount_paise bigint, p_source credit_source, p_reason text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_wallet uuid; v_res jsonb;
BEGIN
  PERFORM public.assert_is_admin_actor(p_admin);
  PERFORM public.assert_admin_role('FINANCE','SUPER_ADMIN');
  IF p_amount_paise = 0 THEN RETURN jsonb_build_object('success',false,'error','ZERO_AMOUNT'); END IF;
  SELECT id INTO v_wallet FROM public.wallets WHERE profile_id=p_profile;
  IF v_wallet IS NULL THEN RETURN jsonb_build_object('success',false,'error','NO_WALLET'); END IF;

  v_res := public.post_transaction('ADJUSTMENT', abs(p_amount_paise), 'admin-credit:'||gen_random_uuid()::text,
    jsonb_build_array(
      jsonb_build_object('wallet_id',v_wallet,'account','wallet','delta_paise',p_amount_paise,
        'bonus_delta_paise', CASE WHEN p_amount_paise > 0 THEN p_amount_paise ELSE 0 END),
      jsonb_build_object('account','platform_adjustment','delta_paise',-p_amount_paise)),
    NULL, jsonb_build_object('reason',p_reason,'admin',p_admin));

  IF p_amount_paise > 0 THEN
    INSERT INTO public.credit_grants (profile_id, source, amount_paise, transaction_id, reference)
      VALUES (p_profile, p_source, p_amount_paise, (v_res->>'transaction_id')::uuid, p_admin::text);
  END IF;
  INSERT INTO public.audit_log (actor_id, actor_role, action, target_type, target_id, new_value)
    VALUES (p_admin,'ADMIN','GRANT_CREDIT','profile',p_profile, jsonb_build_object('amount_paise',p_amount_paise,'source',p_source,'reason',p_reason));
  RETURN jsonb_build_object('success',true,'transaction_id',v_res->>'transaction_id');
END $$;

-- ── 11. platform_settings: auto-stamp who changed it + audit every change ──
CREATE OR REPLACE FUNCTION audit_platform_settings_change()
RETURNS trigger LANGUAGE plpgsql SET search_path = '' AS $$
BEGIN
  NEW.last_updated_by_admin_id := public.current_user_id();
  INSERT INTO public.audit_log (actor_id, actor_role, action, target_type, target_id, old_value, new_value)
    VALUES (public.current_user_id(), 'ADMIN', 'UPDATE_PLATFORM_SETTINGS', 'platform_settings', NEW.id,
      to_jsonb(OLD), to_jsonb(NEW));
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS trg_audit_platform_settings ON platform_settings;
CREATE TRIGGER trg_audit_platform_settings BEFORE UPDATE ON platform_settings
  FOR EACH ROW EXECUTE FUNCTION audit_platform_settings_change();

REVOKE ALL ON FUNCTION rpc_admin_create_admin(uuid,uuid,admin_role,jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION rpc_admin_revoke_admin(uuid,uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION rpc_admin_grant_credit(uuid,uuid,bigint,credit_source,text) FROM PUBLIC;
REVOKE ALL ON FUNCTION rpc_admin_resolve_dispute(uuid,uuid,dispute_status,text) FROM PUBLIC;
REVOKE ALL ON FUNCTION rpc_admin_resolve_report(uuid,uuid,report_status,text,bigint) FROM PUBLIC;

-- Same overload guard as 0022/0023 — must still hold.
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

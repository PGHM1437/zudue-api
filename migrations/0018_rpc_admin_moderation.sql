-- 0018 · Admin, moderation, blocking, referral crediting, waitlist.
-- Completes the admin surface the live DB was missing/messy (see ADMIN_GAPS_AND_FIXES.md).

BEGIN;

-- ── Blocking (global, both directions) ──
CREATE OR REPLACE FUNCTION rpc_block_user(p_blocker uuid, p_blocked uuid, p_scope block_scope DEFAULT 'ALL', p_by_admin boolean DEFAULT false, p_reason text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  INSERT INTO public.user_blocks (blocker_id, blocked_id, scope, reason, created_by_admin)
    VALUES (p_blocker, p_blocked, p_scope, p_reason, p_by_admin)
    ON CONFLICT (blocker_id, blocked_id, scope) DO NOTHING;
  RETURN jsonb_build_object('success',true);
END $$;

CREATE OR REPLACE FUNCTION rpc_unblock_user(p_blocker uuid, p_blocked uuid, p_scope block_scope DEFAULT 'ALL')
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  DELETE FROM public.user_blocks WHERE blocker_id=p_blocker AND blocked_id=p_blocked AND scope=p_scope;
  RETURN jsonb_build_object('success',true);
END $$;

-- ── Admin: set a user's account status (suspend / ban / reactivate) ──
CREATE OR REPLACE FUNCTION rpc_admin_set_account_status(p_admin uuid, p_user uuid, p_status user_account_status, p_reason text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  UPDATE public.profiles SET account_status=p_status, status_reason=p_reason,
    status_changed_at=now(), status_changed_by=p_admin, updated_at=now() WHERE id=p_user;
  IF NOT FOUND THEN RETURN jsonb_build_object('success',false,'error','USER_NOT_FOUND'); END IF;
  INSERT INTO public.audit_log (actor_id, actor_role, action, target_type, target_id, new_value)
    VALUES (p_admin,'ADMIN','SET_ACCOUNT_STATUS','profile',p_user, jsonb_build_object('status',p_status,'reason',p_reason));
  RETURN jsonb_build_object('success',true);
END $$;

-- ── Admin: approve / reject a partner ──
CREATE OR REPLACE FUNCTION rpc_admin_approve_partner(p_admin uuid, p_partner uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  UPDATE public.partner_profiles SET status='ACTIVE', approved_by_admin_id=p_admin, approved_at=now(), updated_at=now()
    WHERE profile_id=p_partner;
  IF NOT FOUND THEN RETURN jsonb_build_object('success',false,'error','NOT_FOUND'); END IF;
  UPDATE public.profiles SET verification_status='VERIFIED', updated_at=now() WHERE id=p_partner;
  INSERT INTO public.audit_log (actor_id, actor_role, action, target_type, target_id)
    VALUES (p_admin,'ADMIN','APPROVE_PARTNER','partner_profile',p_partner);
  RETURN jsonb_build_object('success',true);
END $$;

-- ── Admin: KYC verification decision ──
CREATE OR REPLACE FUNCTION rpc_admin_manage_kyc(p_admin uuid, p_user uuid, p_verified boolean, p_reason text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  UPDATE public.profiles SET
    verification_status = CASE WHEN p_verified THEN 'VERIFIED'::verification_status ELSE 'REJECTED'::verification_status END,
    kyc_verified_at = CASE WHEN p_verified THEN now() END,
    kyc_verified_by_admin_id = p_admin, kyc_rejection_reason = CASE WHEN NOT p_verified THEN p_reason END,
    updated_at=now() WHERE id=p_user;
  IF NOT FOUND THEN RETURN jsonb_build_object('success',false,'error','NOT_FOUND'); END IF;
  RETURN jsonb_build_object('success',true);
END $$;

-- ── Admin: set a partner's reference commission rate (offline settlement) ──
CREATE OR REPLACE FUNCTION rpc_admin_set_commission(p_admin uuid, p_partner uuid, p_rate numeric)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  UPDATE public.partner_profiles SET commission_rate=p_rate, updated_at=now() WHERE profile_id=p_partner;
  IF NOT FOUND THEN RETURN jsonb_build_object('success',false,'error','NOT_FOUND'); END IF;
  INSERT INTO public.audit_log (actor_id, actor_role, action, target_type, target_id, new_value)
    VALUES (p_admin,'ADMIN','SET_COMMISSION','partner_profile',p_partner, jsonb_build_object('rate',p_rate));
  RETURN jsonb_build_object('success',true);
END $$;

-- ── Admin: featured / premium toggles ──
CREATE OR REPLACE FUNCTION rpc_admin_toggle_featured(p_admin uuid, p_partner uuid, p_on boolean, p_reason text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  UPDATE public.partner_profiles SET is_featured=p_on,
    featured_at = CASE WHEN p_on THEN now() END, featured_by_admin_id = CASE WHEN p_on THEN p_admin END,
    featured_reason = CASE WHEN p_on THEN p_reason END, updated_at=now() WHERE profile_id=p_partner;
  RETURN jsonb_build_object('success',FOUND);
END $$;

-- ── Admin: create / deactivate promo code (governed) ──
CREATE OR REPLACE FUNCTION rpc_admin_create_promo(p_admin uuid, p_code text, p_type promo_code_discount_type_enum,
  p_value numeric, p_applies promo_code_service_applicability_enum DEFAULT 'ALL',
  p_max_total int DEFAULT NULL, p_max_per_user int DEFAULT NULL, p_expiry timestamptz DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_id uuid;
BEGIN
  IF p_value <= 0 THEN RETURN jsonb_build_object('success',false,'error','INVALID_VALUE'); END IF;
  INSERT INTO public.promo_codes (code, discount_type, discount_value, applies_to, max_uses_total, max_uses_per_user, expiry_date, created_by_admin_id)
    VALUES (upper(p_code), p_type, p_value, p_applies, p_max_total, p_max_per_user, p_expiry, p_admin) RETURNING id INTO v_id;
  RETURN jsonb_build_object('success',true,'promo_id',v_id);
END $$;

-- ── Referral crediting (the half-built feature — now IMPLEMENTED) ──
-- Called when a referee completes their FIRST paid service → credit BOTH as BONUS.
CREATE OR REPLACE FUNCTION rpc_credit_referral(p_referee uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE r public.referrals; v_referrer_amt bigint; v_referee_amt bigint;
        v_rw uuid; v_ew uuid;
BEGIN
  SELECT * INTO r FROM public.referrals WHERE referee_id=p_referee AND status <> 'COMPLETED_REWARDED' FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('success',false,'error','NO_PENDING_REFERRAL'); END IF;

  SELECT referral_referrer_reward_paise, referral_referee_reward_paise INTO v_referrer_amt, v_referee_amt
    FROM public.platform_settings WHERE id=1;
  SELECT id INTO v_rw FROM public.wallets WHERE profile_id=r.referrer_id;
  SELECT id INTO v_ew FROM public.wallets WHERE profile_id=r.referee_id;

  -- BONUS credits: wallet + bonus bucket up, funded by platform (referral_incentive account)
  PERFORM public.post_transaction('ADJUSTMENT', v_referrer_amt, 'ref-rr:'||r.id::text,
    jsonb_build_array(
      jsonb_build_object('wallet_id',v_rw,'account','wallet','delta_paise',v_referrer_amt,'bonus_delta_paise',v_referrer_amt),
      jsonb_build_object('account','referral_incentive','delta_paise',-v_referrer_amt)));
  IF v_ew IS NOT NULL THEN
    PERFORM public.post_transaction('ADJUSTMENT', v_referee_amt, 'ref-re:'||r.id::text,
      jsonb_build_array(
        jsonb_build_object('wallet_id',v_ew,'account','wallet','delta_paise',v_referee_amt,'bonus_delta_paise',v_referee_amt),
        jsonb_build_object('account','referral_incentive','delta_paise',-v_referee_amt)));
  END IF;

  INSERT INTO public.credit_grants (profile_id, source, amount_paise, reference)
    VALUES (r.referrer_id,'REFERRAL',v_referrer_amt, r.id::text), (r.referee_id,'REFERRAL',v_referee_amt, r.id::text);
  UPDATE public.referrals SET status='COMPLETED_REWARDED', referrer_reward_paise=v_referrer_amt,
    referee_reward_paise=v_referee_amt, referrer_credited_at=now(), referee_credited_at=now(), updated_at=now()
    WHERE id=r.id;
  RETURN jsonb_build_object('success',true,'referrer_credited',v_referrer_amt,'referee_credited',v_referee_amt);
END $$;

-- ── Waitlist: join + notify-when-available (ONE auto notification) ──
CREATE OR REPLACE FUNCTION rpc_join_waitlist(p_fan uuid, p_partner uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  INSERT INTO public.waitlist (fan_id, partner_id) VALUES (p_fan, p_partner)
    ON CONFLICT (fan_id, partner_id) DO NOTHING;
  RETURN jsonb_build_object('success',true);
END $$;

-- Fire the single notification to everyone waiting when a partner frees up.
CREATE OR REPLACE FUNCTION rpc_notify_waitlist(p_partner uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_count int;
BEGIN
  INSERT INTO public.notifications (recipient_id, event_type, title, message, related_entity_type, related_entity_id)
    SELECT w.fan_id, 'PLATFORM_ANNOUNCEMENT', 'A creator is available',
           'A creator you follow is now available to book.', 'user_profile', p_partner
    FROM public.waitlist w WHERE w.partner_id=p_partner AND w.status='WAITING';
  GET DIAGNOSTICS v_count = ROW_COUNT;
  UPDATE public.waitlist SET status='NOTIFIED', notified_at=now()
    WHERE partner_id=p_partner AND status='WAITING';
  RETURN jsonb_build_object('success',true,'notified',v_count);
END $$;

REVOKE ALL ON FUNCTION rpc_credit_referral(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION rpc_admin_set_account_status(uuid,uuid,user_account_status,text) FROM PUBLIC;
REVOKE ALL ON FUNCTION rpc_admin_approve_partner(uuid,uuid) FROM PUBLIC;

COMMIT;

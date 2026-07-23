-- 0034 · Close the six verified feature-parity gaps (A–F) from the fan/partner/
-- admin screen validation, each implemented in the new DB's own idiom.
--
-- Architectural key that unlocks B and F cleanly: the guard_protected_columns
-- trigger (0024) blocked the row owner from changing admin-only columns. But a
-- user legitimately needs to move their OWN verification_status to
-- PENDING_VERIFICATION (submit KYC) and touch account state on deletion — via a
-- vetted RPC, not a raw client write. Rather than punch per-column holes, the
-- guard now distinguishes *raw client writes* (current_user = session_user =
-- the connecting app role → still blocked) from *writes executing inside a
-- SECURITY DEFINER RPC* (current_user becomes the function owner, ≠ session_user
-- → allowed). The connecting role cannot fake current_user, so this is secure:
-- only our vetted RPCs (which validate the caller and control exactly what they
-- set) can reach protected columns; a raw `UPDATE profiles SET role='ADMIN'`
-- from zudue_app is still rejected. Superuser sessions (migrations/ops) pass too.

BEGIN;

-- ── Guard v2: admin OR definer-context OR superuser; else enforce ──────────
CREATE OR REPLACE FUNCTION guard_protected_columns()
RETURNS trigger LANGUAGE plpgsql SET search_path = '' AS $$
DECLARE v_col text;
BEGIN
  IF public.is_admin() OR current_user IS DISTINCT FROM session_user THEN
    RETURN NEW;                       -- admin, or inside a SECURITY DEFINER RPC
  END IF;
  IF (SELECT rolsuper FROM pg_roles WHERE rolname = session_user) THEN
    RETURN NEW;                       -- superuser session (migrations, ops)
  END IF;
  FOREACH v_col IN ARRAY TG_ARGV LOOP
    IF to_jsonb(NEW) -> v_col IS DISTINCT FROM to_jsonb(OLD) -> v_col THEN
      RAISE EXCEPTION 'FORBIDDEN: column % is admin-only and cannot be changed by the row owner', v_col
        USING ERRCODE = '42501';
    END IF;
  END LOOP;
  RETURN NEW;
END $$;

-- ═══ GAP A · Fan can read their OWN money history (RLS-native) ═══
-- Owner may read ledger legs on their wallet, and any transaction that touched
-- their wallet. Admin policies from 0011 remain (OR'd).
CREATE POLICY ledger_owner_read ON ledger_entries FOR SELECT USING (
  wallet_id IN (SELECT id FROM wallets WHERE profile_id = current_user_id()));
CREATE POLICY txn_owner_read ON transactions FOR SELECT USING (
  EXISTS (SELECT 1 FROM ledger_entries le JOIN wallets w ON w.id = le.wallet_id
          WHERE le.transaction_id = transactions.id AND w.profile_id = current_user_id()));

-- ═══ GAP B · KYC submission (fan + partner) ═══
-- Insert the documents and move the submitter to PENDING_VERIFICATION. Runs as
-- SECURITY DEFINER so the guard's definer-context branch permits the status
-- write; the function itself only ever sets PENDING (never VERIFIED/REJECTED —
-- those stay admin-only via rpc_admin_manage_kyc).
CREATE OR REPLACE FUNCTION rpc_submit_kyc(p_documents jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_me uuid := public.current_user_id(); v_doc jsonb; v_status public.verification_status; v_n int := 0;
BEGIN
  IF v_me IS NULL THEN RETURN jsonb_build_object('success',false,'error','NO_IDENTITY'); END IF;
  PERFORM public.assert_active(v_me);
  SELECT verification_status INTO v_status FROM public.profiles WHERE id = v_me;
  IF v_status = 'VERIFIED' THEN RETURN jsonb_build_object('success',false,'error','ALREADY_VERIFIED'); END IF;
  IF p_documents IS NULL OR jsonb_array_length(p_documents) = 0 THEN
    RETURN jsonb_build_object('success',false,'error','NO_DOCUMENTS'); END IF;

  FOR v_doc IN SELECT * FROM jsonb_array_elements(p_documents) LOOP
    INSERT INTO public.kyc_documents (profile_id, document_type, storage_path, file_name)
      VALUES (v_me, v_doc->>'document_type', v_doc->>'storage_path', v_doc->>'file_name');
    v_n := v_n + 1;
  END LOOP;

  UPDATE public.profiles
     SET verification_status = 'PENDING_VERIFICATION', kyc_submitted_at = now(), updated_at = now()
   WHERE id = v_me;
  RETURN jsonb_build_object('success',true,'documents_uploaded',v_n,'status','PENDING_VERIFICATION');
END $$;

-- ═══ GAP C · Fan-facing price / promo preview (before paying) ═══
CREATE OR REPLACE FUNCTION rpc_preview_price(
  p_partner uuid, p_type service_type_enum,
  p_duration call_duration_options_enum DEFAULT NULL, p_promo_code text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  RETURN public.resolve_price(p_partner, p_type, p_duration, p_promo_code, public.current_user_id());
END $$;

-- ═══ GAP D · Partner-initiated free DM follow-up (post-relationship) ═══
-- A partner may message a fan who has an existing conversation with them, free,
-- appended to the thread. Block-aware. No conversation ⇒ no cold outreach.
CREATE OR REPLACE FUNCTION rpc_partner_send_followup(p_fan uuid, p_text text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_partner uuid := public.current_user_id(); v_conv uuid; v_win uuid;
BEGIN
  IF v_partner IS NULL THEN RETURN jsonb_build_object('success',false,'error','NO_IDENTITY'); END IF;
  PERFORM public.assert_active(v_partner);
  IF public.is_blocked(v_partner, p_fan, 'DM') THEN
    RETURN jsonb_build_object('success',false,'error','BLOCKED'); END IF;

  SELECT id INTO v_conv FROM public.conversations WHERE fan_id = p_fan AND partner_id = v_partner;
  IF v_conv IS NULL THEN
    RETURN jsonb_build_object('success',false,'error','NO_CONVERSATION'); END IF;

  SELECT id INTO v_win FROM public.conversation_windows
    WHERE conversation_id = v_conv AND status = 'OPEN' ORDER BY opened_at DESC LIMIT 1;
  IF v_win IS NULL THEN
    INSERT INTO public.conversation_windows (conversation_id, kind, charge_paise, status)
      VALUES (v_conv, 'FREE', 0, 'OPEN') RETURNING id INTO v_win;
  END IF;

  INSERT INTO public.messages (window_id, sender, body) VALUES (v_win, 'PARTNER', p_text);
  UPDATE public.conversations SET last_activity_at = now() WHERE id = v_conv;
  RETURN jsonb_build_object('success',true,'window_id',v_win);
END $$;

-- ═══ GAP E · Two-stage partner verification & approval workflow ═══
-- Stage 1 (initial screen) → Stage 2 (await KYC + profile) → partner submits →
-- Stage 3 (final approval) → ACTIVE. Uses partner_applications.status +
-- the initial_/final_ review timestamp columns that already exist.
CREATE OR REPLACE FUNCTION rpc_admin_review_application(
  p_admin uuid, p_application uuid, p_decision text, p_reason text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE a public.partner_applications;
BEGIN
  PERFORM public.assert_is_admin_actor(p_admin);
  SELECT * INTO a FROM public.partner_applications WHERE id = p_application FOR UPDATE;
  IF NOT FOUND OR a.status <> 'PENDING_INITIAL_REVIEW' THEN
    RETURN jsonb_build_object('success',false,'error','NOT_IN_INITIAL_REVIEW'); END IF;

  UPDATE public.partner_applications
     SET status = CASE WHEN p_decision='APPROVE' THEN 'AWAITING_KYC_AND_PROFILE_COMPLETION'::public.partner_application_status_enum
                       ELSE 'REJECTED_INITIAL'::public.partner_application_status_enum END,
         admin_notes = p_reason, initial_review_at = now(), initial_reviewed_by_admin_id = p_admin, updated_at = now()
   WHERE id = p_application;
  INSERT INTO public.audit_log (actor_id, actor_role, action, target_type, target_id, new_value)
    VALUES (p_admin,'ADMIN','REVIEW_APPLICATION_INITIAL','partner_application',p_application,
      jsonb_build_object('decision',p_decision,'reason',p_reason));
  RETURN jsonb_build_object('success',true,'decision',p_decision);
END $$;

-- Partner signals KYC + profile complete → moves to final-approval queue.
CREATE OR REPLACE FUNCTION rpc_partner_submit_for_review(p_application uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE a public.partner_applications; v_me uuid := public.current_user_id(); v_kyc public.verification_status; v_complete boolean;
BEGIN
  SELECT * INTO a FROM public.partner_applications WHERE id = p_application FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('success',false,'error','NOT_FOUND'); END IF;
  IF a.profile_id IS DISTINCT FROM v_me THEN RETURN jsonb_build_object('success',false,'error','FORBIDDEN'); END IF;
  IF a.status <> 'AWAITING_KYC_AND_PROFILE_COMPLETION' THEN
    RETURN jsonb_build_object('success',false,'error','NOT_AWAITING_COMPLETION'); END IF;

  SELECT verification_status INTO v_kyc FROM public.profiles WHERE id = v_me;
  SELECT profile_complete INTO v_complete FROM public.partner_profiles WHERE profile_id = v_me;
  IF v_kyc = 'NOT_SUBMITTED' THEN RETURN jsonb_build_object('success',false,'error','KYC_NOT_SUBMITTED'); END IF;
  IF v_complete IS NOT TRUE THEN RETURN jsonb_build_object('success',false,'error','PROFILE_INCOMPLETE'); END IF;

  UPDATE public.partner_applications SET status = 'PENDING_FINAL_ADMIN_APPROVAL', updated_at = now()
   WHERE id = p_application;
  RETURN jsonb_build_object('success',true,'status','PENDING_FINAL_ADMIN_APPROVAL');
END $$;

-- Stage 3: admin final decision → activate the partner, or reject.
CREATE OR REPLACE FUNCTION rpc_admin_final_approve_partner(
  p_admin uuid, p_application uuid, p_decision text, p_reason text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE a public.partner_applications;
BEGIN
  PERFORM public.assert_is_admin_actor(p_admin);
  SELECT * INTO a FROM public.partner_applications WHERE id = p_application FOR UPDATE;
  IF NOT FOUND OR a.status <> 'PENDING_FINAL_ADMIN_APPROVAL' THEN
    RETURN jsonb_build_object('success',false,'error','NOT_IN_FINAL_REVIEW'); END IF;

  IF p_decision = 'APPROVE' THEN
    UPDATE public.partner_applications SET status='ACTIVE', final_review_at=now(),
      final_reviewed_by_admin_id=p_admin, updated_at=now() WHERE id=p_application;
    IF a.profile_id IS NOT NULL THEN
      UPDATE public.partner_profiles SET status='ACTIVE', approved_by_admin_id=p_admin, approved_at=now(), updated_at=now()
        WHERE profile_id=a.profile_id;
      UPDATE public.profiles SET verification_status='VERIFIED', updated_at=now() WHERE id=a.profile_id;
    END IF;
  ELSE
    UPDATE public.partner_applications SET status='REJECTED_FINAL', admin_notes=p_reason,
      final_review_at=now(), final_reviewed_by_admin_id=p_admin, updated_at=now() WHERE id=p_application;
    IF a.profile_id IS NOT NULL THEN
      UPDATE public.partner_profiles SET status='REJECTED_ONBOARDING', rejection_reason=p_reason, updated_at=now()
        WHERE profile_id=a.profile_id;
    END IF;
  END IF;
  INSERT INTO public.audit_log (actor_id, actor_role, action, target_type, target_id, new_value)
    VALUES (p_admin,'ADMIN','REVIEW_APPLICATION_FINAL','partner_application',p_application,
      jsonb_build_object('decision',p_decision,'reason',p_reason));
  RETURN jsonb_build_object('success',true,'decision',p_decision);
END $$;

-- ═══ GAP F · Self-serve account deletion request (DPDP / Play compliant) ═══
CREATE OR REPLACE FUNCTION rpc_request_account_deletion(p_reason text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_me uuid := public.current_user_id(); v_id uuid; v_role public.user_role;
BEGIN
  IF v_me IS NULL THEN RETURN jsonb_build_object('success',false,'error','NO_IDENTITY'); END IF;
  IF EXISTS (SELECT 1 FROM public.deletion_requests WHERE profile_id=v_me AND status IN ('REQUESTED','CONFIRMED')) THEN
    RETURN jsonb_build_object('success',false,'error','ALREADY_REQUESTED'); END IF;

  INSERT INTO public.deletion_requests (profile_id, reason, status, confirm_token, scheduled_purge_at)
    VALUES (v_me, p_reason, 'REQUESTED', encode(public.gen_random_bytes(16),'hex'), now() + interval '30 days')
    RETURNING id INTO v_id;

  -- During the grace period a partner is pulled from discovery (owner-settable col).
  SELECT role INTO v_role FROM public.profiles WHERE id=v_me;
  IF v_role = 'PARTNER' THEN
    UPDATE public.partner_profiles SET is_active=false,
      deactivation_reason=COALESCE(deactivation_reason,'Pending account deletion'), updated_at=now()
      WHERE profile_id=v_me;
  END IF;
  RETURN jsonb_build_object('success',true,'deletion_request_id',v_id,'purge_after', (now()+interval '30 days'));
END $$;

CREATE OR REPLACE FUNCTION rpc_cancel_account_deletion()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_me uuid := public.current_user_id(); v_role public.user_role;
BEGIN
  IF v_me IS NULL THEN RETURN jsonb_build_object('success',false,'error','NO_IDENTITY'); END IF;
  UPDATE public.deletion_requests SET status='CANCELLED', completed_at=now()
   WHERE profile_id=v_me AND status IN ('REQUESTED','CONFIRMED');
  IF NOT FOUND THEN RETURN jsonb_build_object('success',false,'error','NO_PENDING_REQUEST'); END IF;
  SELECT role INTO v_role FROM public.profiles WHERE id=v_me;
  IF v_role = 'PARTNER' THEN
    UPDATE public.partner_profiles SET is_active=true, deactivation_reason=NULL, updated_at=now()
      WHERE profile_id=v_me AND deactivation_reason='Pending account deletion';
  END IF;
  RETURN jsonb_build_object('success',true);
END $$;

-- Lock down the SECURITY DEFINER surface.
REVOKE ALL ON FUNCTION rpc_submit_kyc(jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION rpc_preview_price(uuid,service_type_enum,call_duration_options_enum,text) FROM PUBLIC;
REVOKE ALL ON FUNCTION rpc_partner_send_followup(uuid,text) FROM PUBLIC;
REVOKE ALL ON FUNCTION rpc_admin_review_application(uuid,uuid,text,text) FROM PUBLIC;
REVOKE ALL ON FUNCTION rpc_partner_submit_for_review(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION rpc_admin_final_approve_partner(uuid,uuid,text,text) FROM PUBLIC;
REVOKE ALL ON FUNCTION rpc_request_account_deletion(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION rpc_cancel_account_deletion() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION rpc_submit_kyc(jsonb), rpc_preview_price(uuid,service_type_enum,call_duration_options_enum,text),
  rpc_partner_send_followup(uuid,text), rpc_admin_review_application(uuid,uuid,text,text),
  rpc_partner_submit_for_review(uuid), rpc_admin_final_approve_partner(uuid,uuid,text,text),
  rpc_request_account_deletion(text), rpc_cancel_account_deletion() TO zudue_app;

DO $$
DECLARE v_dupes text;
BEGIN
  SELECT string_agg(DISTINCT p.proname, ', ') INTO v_dupes
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname LIKE 'rpc_%'
  GROUP BY p.proname HAVING count(*) > 1;
  IF v_dupes IS NOT NULL THEN RAISE EXCEPTION 'Duplicate RPC overloads: %', v_dupes; END IF;
END $$;

COMMIT;

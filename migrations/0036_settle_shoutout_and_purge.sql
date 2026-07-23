-- 0036 · Close two money/compliance gaps found in a full audit of the app layer.
--
--  1. rpc_settle_shoutout — shout-outs had NO settlement path. rpc_settle_booking
--     and rpc_settle_window were the only functions that ever created a
--     partner_earnings row, so a delivered shout-out left its payment stuck in
--     booking_escrow forever and the creator was never credited. This mirrors
--     rpc_settle_booking exactly (shout-out payments also land in booking_escrow
--     — verified in rpc_request_shoutout), and is idempotent + status-gated so
--     it's safe to call from the settlement sweep without a caller-side guard.
--
--  2. rpc_purge_profile — the deletion sweep marked deletion_requests COMPLETED
--     without erasing anything. This actually anonymises PII (right-to-erasure /
--     DPDP), keeping the row for financial referential integrity (transactions,
--     ledger_entries, earnings all FK a profile and must be retained for audit).

BEGIN;

CREATE OR REPLACE FUNCTION rpc_settle_shoutout(p_shoutout uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE s public.shout_out_requests; v_res jsonb;
BEGIN
  PERFORM public.assert_system();   -- settlement sweep job / admin only
  SELECT * INTO s FROM public.shout_out_requests WHERE id = p_shoutout FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('success',false,'error','NOT_FOUND'); END IF;
  IF s.status <> 'VIDEO_DELIVERED_TO_FAN' THEN
    RETURN jsonb_build_object('success',false,'error','NOT_SETTLEABLE'); END IF;
  -- Idempotent: never create a second earning for the same shout-out.
  IF EXISTS (SELECT 1 FROM public.partner_earnings e WHERE e.service_id = p_shoutout) THEN
    RETURN jsonb_build_object('success',true,'already_settled',true); END IF;

  v_res := public.post_transaction('PARTNER_EARNING', s.price_paise, 'settle-so:'||s.id::text,
    jsonb_build_array(
      jsonb_build_object('account','booking_escrow','delta_paise',-s.price_paise),
      jsonb_build_object('account','partner_payable','delta_paise',s.price_paise)),
    s.id::text);

  INSERT INTO public.partner_earnings (partner_id, transaction_id, service_type, service_id, amount_paise)
  VALUES (s.partner_id, (v_res->>'transaction_id')::uuid, 'SHOUT_OUT', s.id, s.price_paise);

  RETURN jsonb_build_object('success',true,'transaction_id',v_res->>'transaction_id');
END $$;
REVOKE ALL ON FUNCTION rpc_settle_shoutout(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION rpc_settle_shoutout(uuid) TO zudue_app;

CREATE OR REPLACE FUNCTION rpc_purge_profile(p_profile uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM public.assert_system();   -- deletion sweep job / admin only
  -- Anonymise PII in place; the row itself is retained because financial
  -- records reference it. email is NOT NULL, so it gets a stable placeholder.
  UPDATE public.profiles
     SET full_name = 'Deleted user',
         email = 'deleted-' || p_profile::text || '@deleted.zudue.local',
         mobile_number = NULL, age = NULL, gender = NULL,
         referral_code = NULL, account_status = 'INACTIVE',
         notification_prefs = '{}'::jsonb, updated_at = now()
   WHERE id = p_profile;
  IF NOT FOUND THEN RETURN jsonb_build_object('success',false,'error','NOT_FOUND'); END IF;

  -- Partner-facing PII too, if they were a creator.
  UPDATE public.partner_profiles
     SET display_name = 'Deleted creator', bio = NULL, profile_image_path = NULL,
         is_active = false, vacation_mode = true, updated_at = now()
   WHERE profile_id = p_profile;

  -- KYC documents point at storage objects that must go — drop the references
  -- (the sweep is responsible for deleting the underlying R2 objects).
  DELETE FROM public.kyc_documents WHERE profile_id = p_profile;

  RETURN jsonb_build_object('success',true);
END $$;
REVOKE ALL ON FUNCTION rpc_purge_profile(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION rpc_purge_profile(uuid) TO zudue_app;

COMMIT;

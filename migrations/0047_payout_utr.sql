-- 0047 · UTR as a first-class, enforced payout field.
--
-- Payouts are settled OFFLINE (bank/UPI transfer done outside the platform),
-- so the UTR is the ONLY link between "we marked this creator paid" and money
-- actually leaving the bank. It is the reconciliation key for the whole payout
-- history, and it was a nullable, generically-named `reference` column that
-- rpc_process_payout accepted as an optional argument — a payout could be
-- marked PAID with no evidence whatsoever that a transfer occurred.
--
-- Three changes, all enforced in the database rather than the admin UI,
-- because the UI is not the only possible caller:
--
--   1. reference -> utr. The column now says what it holds. Renamed rather
--      than added: the table has 0 rows on both databases, so there is no
--      migration of existing values to get wrong.
--
--   2. UTR is MANDATORY on approval. rpc_process_payout now rejects an
--      approval without one. Rejection still needs no UTR — no money moved.
--
--   3. UTR is UNIQUE. The same bank reference cannot mark two payouts as
--      paid. This is the control that catches the realistic finance error:
--      pasting the previous transfer's UTR into the next payout, which would
--      otherwise silently close a payout that was never actually sent.
--
-- Format is validated permissively (6-30 alphanumerics, normalised to upper
-- case). Indian references vary by rail — NEFT is 16 chars, IMPS/UPI RRN is
-- 12 digits — so a strict per-rail pattern would reject legitimate transfers.
-- The goal is to stop empty/garbage values, not to police the bank.

BEGIN;

ALTER TABLE public.partner_payouts RENAME COLUMN reference TO utr;

-- Partial: only PAID rows carry a UTR, and multiple NULLs must stay legal.
CREATE UNIQUE INDEX partner_payouts_utr_uq
  ON public.partner_payouts (upper(utr)) WHERE utr IS NOT NULL;

CREATE OR REPLACE FUNCTION public.rpc_process_payout(p_payout uuid, p_approve boolean, p_reference text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE po public.partner_payouts; v_res jsonb; v_utr text;
BEGIN
  PERFORM public.assert_admin_role('FINANCE','SUPER_ADMIN');
  SELECT * INTO po FROM public.partner_payouts WHERE id=p_payout FOR UPDATE;
  IF NOT FOUND OR po.status NOT IN ('REQUESTED','APPROVED') THEN
    RETURN jsonb_build_object('success',false,'error','INVALID_STATE'); END IF;

  IF p_approve THEN
    -- The transfer happens offline; the UTR is the only proof it happened.
    -- Marking a payout PAID without one leaves the creator's earnings closed
    -- and nothing to reconcile against the bank statement.
    v_utr := upper(btrim(COALESCE(p_reference, '')));
    IF v_utr = '' THEN
      RETURN jsonb_build_object('success',false,'error','UTR_REQUIRED'); END IF;
    IF v_utr !~ '^[A-Z0-9]{6,30}$' THEN
      RETURN jsonb_build_object('success',false,'error','UTR_INVALID_FORMAT'); END IF;
    IF EXISTS (SELECT 1 FROM public.partner_payouts
                WHERE upper(utr) = v_utr AND id <> p_payout) THEN
      RETURN jsonb_build_object('success',false,'error','UTR_ALREADY_USED'); END IF;

    v_res := public.post_transaction('PAYOUT_DEBIT', po.amount_paise, 'payout:'||po.id::text,
      jsonb_build_array(
        jsonb_build_object('account','partner_payable','delta_paise',-po.amount_paise),
        jsonb_build_object('account','razorpay_clearing','delta_paise',po.amount_paise)),
      po.id::text);
    UPDATE public.partner_payouts
       SET status='PAID', utr=v_utr, transaction_id=(v_res->>'transaction_id')::uuid, processed_at=now()
     WHERE id=p_payout;
    UPDATE public.partner_earnings SET status='PAID' WHERE payout_id=p_payout;

    INSERT INTO public.audit_log (actor_id, actor_role, action, target_type, target_id, new_value)
      VALUES (public.current_user_id(),'ADMIN','PROCESS_PAYOUT','partner_payout',p_payout,
        jsonb_build_object('status','PAID','utr',v_utr,'amount_paise',po.amount_paise));

    -- The creator should learn their money moved, and with which reference.
    INSERT INTO public.notifications (recipient_id, event_type, title, message, related_entity_type, related_entity_id)
      VALUES (po.partner_id,'PAYOUT_PROCESSED_PARTNER','Payout sent',
              'Your payout has been transferred. Bank reference (UTR): '||v_utr,
              'payout', p_payout);

    RETURN jsonb_build_object('success',true,'status','PAID','utr',v_utr);
  ELSE
    UPDATE public.partner_payouts SET status='REJECTED', processed_at=now() WHERE id=p_payout;
    UPDATE public.partner_earnings SET status='PENDING_PAYOUT', payout_id=NULL WHERE payout_id=p_payout;

    INSERT INTO public.audit_log (actor_id, actor_role, action, target_type, target_id, new_value)
      VALUES (public.current_user_id(),'ADMIN','PROCESS_PAYOUT','partner_payout',p_payout,
        jsonb_build_object('status','REJECTED','amount_paise',po.amount_paise));

    INSERT INTO public.notifications (recipient_id, event_type, title, message, related_entity_type, related_entity_id)
      VALUES (po.partner_id,'PAYOUT_FAILED_PARTNER','Payout not processed',
              'Your withdrawal was not processed. Your earnings are available to withdraw again.',
              'payout', p_payout);

    RETURN jsonb_build_object('success',true,'status','REJECTED','earnings_released',true);
  END IF;
END $function$;

-- CREATE OR REPLACE VIEW cannot rename a column (0037), so drop and recreate.
DROP VIEW IF EXISTS public.vw_admin_processed_payouts;
CREATE VIEW vw_admin_processed_payouts AS
SELECT po.id AS payout_id,
       po.partner_id,
       pp.display_name,
       po.amount_paise,
       po.status,
       po.utr,
       po.requested_at,
       po.processed_at,
       pm.method_type
  FROM partner_payouts po
  JOIN partner_profiles pp ON pp.profile_id = po.partner_id
  JOIN payout_methods pm ON pm.id = po.payout_method_id
 WHERE po.status = ANY (ARRAY['PAID'::payout_status,'REJECTED'::payout_status]) AND is_admin();

ALTER VIEW vw_admin_processed_payouts SET (security_invoker = true);
REVOKE ALL ON public.vw_admin_processed_payouts FROM PUBLIC;
GRANT SELECT ON public.vw_admin_processed_payouts TO zudue_app;

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

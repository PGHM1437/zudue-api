-- 0045 · Give disputes a beginning, and the audit log a reader.
--
-- Two features that were built from the middle outward:
--
-- DISPUTES — rpc_admin_resolve_dispute correctly reverses money and the admin
-- page renders the queue, but NOTHING ever created a dispute row. 0009 scoped
-- the table to "Razorpay disputes / chargebacks" and 0028 granted
-- is_service_role() write access for exactly that, yet the webhook handler
-- only ever branched on payment.captured / order.paid — every chargeback event
-- fell through to the `ignored` path. The admin Disputes page could never show
-- anything. rpc_record_dispute is the missing ingestion point.
--
-- AUDIT LOG — every admin RPC writes to audit_log (approve partner, set
-- commission, resolve report, process payout, grant credit...). Nothing could
-- read it: no view, no endpoint, no page. An audit trail nobody can inspect
-- provides no accountability, which is the entire point of keeping one.

BEGIN;

-- ── Chargeback ingestion ────────────────────────────────────────────────
-- Service-role only: this is driven by the verified Razorpay webhook, never
-- by a user. Idempotent on razorpay_dispute_id because payment providers
-- retry aggressively and send multiple lifecycle events per dispute — a
-- repeat delivery must update the existing row, never insert a second one.
CREATE OR REPLACE FUNCTION rpc_record_dispute(
  p_razorpay_dispute_id text,
  p_razorpay_payment_id text,
  p_amount_paise        bigint,
  p_reason              text DEFAULT NULL,
  p_status              dispute_status DEFAULT 'OPEN')
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_txn uuid; v_id uuid; v_existing public.disputes;
BEGIN
  PERFORM public.assert_system();
  IF p_razorpay_dispute_id IS NULL OR p_amount_paise IS NULL OR p_amount_paise <= 0 THEN
    RETURN jsonb_build_object('success',false,'error','INVALID_INPUT'); END IF;

  -- Resolve the disputed payment back to our transaction. topup_orders is the
  -- only place a Razorpay payment id is recorded; a dispute for a payment we
  -- cannot match is still worth recording (transaction_id stays NULL) rather
  -- than dropped, so it surfaces for a human instead of vanishing.
  SELECT transaction_id INTO v_txn FROM public.topup_orders
    WHERE razorpay_payment_id = p_razorpay_payment_id;

  SELECT * INTO v_existing FROM public.disputes
    WHERE razorpay_dispute_id = p_razorpay_dispute_id FOR UPDATE;

  IF FOUND THEN
    -- Lifecycle update (created -> under review -> won/lost/closed).
    UPDATE public.disputes
       SET status = p_status,
           reason = COALESCE(p_reason, reason),
           transaction_id = COALESCE(transaction_id, v_txn),
           resolved_at = CASE WHEN p_status IN ('WON','LOST','CLOSED') THEN now() ELSE resolved_at END
     WHERE id = v_existing.id;
    RETURN jsonb_build_object('success',true,'dispute_id',v_existing.id,'updated',true);
  END IF;

  INSERT INTO public.disputes (transaction_id, razorpay_dispute_id, amount_paise, reason, status)
    VALUES (v_txn, p_razorpay_dispute_id, p_amount_paise, p_reason, p_status)
    RETURNING id INTO v_id;

  -- Chargebacks are money leaving without our initiation; make them loud.
  INSERT INTO public.notifications (recipient_id, event_type, title, message, related_entity_type, related_entity_id)
    SELECT p.id, 'PLATFORM_ANNOUNCEMENT', 'Payment dispute opened',
           'A chargeback was raised on a payment. Review it in the admin panel.', 'system', v_id
      FROM public.profiles p WHERE p.role='ADMIN' LIMIT 1;

  RETURN jsonb_build_object('success',true,'dispute_id',v_id,'created',true);
END $$;

REVOKE ALL ON FUNCTION rpc_record_dispute(text,text,bigint,text,dispute_status) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION rpc_record_dispute(text,text,bigint,text,dispute_status) TO zudue_app;

-- ── Audit log read model ────────────────────────────────────────────────
-- Resolves actor_id to a human name so the trail is readable without a join
-- per row. is_admin() in the view itself, matching the 0029 hardening pattern
-- (a view is only as restrictive as its own WHERE clause).
CREATE OR REPLACE VIEW vw_admin_audit_log AS
SELECT a.id,
       a.created_at,
       a.actor_id,
       COALESCE(p.full_name, '(deleted user)') AS actor_name,
       p.email                                  AS actor_email,
       a.actor_role,
       a.action,
       a.target_type,
       a.target_id,
       a.old_value,
       a.new_value,
       a.ip_address
  FROM public.audit_log a
  LEFT JOIN public.profiles p ON p.id = a.actor_id
 WHERE public.is_admin();

REVOKE ALL ON public.vw_admin_audit_log FROM PUBLIC;
GRANT SELECT ON public.vw_admin_audit_log TO zudue_app;

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

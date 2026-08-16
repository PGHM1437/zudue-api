-- 0070 · Abandoned top-up cleanup (M4).
--
-- ⚠️ NEEDS REVIEW BEFORE APPLYING — touches financial records, kept separate
-- from the plain schema fixes for the same reason as 0069.
--
-- Nothing currently reaps topup_orders rows stuck in PENDING (the fan opened
-- a Razorpay checkout and never completed or cancelled it). They accumulate
-- forever. This marks them FAILED via UPDATE, not DELETE — the row and its
-- audit trail (razorpay_order_id, timestamps) stay intact; only the status
-- and error_message change. A prior draft of this same fix used a hard
-- DELETE, which would destroy that trail for no benefit — rejected here on
-- purpose.
--
-- Verified against the live enum: txn_status is PENDING/SUCCESSFUL/FAILED/
-- REVERSED (checked via pg_enum, not assumed — the legacy status set had
-- extra REFUND_* values that don't exist on this enum).
--
-- 24 hours is a judgement call, not a verified business requirement —
-- Razorpay checkout sessions are typically valid for well under that, so
-- this is deliberately conservative. Adjust the interval if you know the
-- actual gateway session lifetime.
--
-- Follow-up (not part of this migration, application code): wire this RPC
-- into apps/api/src/jobs/jobs.module.ts as a new job alongside 'settle',
-- 'stalled-calls', 'expire-windows', 'purge-deletions' — it does nothing
-- until something calls it on a schedule.

BEGIN;

CREATE OR REPLACE FUNCTION public.rpc_cleanup_abandoned_topups()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE v_count int;
BEGIN
  PERFORM public.assert_system();

  UPDATE public.topup_orders
     SET status = 'FAILED',
         error_message = COALESCE(error_message, 'Abandoned: no payment confirmation within 24 hours'),
         updated_at = now()
   WHERE status = 'PENDING'
     AND created_at < now() - interval '24 hours';

  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN jsonb_build_object('success', true, 'marked_failed', v_count);
END $function$;

REVOKE ALL ON FUNCTION public.rpc_cleanup_abandoned_topups() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.rpc_cleanup_abandoned_topups() TO authenticated;

INSERT INTO _migrations (name) VALUES ('0070_abandoned_topup_cleanup.sql')
  ON CONFLICT (name) DO NOTHING;

COMMIT;

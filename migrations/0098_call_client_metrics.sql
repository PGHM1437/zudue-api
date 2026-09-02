-- 0098 · Let a call's own participants report why it went the way it did.
--
-- WHY
-- calls.metadata (jsonb, GIN-indexed) was added speculatively in 0071 and has
-- had zero readers or writers since -- the same dead-infra state
-- remaining_duration_seconds was in before 0092 dropped it. Meanwhile the
-- client already computes every signal support/ops would want when a call
-- drops (Agora connection-state transitions, up/downlink quality, heartbeat
-- failures, whether the peer ever appeared, how long join took) and throws it
-- all away at teardown. "Why did this call drop" is currently unanswerable.
--
-- WHAT
-- One thin RPC the call screen POSTs once, fire-and-forget, on its way out
-- (deadline / manual end / peer-gone / server-ended). It only writes
-- calls.metadata -- never touches status, duration, escrow, or anything the
-- settlement path reads -- so it stays out of the money RPCs entirely and a
-- failed metrics write can never affect how a call resolves.
--
--   metadata.clientMetrics.FAN     = { ...fan app's session summary,   recordedAt }
--   metadata.clientMetrics.PARTNER = { ...partner app's session summary, recordedAt }
--
-- Each party writes only its own sub-object; a re-POST from the same party
-- replaces that party's summary (same data, or a more complete one) and leaves
-- the other's untouched. No status guard: metrics arrive AT teardown, when the
-- call is already terminal.
--
-- Granted to the same roles as the other participant RPCs (rpc_call_heartbeat
-- et al.). SECURITY DEFINER + assert_caller_any so only the fan or partner on
-- THIS call can write, and only to this call's row.
--
-- Reversible: DROP FUNCTION public.rpc_record_call_metrics(uuid, jsonb);
-- the metadata column and its index are left exactly as 0071 created them.

BEGIN;

CREATE OR REPLACE FUNCTION public.rpc_record_call_metrics(p_call uuid, p_metrics jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE c public.calls; v_role text;
BEGIN
  SELECT * INTO c FROM public.calls WHERE id = p_call;
  IF NOT FOUND THEN RETURN jsonb_build_object('success', false, 'error', 'NOT_FOUND'); END IF;
  PERFORM public.assert_caller_any(c.fan_id, c.partner_id);

  IF p_metrics IS NULL OR jsonb_typeof(p_metrics) <> 'object' THEN
    RETURN jsonb_build_object('success', false, 'error', 'INVALID_METRICS');
  END IF;
  IF length(p_metrics::text) > 4000 THEN
    RETURN jsonb_build_object('success', false, 'error', 'METRICS_TOO_LARGE');
  END IF;

  v_role := upper(COALESCE(p_metrics ->> 'role', ''));
  IF v_role NOT IN ('FAN', 'PARTNER') THEN
    RETURN jsonb_build_object('success', false, 'error', 'INVALID_ROLE');
  END IF;

  UPDATE public.calls
     SET metadata = COALESCE(metadata, '{}'::jsonb)
                    || jsonb_build_object(
                         'clientMetrics',
                         COALESCE(metadata -> 'clientMetrics', '{}'::jsonb)
                           || jsonb_build_object(
                                v_role,
                                jsonb_set(p_metrics, '{recordedAt}', to_jsonb(now()))
                              )
                       ),
         updated_at = now()
   WHERE id = p_call;

  RETURN jsonb_build_object('success', true);
END $function$;

REVOKE ALL ON FUNCTION public.rpc_record_call_metrics(uuid, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.rpc_record_call_metrics(uuid, jsonb)
  TO anon, authenticated, service_role, zudue_app;

INSERT INTO _migrations (name) VALUES ('0098_call_client_metrics.sql') ON CONFLICT (name) DO NOTHING;

COMMIT;

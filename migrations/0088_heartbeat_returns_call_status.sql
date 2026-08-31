-- 0088 · rpc_call_heartbeat also returns the call's current attempt_status.
--
-- The client has no way to learn that the server ended a call. cleanup_stalled_calls()
-- marks a no-show MISSED_FAN_NO_JOIN 30s after initiate (verified firing in
-- production: "calls — missed 1/1" in the API log), the BullMQ sweep drops stale
-- calls, and rpc_complete_call auto-completes at the deadline — but every one of
-- those is a server-side write the app never sees. The call screen keeps its
-- timer running and both parties sit in a session the database closed minutes
-- ago. Legacy solved this with a Supabase realtime subscription on `calls`;
-- there is no equivalent transport here.
--
-- There is, however, already a round trip: every client heartbeats every 15s and
-- this function already returns remaining_seconds to it. Adding the status to
-- that same response turns an existing call into a state channel — worst case
-- 15s to notice, no new endpoint, no new infrastructure, and nothing extra sent
-- between beats. That is strictly cheaper than replicating `calls` to every
-- connected client the way legacy did.
--
-- Everything else is unchanged from the live definition: NOT_FOUND guard,
-- assert_caller on the actor's own id, per-actor heartbeat column, counter.

BEGIN;

CREATE OR REPLACE FUNCTION public.rpc_call_heartbeat(p_call uuid, p_actor text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $function$
DECLARE c public.calls; v_expected uuid;
BEGIN
  SELECT * INTO c FROM public.calls WHERE id=p_call;
  IF NOT FOUND THEN RETURN jsonb_build_object('success',false,'error','NOT_FOUND'); END IF;
  v_expected := CASE WHEN p_actor='FAN' THEN c.fan_id ELSE c.partner_id END;
  PERFORM public.assert_caller(v_expected);

  IF p_actor = 'FAN' THEN
    UPDATE public.calls SET fan_last_heartbeat_at=now(), heartbeat_count=heartbeat_count+1 WHERE id=p_call RETURNING * INTO c;
  ELSE
    UPDATE public.calls SET partner_last_heartbeat_at=now(), heartbeat_count=heartbeat_count+1 WHERE id=p_call RETURNING * INTO c;
  END IF;

  RETURN jsonb_build_object('success',true,
    -- New: lets the client honour a terminal status instead of running a timer
    -- of its own and racing the server's own thresholds.
    'attempt_status', c.attempt_status::text,
    'remaining_seconds', GREATEST(0, EXTRACT(epoch FROM c.deadline_at - now())::int));
END $function$;

INSERT INTO _migrations (name) VALUES ('0088_heartbeat_returns_call_status.sql')
  ON CONFLICT (name) DO NOTHING;

COMMIT;

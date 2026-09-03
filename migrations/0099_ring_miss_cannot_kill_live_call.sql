-- 0099 · A ring outcome must never terminate a call that is already live.
--
-- WHY
-- rpc_mark_call_missed accepts any of its three statuses whenever the call is
-- in ('PARTNER_INITIATED','IN_PROGRESS'). Two of those three -- MISSED_FAN_NO_JOIN
-- and MISSED_FAN_DECLINED -- are RING outcomes: they can only be produced by
-- flutter_callkit_incoming's actionCallTimeout / actionCallDecline, which fire
-- from the incoming-call UI, not from the call screen.
--
-- Nothing ended that ring when the fan joined. So the ordinary sequence
--
--   creator initiates -> fan's phone rings -> fan ignores the ring, opens the
--   app and taps Join -> call goes IN_PROGRESS -> both parties are talking ->
--   45s after the ring started, CallKit times it out -> actionCallTimeout ->
--   POST /calls/call/:id/missed { MISSED_FAN_NO_JOIN }
--
-- flipped a LIVE, working call to MISSED_FAN_NO_JOIN 45 seconds in. The call
-- screens then tore down on their next heartbeat, and the booking was recorded
-- as a fan no-show. It also loses the creator their money: a call they actually
-- delivered resolves as never-answered, so nothing settles to them.
--
-- The same thing happens on a second device: the fan answers on their phone
-- while their tablet keeps ringing, and the tablet's timeout kills the call.
--
-- FIX
-- Gate by what the status MEANS rather than by one shared state list:
--   · MISSED_FAN_NO_JOIN / MISSED_FAN_DECLINED  -> only from PARTNER_INITIATED.
--     Once the fan is in, "the fan never joined" and "the fan declined" are not
--     facts that can still become true.
--   · DROPPED_TECHNICAL_ISSUE -> still allowed from either state. That IS the
--     mid-call path (job_sweep_calls' stale-heartbeat drop, the call screen's
--     own "End call now", and the peer-gone grace timer) and must keep working
--     from IN_PROGRESS.
--
-- A refused ring outcome returns ALREADY_JOINED rather than raising: the caller
-- is a fire-and-forget native CallKit event with no UI to show an error, and
-- there is nothing wrong to report -- the ring simply lost the race to a fan
-- who was already on the call.
--
-- The API's own MISSED_STATUSES allow-list is unchanged; this is the layer that
-- has the call's state in hand.

BEGIN;

CREATE OR REPLACE FUNCTION public.rpc_mark_call_missed(p_call uuid, p_status call_status)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE c public.calls;
BEGIN
  IF p_status NOT IN ('MISSED_FAN_NO_JOIN','MISSED_FAN_DECLINED','DROPPED_TECHNICAL_ISSUE') THEN
    RETURN jsonb_build_object('success',false,'error','INVALID_STATUS'); END IF;
  SELECT * INTO c FROM public.calls WHERE id=p_call AND attempt_status IN ('PARTNER_INITIATED','IN_PROGRESS');
  IF NOT FOUND THEN RETURN jsonb_build_object('success',false,'error','NOT_ACTIVE'); END IF;
  PERFORM public.assert_caller_any(c.fan_id, c.partner_id);

  -- A ring outcome arriving for a call the fan is already on is a stale ring,
  -- not a miss. Drop it on the floor and leave the live call alone.
  IF p_status IN ('MISSED_FAN_NO_JOIN','MISSED_FAN_DECLINED')
     AND c.attempt_status = 'IN_PROGRESS' THEN
    RETURN jsonb_build_object('success',false,'error','ALREADY_JOINED');
  END IF;

  UPDATE public.calls SET attempt_status=p_status, ended_at=now(), updated_at=now() WHERE id=p_call;
  RETURN jsonb_build_object('success',true);
END $function$;

INSERT INTO _migrations (name) VALUES ('0099_ring_miss_cannot_kill_live_call.sql')
  ON CONFLICT (name) DO NOTHING;

COMMIT;

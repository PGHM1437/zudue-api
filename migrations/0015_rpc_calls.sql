-- 0015 · Call lifecycle RPCs — clean, on the strengthened calls table.
-- Deterministic deadline (no drifting countdown); first-class heartbeats;
-- retry-safe; idempotent join. Triggers (0013) handle booking sync + event log.

BEGIN;

-- Fan signals ready → promotes booking to queue tier 0.
CREATE OR REPLACE FUNCTION rpc_fan_signal_ready(p_booking uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  UPDATE public.bookings SET fan_ready_at = now(), updated_at = now()
   WHERE id = p_booking AND status = 'BOOKED';
  IF NOT FOUND THEN RETURN jsonb_build_object('success',false,'error','NOT_BOOKABLE'); END IF;
  RETURN jsonb_build_object('success',true);
END $$;

-- Partner initiates a call attempt (dedupe within 60s), creates the calls row.
CREATE OR REPLACE FUNCTION rpc_partner_initiate_call(p_booking uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE b public.bookings; v_call uuid; v_meeting text;
BEGIN
  SELECT * INTO b FROM public.bookings WHERE id = p_booking FOR UPDATE;
  IF NOT FOUND OR b.status <> 'BOOKED' THEN
    RETURN jsonb_build_object('success',false,'error','NOT_BOOKABLE'); END IF;
  -- dedupe: an active attempt started < 60s ago
  IF EXISTS (SELECT 1 FROM public.calls c WHERE c.booking_id=p_booking
       AND c.attempt_status='PARTNER_INITIATED' AND c.partner_initiated_at > now()-interval '60 seconds') THEN
    RETURN jsonb_build_object('success',false,'error','ALREADY_INITIATED'); END IF;

  v_meeting := COALESCE(b.meeting_id, 'zudue-'||gen_random_uuid()::text);
  UPDATE public.bookings SET meeting_id=v_meeting, attempts=attempts+1, updated_at=now() WHERE id=p_booking;

  INSERT INTO public.calls (booking_id, fan_id, partner_id, attempt_status, meeting_id, partner_initiated_at)
  VALUES (p_booking, b.fan_id, b.partner_id, 'PARTNER_INITIATED', v_meeting, now())
  RETURNING id INTO v_call;

  RETURN jsonb_build_object('success',true,'call_id',v_call,'meeting_id',v_meeting);
END $$;

-- Fan joins → IN_PROGRESS, set started_at + hard deadline (booked minutes). Idempotent.
CREATE OR REPLACE FUNCTION rpc_fan_join_call(p_booking uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE c public.calls; v_mins int;
BEGIN
  SELECT * INTO c FROM public.calls
    WHERE booking_id=p_booking AND attempt_status IN ('PARTNER_INITIATED','IN_PROGRESS')
    ORDER BY partner_initiated_at DESC LIMIT 1 FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('success',false,'error','NO_ACTIVE_CALL'); END IF;

  IF c.attempt_status = 'PARTNER_INITIATED' THEN
    SELECT (selected_duration::text)::int INTO v_mins FROM public.bookings WHERE id=p_booking;
    UPDATE public.calls SET attempt_status='IN_PROGRESS', fan_joined_at=now(),
      started_at=now(), deadline_at=now()+(v_mins||' minutes')::interval,
      fan_last_heartbeat_at=now(), updated_at=now()
    WHERE id=c.id;
  END IF;   -- already IN_PROGRESS → idempotent, same call/meeting

  RETURN jsonb_build_object('success',true,'call_id',c.id,'meeting_id',c.meeting_id);
END $$;

-- Heartbeat (both parties) → updates first-class column; returns remaining seconds.
CREATE OR REPLACE FUNCTION rpc_call_heartbeat(p_call uuid, p_actor text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE c public.calls;
BEGIN
  IF p_actor = 'FAN' THEN
    UPDATE public.calls SET fan_last_heartbeat_at=now(), heartbeat_count=heartbeat_count+1 WHERE id=p_call RETURNING * INTO c;
  ELSE
    UPDATE public.calls SET partner_last_heartbeat_at=now(), heartbeat_count=heartbeat_count+1 WHERE id=p_call RETURNING * INTO c;
  END IF;
  RETURN jsonb_build_object('success',true,
    'remaining_seconds', GREATEST(0, EXTRACT(epoch FROM c.deadline_at - now())::int));
END $$;

-- Complete a call (partner/fan ends, or auto at deadline). Records actual duration.
CREATE OR REPLACE FUNCTION rpc_complete_call(p_call uuid, p_auto boolean DEFAULT false)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE c public.calls;
BEGIN
  SELECT * INTO c FROM public.calls WHERE id=p_call FOR UPDATE;
  IF NOT FOUND OR c.attempt_status <> 'IN_PROGRESS' THEN
    RETURN jsonb_build_object('success',false,'error','NOT_IN_PROGRESS'); END IF;
  UPDATE public.calls SET attempt_status='COMPLETED_SUCCESSFUL', ended_at=now(),
    actual_duration_seconds = GREATEST(0, EXTRACT(epoch FROM now() - c.started_at)::int),
    termination_reason = CASE WHEN p_auto THEN 'auto_duration_complete' ELSE 'ended_by_participant' END,
    updated_at=now()
  WHERE id=p_call;   -- trigger syncs booking → COMPLETED_SUCCESSFUL + logs event
  RETURN jsonb_build_object('success',true);
END $$;

-- Mark a call missed/dropped (fan no-join, declined, technical). Retry-safe.
CREATE OR REPLACE FUNCTION rpc_mark_call_missed(p_call uuid, p_status call_status)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  IF p_status NOT IN ('MISSED_FAN_NO_JOIN','MISSED_FAN_DECLINED','DROPPED_TECHNICAL_ISSUE') THEN
    RETURN jsonb_build_object('success',false,'error','INVALID_STATUS'); END IF;
  UPDATE public.calls SET attempt_status=p_status, ended_at=now(), updated_at=now()
    WHERE id=p_call AND attempt_status IN ('PARTNER_INITIATED','IN_PROGRESS');
  IF NOT FOUND THEN RETURN jsonb_build_object('success',false,'error','NOT_ACTIVE'); END IF;
  RETURN jsonb_build_object('success',true);   -- trigger resets fan_ready
END $$;

REVOKE ALL ON FUNCTION rpc_partner_initiate_call(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION rpc_fan_join_call(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION rpc_complete_call(uuid,boolean) FROM PUBLIC;

COMMIT;

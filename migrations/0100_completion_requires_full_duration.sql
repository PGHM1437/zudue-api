-- 0100 · A call completes only when the booked duration is actually delivered.
--
-- WHY
-- 0091 introduced a partial-completion bar: a participant ending the call early
-- still resolved to COMPLETED_SUCCESSFUL if cumulative talk time cleared 75% of
-- the booked duration (or came within 30 seconds of it). 0096 kept it and made
-- it cumulative across attempts.
--
-- That bar is not the product's rule and never was. It does not appear anywhere
-- in the legacy implementation -- grepped the whole legacy tree for a 75%/0.75/
-- partial-duration threshold and there is none; legacy's client simply called
-- rpc_complete_call and the server decided on duration alone. The bar was
-- invented during the rebuild.
--
-- Its effect was to pay a creator in full for a call the fan cut short. On a
-- 15-minute booking a fan hanging up at 11:15 settled as a completed call. The
-- fan paid for 15 minutes and received 11, and the money moved anyway.
--
-- FIX
-- Completion now requires the booked time to be delivered, full stop:
--
--   complete  ==  presence confirmed  AND  (system sweep OR deadline reached)
--
-- deadline_at already carries time forward from earlier attempts (0096), so a
-- retry that runs out its shortened remainder still completes correctly -- the
-- cumulative accounting lives in the deadline, which is where it belongs,
-- rather than in a second and looser rule here.
--
-- Anything ended before the deadline is DROPPED_TECHNICAL_ISSUE. The booking
-- stays BOOKED and retryable; if it is never fulfilled,
-- process_end_of_day_expired_bookings routes it -- under 3 minutes it refunds
-- the fan, 3 minutes or more it goes to REQUIRES_ADMIN_REVIEW for a human split.
-- A partial call is now an admin decision instead of an automatic full payout.
--
-- SKEW TOLERANCE
-- A 5-second allowance sits in front of deadline_at, and it is NOT a completion
-- discount. The client ends the call when ITS countdown reaches zero; that
-- request then crosses the network, so the server's now() can land a fraction
-- before deadline_at on a call that genuinely ran its full length. Without the
-- allowance those calls would be recorded as early drops on latency alone.
-- Five seconds covers request time and cannot be gamed into meaningful unpaid
-- time on a booking whose shortest option is 60 seconds.

BEGIN;

CREATE OR REPLACE FUNCTION public.rpc_complete_call(p_call uuid, p_auto boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  c             public.calls;
  v_this_s      int;
  v_prior_s     int;
  v_total_s     int;
  v_complete    boolean;
  v_reason      text;
  v_unconfirmed boolean;
BEGIN
  SELECT * INTO c FROM public.calls WHERE id = p_call FOR UPDATE;
  IF NOT FOUND OR c.attempt_status <> 'IN_PROGRESS' THEN
    RETURN jsonb_build_object('success', false, 'error', 'NOT_IN_PROGRESS');
  END IF;

  IF p_auto THEN
    PERFORM public.assert_system();
  ELSE
    PERFORM public.assert_caller_any(c.fan_id, c.partner_id);
  END IF;

  -- Booked duration is deliberately NOT read here any more: deadline_at is the
  -- single expression of "how much time this attempt owes", carry-over included.
  v_this_s := GREATEST(0, EXTRACT(epoch FROM now()
                - COALESCE(c.started_at, c.fan_joined_at, c.partner_initiated_at))::int);
  v_prior_s := public.booking_consumed_seconds(c.booking_id, c.id);
  v_total_s := v_this_s + v_prior_s;

  -- The fan's app ran heartbeats and never once saw the creator on the channel.
  v_unconfirmed := c.partner_media_confirmed IS FALSE;

  IF v_unconfirmed THEN
    v_complete := false;
    v_reason   := 'creator_presence_unconfirmed';
  ELSIF p_auto OR now() >= (c.deadline_at - interval '5 seconds') THEN
    -- The booked time was delivered. deadline_at already nets off whatever
    -- earlier attempts of this booking consumed.
    v_complete := true;
    v_reason   := 'duration_delivered';
  ELSE
    -- Ended before the booked time was up. Never a completion, however close.
    v_complete := false;
    v_reason   := 'ended_early_by_participant';
  END IF;

  UPDATE public.calls
     SET attempt_status = CASE WHEN v_complete THEN 'COMPLETED_SUCCESSFUL'::public.call_status
                                               ELSE 'DROPPED_TECHNICAL_ISSUE'::public.call_status END,
         ended_at = CASE WHEN v_unconfirmed THEN c.started_at ELSE now() END,
         actual_duration_seconds = CASE WHEN v_unconfirmed THEN 0 ELSE v_this_s END,
         termination_reason = v_reason,
         updated_at = now()
   WHERE id = p_call;

  IF v_complete THEN
    INSERT INTO public.notifications (recipient_id, actor_id, event_type, title, message, related_entity_type, related_entity_id, metadata)
    VALUES
      (c.fan_id, c.partner_id, 'VIDEO_CALL_COMPLETED_FAN'::public.notification_event_type_enum, 'Call completed',
       'Your call has ended. We hope it was great!', 'call'::public.notification_related_entity_type_enum, c.id,
       jsonb_build_object('callId', c.id, 'bookingId', c.booking_id)),
      (c.partner_id, c.fan_id, 'VIDEO_CALL_COMPLETED_PARTNER'::public.notification_event_type_enum, 'Call completed',
       'Your call has ended. Earnings will be released after the review window.', 'call'::public.notification_related_entity_type_enum, c.id,
       jsonb_build_object('callId', c.id, 'bookingId', c.booking_id))
    ON CONFLICT (recipient_id, event_type, related_entity_type, related_entity_id) DO NOTHING;
  ELSE
    INSERT INTO public.notifications (recipient_id, actor_id, event_type, title, message, related_entity_type, related_entity_id, metadata)
    VALUES
      (c.fan_id, c.partner_id, 'VIDEO_CALL_MISSED_ATTEMPT_FAN'::public.notification_event_type_enum, 'Call ended early',
       'That call ended before the booked time. Your booking is still active — mark yourself ready to try again.',
       'call'::public.notification_related_entity_type_enum, c.id,
       jsonb_build_object('callId', c.id, 'bookingId', c.booking_id, 'durationSeconds', v_this_s))
    ON CONFLICT (recipient_id, event_type, related_entity_type, related_entity_id) DO NOTHING;
  END IF;

  RETURN jsonb_build_object('success', true, 'completed', v_complete,
    'duration_seconds', CASE WHEN v_unconfirmed THEN 0 ELSE v_this_s END,
    'booking_total_seconds', CASE WHEN v_unconfirmed THEN v_prior_s ELSE v_total_s END,
    'reason', v_reason);
END $function$;

INSERT INTO _migrations (name) VALUES ('0100_completion_requires_full_duration.sql')
  ON CONFLICT (name) DO NOTHING;

COMMIT;

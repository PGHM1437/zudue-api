-- 0091 · rpc_complete_call: don't call a 2-second call a completed call.
--
-- WHY
-- rpc_complete_call(p_auto => false) fires when a participant taps "End". It
-- flips ANY in-progress call to COMPLETED_SUCCESSFUL; trg_sync_call_to_booking
-- flips the booking; rpc_settle_booking then pays the creator in full at
-- settle_at. Duration is computed and stored, but never tested.
--
-- Live evidence: the only 4 "completed" calls in production are manual ends at
-- 2s / 8s / 10s (plus one 20.9h stuck row) — all settled to the creator. The
-- legacy build had the identical defect: 19 of its 24 "completed" calls were
-- `user_ended_call` averaging 84 seconds.
--
-- The fan has no recourse in that state. The day-of-settle sweep
-- (process_end_of_day_expired_bookings) is the thing that classifies partial
-- calls and refunds, but its loop is `WHERE b.status = 'BOOKED'` — once the
-- booking is COMPLETED_SUCCESSFUL it is excluded permanently.
--
-- WHAT
-- The manual path now decides exactly one thing: did this reach the completion
-- bar?
--   • yes → COMPLETED_SUCCESSFUL, exactly as before
--   • no  → DROPPED_TECHNICAL_ISSUE, and the booking is left BOOKED
--
-- That is the whole change. It deliberately does NOT re-implement partial-call
-- policy here: leaving the booking BOOKED hands it to the sweep that already
-- owns that policy, which reads MAX(ended_at - started_at) across attempts with
-- terminal statuses (DROPPED_TECHNICAL_ISSUE included) and applies its existing
-- rules — >= booked duration → COMPLETED; >= 180s → REQUIRES_ADMIN_REVIEW
-- (escrow held for rpc_admin_resolve_partial_call); otherwise EXPIRED_* +
-- refund. One policy, one place. A second copy here would drift.
--
-- Side effect, and it is the point: a booking whose attempt was cut short stays
-- retryable. trg_reset_fan_ready clears fan_ready_at, vw_partner_call_queue
-- keeps it for 7 days at queue_priority 3, and the creator can call again.
--
-- The completion bar is relative to booked duration (75%, or within 30s of the
-- end) rather than a flat number, so a 1-minute and a 15-minute booking are
-- judged the same way. The auto path (deadline reached) is untouched: reaching
-- deadline_at means the booked duration elapsed.

BEGIN;

CREATE OR REPLACE FUNCTION public.rpc_complete_call(p_call uuid, p_auto boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  c           public.calls;
  v_booked_s  int;
  v_elapsed_s int;
  v_complete  boolean;
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

  v_elapsed_s := GREATEST(0, EXTRACT(epoch FROM now()
                   - COALESCE(c.started_at, c.fan_joined_at, c.partner_initiated_at))::int);

  IF p_auto THEN
    v_complete := true;                       -- deadline reached
  ELSE
    SELECT (selected_duration::text)::int * 60 INTO v_booked_s
      FROM public.bookings WHERE id = c.booking_id;
    v_booked_s := COALESCE(NULLIF(v_booked_s, 0), 60);
    v_complete := v_elapsed_s >= (v_booked_s * 3 / 4)
               OR v_elapsed_s >= v_booked_s - 30;
  END IF;

  UPDATE public.calls
     SET attempt_status = CASE WHEN v_complete THEN 'COMPLETED_SUCCESSFUL'::public.call_status
                                               ELSE 'DROPPED_TECHNICAL_ISSUE'::public.call_status END,
         ended_at = now(),
         actual_duration_seconds = v_elapsed_s,
         termination_reason = CASE WHEN p_auto THEN 'auto_duration_complete'
                                   WHEN v_complete THEN 'ended_by_participant'
                                   ELSE 'ended_early_by_participant' END,
         updated_at = now()
   WHERE id = p_call;
  -- Triggers do the rest: trg_sync_call_to_booking completes the booking only
  -- on COMPLETED_SUCCESSFUL; trg_reset_fan_ready clears fan_ready_at on the
  -- drop; trg_log_call_event records either way.

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
       jsonb_build_object('callId', c.id, 'bookingId', c.booking_id, 'durationSeconds', v_elapsed_s))
    ON CONFLICT (recipient_id, event_type, related_entity_type, related_entity_id) DO NOTHING;
  END IF;

  RETURN jsonb_build_object('success', true, 'completed', v_complete, 'duration_seconds', v_elapsed_s);
END $function$;

INSERT INTO _migrations (name) VALUES ('0091_call_completion_quality_gate.sql')
  ON CONFLICT (name) DO NOTHING;

COMMIT;

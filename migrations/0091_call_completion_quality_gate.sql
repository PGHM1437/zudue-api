-- 0091 · rpc_complete_call: gate the manual-end path on real call quality.
--
-- WHY
-- rpc_complete_call(p_auto => false) fires when a participant taps "End". Today
-- it flips ANY in-progress call to COMPLETED_SUCCESSFUL, sync_call_to_booking
-- flips the booking, and it settles in full at settle_at — regardless of whether
-- the call lasted 2 seconds or whether both parties were ever present. Live
-- evidence: the only 4 "completed" calls in production are 2s / 8s / 10s manual
-- ends (plus one 20.9h stuck row), every one already paid to the partner.
--
-- WHAT
-- The auto path (p_auto => true, the deadline sweep in job_sweep_calls) is
-- unchanged — reaching deadline_at means the booked duration elapsed, which is a
-- genuine completion.
--
-- The manual path now classifies by how much of the booked time actually ran
-- and whether the PARTNER was really connected (a heartbeat from the partner —
-- fan_last_heartbeat_at is seeded at join and proves nothing):
--   • ran ~the full booked time            → COMPLETED_SUCCESSFUL (unchanged)
--   • >= 45s AND partner heartbeated (>=2   → attempt COMPLETED, booking
--     total beats)                            REQUIRES_ADMIN_REVIEW (admin
--                                             splits escrow via
--                                             rpc_admin_resolve_partial_call —
--                                             same path 0066a / 0077 use)
--   • otherwise (barely connected, or the
--     partner never really joined)          → attempt DROPPED_TECHNICAL_ISSUE,
--                                             booking stays BOOKED and retryable
--                                             (trg_reset_fan_ready clears
--                                             fan_ready_at); if no attempt ever
--                                             succeeds, the day-of-settle sweep
--                                             refunds the fan as EXPIRED_TECHNICAL_ISSUE.
--
-- Thresholds are relative to booked duration so a 1-min and a 15-min call are
-- judged fairly. 75% (or within 30s of the end) counts as done.
--
-- Notifications branch to match the real outcome. No new enum value is needed —
-- VIDEO_CALL_COMPLETED_* carries an honest "ended early, under review" message
-- for the admin-review case; the retry case tells the fan they can try again.

BEGIN;

CREATE OR REPLACE FUNCTION public.rpc_complete_call(p_call uuid, p_auto boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  c              public.calls;
  v_booked_s     int;
  v_elapsed_s    int;
  v_both_present  boolean;
  v_outcome      text;        -- 'COMPLETE' | 'REVIEW' | 'DROP'
  v_call_status  public.call_status;
  v_term         text;
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

  v_elapsed_s := GREATEST(0, EXTRACT(epoch FROM now() - COALESCE(c.started_at, c.fan_joined_at, c.partner_initiated_at))::int);

  -- ── classify ────────────────────────────────────────────────────────────
  IF p_auto THEN
    -- Deadline reached → the booked duration elapsed. Always a completion.
    v_outcome := 'COMPLETE';
  ELSE
    SELECT (selected_duration::text)::int * 60 INTO v_booked_s
      FROM public.bookings WHERE id = c.booking_id;
    v_booked_s := COALESCE(NULLIF(v_booked_s, 0), 60);
    -- "Both sides were really connected." rpc_fan_join_call SEEDS
    -- fan_last_heartbeat_at at join, so it is always non-null for an
    -- IN_PROGRESS call and proves nothing. The real signal is a heartbeat FROM
    -- THE PARTNER (never seeded — only rpc_call_heartbeat sets it) plus a
    -- non-trivial beat count (heartbeat_count is bumped by every real beat from
    -- either side, and is NOT touched by the join seed).
    v_both_present := c.partner_last_heartbeat_at IS NOT NULL
                  AND c.heartbeat_count >= 2;

    IF v_elapsed_s >= (v_booked_s * 3 / 4) OR v_elapsed_s >= v_booked_s - 30 THEN
      v_outcome := 'COMPLETE';
    ELSIF v_elapsed_s >= 45 AND v_both_present THEN
      v_outcome := 'REVIEW';
    ELSE
      v_outcome := 'DROP';
    END IF;
  END IF;

  IF v_outcome = 'DROP' THEN
    v_call_status := 'DROPPED_TECHNICAL_ISSUE';
    v_term := 'ended_early_by_participant';
  ELSE
    v_call_status := 'COMPLETED_SUCCESSFUL';
    v_term := CASE WHEN p_auto THEN 'auto_duration_complete' ELSE 'ended_by_participant' END;
  END IF;

  UPDATE public.calls
     SET attempt_status = v_call_status,
         ended_at = now(),
         actual_duration_seconds = v_elapsed_s,
         termination_reason = v_term,
         updated_at = now()
   WHERE id = p_call;
  -- trg_sync_call_to_booking has now set the booking to COMPLETED_SUCCESSFUL if
  -- v_call_status is COMPLETED_SUCCESSFUL; trg_reset_fan_ready has cleared
  -- fan_ready_at if it is DROPPED_TECHNICAL_ISSUE.

  -- ── booking status + notifications per outcome ──────────────────────────
  IF v_outcome = 'REVIEW' THEN
    -- Override the trigger's COMPLETED_SUCCESSFUL: escrow is held until an admin
    -- splits it. settle_at is left as-is (the admin path does not need it).
    UPDATE public.bookings
       SET status = 'REQUIRES_ADMIN_REVIEW', updated_at = now()
     WHERE id = c.booking_id AND status = 'COMPLETED_SUCCESSFUL';

    INSERT INTO public.notifications (recipient_id, actor_id, event_type, title, message, related_entity_type, related_entity_id, metadata)
    VALUES
      (c.fan_id, c.partner_id, 'VIDEO_CALL_COMPLETED_FAN'::public.notification_event_type_enum, 'Call ended early',
       'Your call ended before the booked time. Our team is reviewing it and will settle any refund shortly.',
       'call'::public.notification_related_entity_type_enum, c.id,
       jsonb_build_object('callId', c.id, 'bookingId', c.booking_id, 'outcome', 'under_review')),
      (c.partner_id, c.fan_id, 'VIDEO_CALL_COMPLETED_PARTNER'::public.notification_event_type_enum, 'Call ended early',
       'This call ended before the booked time. Earnings are on hold pending a quick review.',
       'call'::public.notification_related_entity_type_enum, c.id,
       jsonb_build_object('callId', c.id, 'bookingId', c.booking_id, 'outcome', 'under_review'))
    ON CONFLICT (recipient_id, event_type, related_entity_type, related_entity_id) DO NOTHING;

  ELSIF v_outcome = 'DROP' THEN
    INSERT INTO public.notifications (recipient_id, actor_id, event_type, title, message, related_entity_type, related_entity_id, metadata)
    VALUES
      (c.fan_id, c.partner_id, 'VIDEO_CALL_MISSED_ATTEMPT_FAN'::public.notification_event_type_enum, 'Call didn''t connect',
       'That call attempt didn''t go through. Your booking is still active — mark yourself ready to try again.',
       'call'::public.notification_related_entity_type_enum, c.id,
       jsonb_build_object('callId', c.id, 'bookingId', c.booking_id, 'outcome', 'retry'))
    ON CONFLICT (recipient_id, event_type, related_entity_type, related_entity_id) DO NOTHING;

  ELSE
    -- COMPLETE — unchanged copy.
    INSERT INTO public.notifications (recipient_id, actor_id, event_type, title, message, related_entity_type, related_entity_id, metadata)
    VALUES
      (c.fan_id, c.partner_id, 'VIDEO_CALL_COMPLETED_FAN'::public.notification_event_type_enum, 'Call completed',
       'Your call has ended. We hope it was great!', 'call'::public.notification_related_entity_type_enum, c.id,
       jsonb_build_object('callId', c.id, 'bookingId', c.booking_id)),
      (c.partner_id, c.fan_id, 'VIDEO_CALL_COMPLETED_PARTNER'::public.notification_event_type_enum, 'Call completed',
       'Your call has ended. Earnings will be released after the review window.', 'call'::public.notification_related_entity_type_enum, c.id,
       jsonb_build_object('callId', c.id, 'bookingId', c.booking_id))
    ON CONFLICT (recipient_id, event_type, related_entity_type, related_entity_id) DO NOTHING;
  END IF;

  RETURN jsonb_build_object('success', true, 'outcome', lower(v_outcome), 'duration_seconds', v_elapsed_s);
END $function$;

INSERT INTO _migrations (name) VALUES ('0091_call_completion_quality_gate.sql')
  ON CONFLICT (name) DO NOTHING;

COMMIT;

-- 0096 · A resumed call gets the time that's LEFT, not a fresh full duration.
--
-- WHY
-- A 15-min booking whose first attempt dropped at 5 min currently gets a fresh
-- 15-min deadline on the retry (rpc_fan_join_call: deadline_at = now() + booked
-- minutes, every attempt). The fan can end up with far more than the booked
-- time across attempts, and the countdown on the retry lies -- it shows 15:00
-- when only 10:00 is owed.
--
-- WHAT
-- One idea, applied in three places, all derived from calls.started_at /
-- calls.ended_at -- no stored countdown, no client writes, no new column
-- (remaining_duration_seconds stays dropped from 0092):
--
--   1. booking_consumed_seconds(booking) -- SUM(ended_at - started_at) over the
--      booking's prior terminal attempts. One definition, three callers.
--
--   2. rpc_fan_join_call -- the attempt's deadline is booked_seconds MINUS what
--      earlier attempts already delivered. First attempt: 0 prior -> full
--      duration, exactly as before.
--
--   3. rpc_complete_call -- the "did this reach the bar" test for an early
--      manual end now measures CUMULATIVE delivered time (this attempt + prior),
--      not just this attempt. Reaching deadline_at (auto sweep, or the client's
--      own countdown hitting zero) completes as before. The 0092 confirmed-
--      presence gate is unchanged.
--
-- process_end_of_day_expired_bookings is deliberately NOT touched. It is the
-- backstop for bookings nobody ever resolves; its MAX(ended_at - started_at)
-- "best sustained attempt" proxy stays a conservative, fan-favouring measure
-- for the abandoned case. The cumulative logic lives where a call is actively
-- completed (point 3), which is where 5+5+5-across-drops -> COMPLETED happens.
--
-- CLIENT
-- calls.module.ts join() already selects and returns deadline_at; call_screen
-- already seeds its countdown from it and ends at zero. The only client change
-- is cosmetic (show the "Call complete" card on a local-deadline end instead of
-- snapping back to the list) -- shipped separately, not required for this.
--
-- Depends on: 0090 (sweep), 0092 (partner_media_confirmed column + body this
-- rewrites). Deploy order: 0090 -> 0091 -> 0092 -> 0093 -> 0094 -> 0095 -> 0096.
--
-- 0090 is a hard prerequisite, not just ordering: booking_consumed_seconds only
-- counts attempts in a terminal status. An IN_PROGRESS attempt whose app
-- crashed contributes 0 until the 60s stale-heartbeat sweep closes it, so
-- without 0090 running a re-join would hand out more time than is owed.
--
-- Live state: bookings cleared; nothing to backfill.

BEGIN;

-- ── 1. one place computes delivered time ────────────────────────────────────
-- SECURITY DEFINER so it sees every call row regardless of caller RLS context
-- (0083 has the same note for the same reason). STABLE: same answer within a
-- statement. Only ever called from the two RPCs below -- revoked from clients.
CREATE OR REPLACE FUNCTION public.booking_consumed_seconds(
  p_booking uuid,
  p_exclude_call uuid DEFAULT NULL
)
RETURNS int
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO ''
AS $fn$
  SELECT COALESCE(
           SUM(GREATEST(0, EXTRACT(epoch FROM (ended_at - started_at))))::int,
           0)
  FROM public.calls
  WHERE booking_id = p_booking
    AND (p_exclude_call IS NULL OR id <> p_exclude_call)
    AND started_at IS NOT NULL
    AND ended_at   IS NOT NULL
    AND attempt_status IN ('COMPLETED_SUCCESSFUL', 'DROPPED_TECHNICAL_ISSUE');
$fn$;

REVOKE ALL ON FUNCTION public.booking_consumed_seconds(uuid, uuid)
  FROM PUBLIC, anon, authenticated;

COMMENT ON FUNCTION public.booking_consumed_seconds(uuid, uuid) IS
  'Seconds of video actually delivered across a booking''s prior terminal call '
  'attempts (COMPLETED_SUCCESSFUL + DROPPED_TECHNICAL_ISSUE, both of which have '
  'started_at and ended_at set). MISSED_* attempts never started, so contribute '
  'nothing. Used to carry remaining time across a resumed call.';

-- ── 2. rpc_fan_join_call: carry-over deadline ───────────────────────────────
-- Body is the live 0023 version; the only change is v_mins (full booked
-- minutes) -> v_remaining_s (booked minus already delivered), and returning
-- deadline_at so join() can skip its follow-up SELECT.
CREATE OR REPLACE FUNCTION public.rpc_fan_join_call(p_booking uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $fn$
DECLARE
  c             public.calls;
  v_booked_s    int;
  v_remaining_s int;
BEGIN
  SELECT * INTO c FROM public.calls
    WHERE booking_id = p_booking
      AND attempt_status IN ('PARTNER_INITIATED', 'IN_PROGRESS')
    ORDER BY partner_initiated_at DESC
    LIMIT 1
    FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'NO_ACTIVE_CALL');
  END IF;
  PERFORM public.assert_caller(c.fan_id);

  IF c.attempt_status = 'PARTNER_INITIATED' THEN
    SELECT (selected_duration::text)::int * 60 INTO v_booked_s
      FROM public.bookings WHERE id = p_booking;
    v_booked_s := COALESCE(NULLIF(v_booked_s, 0), 60);

    -- Cap this attempt at the booked time minus what earlier attempts of the
    -- same booking already delivered. First attempt: consumed is 0 -> full
    -- duration, identical to the previous behaviour. GREATEST(0, ...) only
    -- guards against a negative interval literal; a fully-delivered booking is
    -- already terminal (rpc_complete_call's cumulative bar) so it can't be
    -- BOOKED-and-ringing here in practice.
    v_remaining_s := GREATEST(0, v_booked_s
                       - public.booking_consumed_seconds(p_booking, c.id));

    UPDATE public.calls
       SET attempt_status        = 'IN_PROGRESS',
           fan_joined_at         = now(),
           started_at            = now(),
           deadline_at           = now() + (v_remaining_s || ' seconds')::interval,
           fan_last_heartbeat_at = now(),
           updated_at            = now()
     WHERE id = c.id
     RETURNING * INTO c;
  END IF;

  RETURN jsonb_build_object('success', true,
    'call_id', c.id,
    'meeting_id', c.meeting_id,
    'deadline_at', c.deadline_at);
END $fn$;

-- ── 3. rpc_complete_call: cumulative bar for an early manual end ─────────────
-- Full body = 0092 (confirmed-presence gate + notifications, verbatim) with the
-- one change: the manual-path completion test measures this attempt PLUS prior
-- attempts against the booked duration, so a resumed call that runs its
-- shortened deadline out still completes. Auto path and presence gate unchanged.
CREATE OR REPLACE FUNCTION public.rpc_complete_call(p_call uuid, p_auto boolean DEFAULT false)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $fn$
DECLARE
  c             public.calls;
  v_booked_s    int;
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

  SELECT (selected_duration::text)::int * 60 INTO v_booked_s
    FROM public.bookings WHERE id = c.booking_id;
  v_booked_s := COALESCE(NULLIF(v_booked_s, 0), 60);

  -- this attempt's own elapsed time
  v_this_s := GREATEST(0, EXTRACT(epoch FROM now()
                - COALESCE(c.started_at, c.fan_joined_at, c.partner_initiated_at))::int);
  -- everything earlier attempts of this booking delivered, and the two combined
  v_prior_s := public.booking_consumed_seconds(c.booking_id, c.id);
  v_total_s := v_this_s + v_prior_s;

  -- The fan's app ran heartbeats and never once saw the creator on the channel.
  v_unconfirmed := c.partner_media_confirmed IS FALSE;

  IF v_unconfirmed THEN
    -- Not a completion, whatever the clock says. Record zero duration so
    -- process_end_of_day_expired_bookings classifies it as a technical expiry
    -- and refunds the fan.
    v_complete := false;
    v_reason   := 'creator_presence_unconfirmed';
  ELSIF p_auto OR now() >= c.deadline_at THEN
    -- Deadline reached -- auto sweep, or the client's countdown hit zero and
    -- called this directly. The booked time (carry-over included) is delivered.
    v_complete := true;
    v_reason   := 'auto_duration_complete';
  ELSE
    -- Ended early by a participant: complete only if cumulative delivery across
    -- all attempts cleared the bar.
    v_complete := v_total_s >= (v_booked_s * 3 / 4)
               OR v_total_s >= v_booked_s - 30;
    v_reason := CASE WHEN v_complete THEN 'ended_by_participant' ELSE 'ended_early_by_participant' END;
  END IF;

  UPDATE public.calls
     SET attempt_status = CASE WHEN v_complete THEN 'COMPLETED_SUCCESSFUL'::public.call_status
                                               ELSE 'DROPPED_TECHNICAL_ISSUE'::public.call_status END,
         ended_at = CASE WHEN v_unconfirmed THEN c.started_at ELSE now() END,
         actual_duration_seconds = CASE WHEN v_unconfirmed THEN 0 ELSE v_this_s END,
         termination_reason = v_reason,
         updated_at = now()
   WHERE id = p_call;
  -- Triggers do the rest: trg_sync_call_to_booking completes the booking only on
  -- COMPLETED_SUCCESSFUL; trg_reset_fan_ready clears fan_ready_at on the drop;
  -- trg_log_call_event records either way. A DROPPED booking stays BOOKED and is
  -- handed to process_end_of_day_expired_bookings.

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
END $fn$;

INSERT INTO _migrations (name) VALUES ('0096_call_time_carryover.sql')
  ON CONFLICT (name) DO NOTHING;

COMMIT;

-- 0092 · Confirmed-presence gate on rpc_complete_call.
--
-- WHY
-- rpc_complete_call(p_auto => true) fires at the deadline and pays the creator
-- in full. Nothing checks the creator was ever actually on the video channel:
-- a creator who taps "start" and never connects still gets paid when the call
-- sits IN_PROGRESS to the deadline (their app keeps sending PARTNER heartbeats
-- even with no media flowing). 0091's two-outcome rewrite did not close this.
--
-- WHAT
-- The fan's app is the authority on "was the creator on the channel" -- it
-- either sees the creator's video or it does not, and a modified creator app
-- cannot forge the fan's phone. The fan app reports this one bit on the
-- heartbeat it already sends every 60s. rpc_complete_call refuses to mark a
-- call COMPLETED when the fan's app ran at least one heartbeat and never once
-- confirmed the creator present.
--
-- "Did the call happen, for how long" now rests on three provider-neutral
-- layers -- none of which asks the media provider (Agora) anything:
--   1. the deterministic deadline (0091, server-owned);
--   2. this one confirmed-present bit, carried on the heartbeat;
--   3. the 60s stale-heartbeat sweep (0090) as the crash backstop.
--
-- FAIL-SOFT: partner_media_confirmed IS NULL (an app that never sends the bit)
-- -> exact 0091 behaviour. Only an explicit FALSE blocks completion.
--
-- Depends on: 0091 (rpc_complete_call two-outcome gate).
-- Deploy order: 0090 -> 0091 -> 0092.

BEGIN;

-- ── 1. one nullable bit on calls ──────────────────────────────────────────
ALTER TABLE public.calls
  ADD COLUMN IF NOT EXISTS partner_media_confirmed boolean;

COMMENT ON COLUMN public.calls.partner_media_confirmed IS
  'Set by rpc_call_heartbeat from the fan app''s peer_present flag: true once '
  'the fan''s device has seen the creator on the video channel, sticky. NULL '
  'until the fan app reports it at all. rpc_complete_call will not mark a call '
  'COMPLETED when this is explicitly FALSE.';

-- Dead legacy column (a leftover from the old schema, referenced by nothing).
ALTER TABLE public.calls DROP COLUMN IF EXISTS remaining_duration_seconds;

-- ── 2. rpc_call_heartbeat: carry the one bit ──────────────────────────────
-- Adding a parameter is a new signature (an overload) -- drop + recreate so
-- there is exactly one rpc_call_heartbeat (db-doctor RPC_OVERLOAD stays green).
-- Body is the live 0088 version plus the partner_media_confirmed update.
DROP FUNCTION IF EXISTS public.rpc_call_heartbeat(uuid, text);

CREATE FUNCTION public.rpc_call_heartbeat(p_call uuid, p_actor text, p_peer_present boolean DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $fn$
DECLARE c public.calls; v_expected uuid;
BEGIN
  SELECT * INTO c FROM public.calls WHERE id = p_call;
  IF NOT FOUND THEN RETURN jsonb_build_object('success', false, 'error', 'NOT_FOUND'); END IF;
  v_expected := CASE WHEN p_actor = 'FAN' THEN c.fan_id ELSE c.partner_id END;
  PERFORM public.assert_caller(v_expected);

  IF p_actor = 'FAN' THEN
    UPDATE public.calls
       SET fan_last_heartbeat_at = now(),
           heartbeat_count = heartbeat_count + 1,
           -- sticky: once true, stays true. A first FALSE seeds the column so
           -- rpc_complete_call can tell "reported, never seen" from "not reported".
           partner_media_confirmed = CASE
             WHEN p_peer_present IS NULL THEN partner_media_confirmed
             ELSE COALESCE(partner_media_confirmed, false) OR p_peer_present
           END
     WHERE id = p_call RETURNING * INTO c;
  ELSE
    UPDATE public.calls
       SET partner_last_heartbeat_at = now(),
           heartbeat_count = heartbeat_count + 1
     WHERE id = p_call RETURNING * INTO c;
  END IF;

  RETURN jsonb_build_object('success', true,
    'attempt_status', c.attempt_status::text,
    'remaining_seconds', GREATEST(0, EXTRACT(epoch FROM c.deadline_at - now())::int));
END $fn$;
-- Supabase ALTER DEFAULT PRIVILEGES re-grants EXECUTE to anon/authenticated/
-- service_role/zudue_app on CREATE; rpc_call_heartbeat was never REVOKEd from
-- PUBLIC, so the grant set is unchanged. No explicit GRANT needed.

-- ── 3. rpc_complete_call: 0091 body + the confirmed-presence gate ──────────
-- Full CREATE OR REPLACE so this is correct whether or not 0091 ran first (the
-- migrate runner applies files in order, so 0092 lands last and wins). The only
-- change vs 0091 is the first branch of the v_complete decision and the
-- ended_at / actual_duration_seconds written for that case; the notification
-- blocks are 0091's verbatim.
CREATE OR REPLACE FUNCTION public.rpc_complete_call(p_call uuid, p_auto boolean DEFAULT false)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $fn$
DECLARE
  c             public.calls;
  v_booked_s    int;
  v_elapsed_s   int;
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

  v_elapsed_s := GREATEST(0, EXTRACT(epoch FROM now()
                   - COALESCE(c.started_at, c.fan_joined_at, c.partner_initiated_at))::int);

  -- The fan's app ran heartbeats and never once saw the creator on the channel.
  v_unconfirmed := c.partner_media_confirmed IS FALSE;

  IF v_unconfirmed THEN
    -- Not a completion, whatever the clock says. Record zero duration so
    -- process_end_of_day_expired_bookings classifies it as a technical expiry
    -- and refunds the fan -- no change needed to that function.
    v_complete := false;
    v_reason   := 'creator_presence_unconfirmed';
  ELSIF p_auto THEN
    v_complete := true;                       -- deadline reached
    v_reason   := 'auto_duration_complete';
  ELSE
    v_complete := v_elapsed_s >= (v_booked_s * 3 / 4)
               OR v_elapsed_s >= v_booked_s - 30;
    v_reason := CASE WHEN v_complete THEN 'ended_by_participant' ELSE 'ended_early_by_participant' END;
  END IF;

  UPDATE public.calls
     SET attempt_status = CASE WHEN v_complete THEN 'COMPLETED_SUCCESSFUL'::public.call_status
                                               ELSE 'DROPPED_TECHNICAL_ISSUE'::public.call_status END,
         ended_at = CASE WHEN v_unconfirmed THEN c.started_at ELSE now() END,
         actual_duration_seconds = CASE WHEN v_unconfirmed THEN 0 ELSE v_elapsed_s END,
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
       jsonb_build_object('callId', c.id, 'bookingId', c.booking_id, 'durationSeconds', v_elapsed_s))
    ON CONFLICT (recipient_id, event_type, related_entity_type, related_entity_id) DO NOTHING;
  END IF;

  RETURN jsonb_build_object('success', true, 'completed', v_complete,
    'duration_seconds', CASE WHEN v_unconfirmed THEN 0 ELSE v_elapsed_s END,
    'reason', v_reason);
END $fn$;

INSERT INTO _migrations (name) VALUES ('0092_confirmed_presence_completion_gate.sql')
  ON CONFLICT (name) DO NOTHING;

COMMIT;

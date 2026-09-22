-- 0101 · Attribute a manual call end to the participant who triggered it.
--
-- WHY
-- Neither rpc_complete_call nor rpc_mark_call_missed ever recorded WHICH party
-- (fan or partner) tapped End / reported an issue on a call that had already
-- gone IN_PROGRESS — completion was anonymous and symmetric: same DB effect,
-- same notification text, regardless of who acted. The remaining participant
-- had no way to tell "the other person ended this" from "the call simply
-- completed" — both rendered the same generic "Call ended" card — and there
-- was nothing in the database a later investigation could read to say who
-- ended a given attempt early.
--
-- assert_caller_any(fan_id, partner_id) already resolves current_user_id()
-- against both parties before either RPC proceeds; it just never kept the
-- result. This migration captures it.
--
-- FIX
-- calls.ended_by / ended_by_role are stamped only for a genuinely
-- participant-triggered end:
--   · rpc_complete_call: only when p_auto = false (a real client call, not the
--     pg_cron sweep) AND the outcome is 'ended_early_by_participant' — i.e.
--     the call was live and someone left before the booked time. A deadline
--     completion (v_reason = 'duration_delivered') is not "ended by" anyone;
--     both parties trigger that same finalize call once the timer runs out,
--     so it stays unattributed even though it is technically p_auto = false.
--   · rpc_mark_call_missed: only when the resulting status is
--     DROPPED_TECHNICAL_ISSUE on a call that was already IN_PROGRESS — the
--     "report a technical issue" self-report on a live call. A still-RINGING
--     call resolving to MISSED_FAN_NO_JOIN / MISSED_FAN_DECLINED is
--     deliberately left unattributed: that is a pre-acceptance ring outcome,
--     not a manual drop of an accepted call.
-- Both RPCs now also persist a notification for the OTHER party (previously
-- rpc_complete_call's early-drop branch notified only the fan; the partner got
-- nothing persisted) and word it by role, and return ended_by_role so the
-- calling TS layer and the live heartbeat/push path can surface it without a
-- second query. rpc_call_heartbeat returns it too — the 60s heartbeat is the
-- backstop path when the push notification is delayed or dropped.

BEGIN;

ALTER TABLE public.calls
  ADD COLUMN IF NOT EXISTS ended_by uuid REFERENCES public.profiles(id),
  ADD COLUMN IF NOT EXISTS ended_by_role public.user_role;

-- ── rpc_complete_call ────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.rpc_complete_call(p_call uuid, p_auto boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  c              public.calls;
  v_this_s       int;
  v_prior_s      int;
  v_total_s      int;
  v_complete     boolean;
  v_reason       text;
  v_unconfirmed  boolean;
  v_ended_by     uuid;
  v_ended_by_role public.user_role;
BEGIN
  SELECT * INTO c FROM public.calls WHERE id = p_call FOR UPDATE;
  IF NOT FOUND OR c.attempt_status <> 'IN_PROGRESS' THEN
    RETURN jsonb_build_object('success', false, 'error', 'NOT_IN_PROGRESS');
  END IF;

  IF p_auto THEN
    PERFORM public.assert_system();
  ELSE
    PERFORM public.assert_caller_any(c.fan_id, c.partner_id);
    v_ended_by := public.current_user_id();
    v_ended_by_role := CASE WHEN v_ended_by = c.fan_id THEN 'FAN'::public.user_role
                             WHEN v_ended_by = c.partner_id THEN 'PARTNER'::public.user_role
                             ELSE NULL END;
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
    -- earlier attempts of this booking consumed. Not "ended by" anyone —
    -- both parties independently trigger this same finalize call once their
    -- own local timer reaches zero, so no attribution is recorded here even
    -- though the call itself was p_auto = false.
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
         ended_by = CASE WHEN v_reason = 'ended_early_by_participant' THEN v_ended_by ELSE c.ended_by END,
         ended_by_role = CASE WHEN v_reason = 'ended_early_by_participant' THEN v_ended_by_role ELSE c.ended_by_role END,
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
  ELSIF v_reason = 'ended_early_by_participant' AND v_ended_by_role IS NOT NULL THEN
    -- A specific party manually ended a live call. Tell BOTH — previously only
    -- the fan got a persisted row here, regardless of which of them left; the
    -- partner got nothing. Each sees the plain fact, worded for who did what.
    INSERT INTO public.notifications (recipient_id, actor_id, event_type, title, message, related_entity_type, related_entity_id, metadata)
    VALUES
      (c.fan_id, v_ended_by, 'VIDEO_CALL_MISSED_ATTEMPT_FAN'::public.notification_event_type_enum, 'Call ended early',
       CASE WHEN v_ended_by_role = 'FAN' THEN 'You ended the call early. Your booking is still active — mark yourself ready to try again.'
            ELSE 'The creator ended the call early. Your booking is still active — mark yourself ready to try again.' END,
       'call'::public.notification_related_entity_type_enum, c.id,
       jsonb_build_object('callId', c.id, 'bookingId', c.booking_id, 'durationSeconds', v_this_s, 'endedByRole', v_ended_by_role)),
      (c.partner_id, v_ended_by, 'VIDEO_CALL_COMPLETED_PARTNER'::public.notification_event_type_enum, 'Call ended early',
       CASE WHEN v_ended_by_role = 'PARTNER' THEN 'You ended the call early.'
            ELSE 'The fan ended the call early.' END,
       'call'::public.notification_related_entity_type_enum, c.id,
       jsonb_build_object('callId', c.id, 'bookingId', c.booking_id, 'durationSeconds', v_this_s, 'endedByRole', v_ended_by_role))
    ON CONFLICT (recipient_id, event_type, related_entity_type, related_entity_id) DO NOTHING;
  ELSE
    -- creator_presence_unconfirmed, or an unattributed early drop (p_auto sweep
    -- catching a stale IN_PROGRESS call) — unchanged from before this migration.
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
    'reason', v_reason,
    'ended_by_role', v_ended_by_role);
END $function$;

-- ── rpc_mark_call_missed ─────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.rpc_mark_call_missed(p_call uuid, p_status call_status)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  c               public.calls;
  v_ended_by      uuid;
  v_ended_by_role public.user_role;
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

  -- Attribute only a manual technical-issue report on a call that had already
  -- gone live — this is the self-report path from a real participant (or an
  -- admin recovering it), not a still-ringing MISSED_FAN_* outcome, which is a
  -- pre-acceptance event and stays unattributed.
  IF p_status = 'DROPPED_TECHNICAL_ISSUE' AND c.attempt_status = 'IN_PROGRESS' THEN
    v_ended_by := public.current_user_id();
    v_ended_by_role := CASE WHEN v_ended_by = c.fan_id THEN 'FAN'::public.user_role
                             WHEN v_ended_by = c.partner_id THEN 'PARTNER'::public.user_role
                             ELSE 'ADMIN'::public.user_role END;
  END IF;

  UPDATE public.calls
     SET attempt_status = p_status, ended_at = now(), updated_at = now(),
         ended_by = COALESCE(v_ended_by, c.ended_by),
         ended_by_role = COALESCE(v_ended_by_role, c.ended_by_role)
   WHERE id = p_call;

  RETURN jsonb_build_object('success', true, 'ended_by_role', v_ended_by_role);
END $function$;

-- ── rpc_call_heartbeat ───────────────────────────────────────────────────────
-- Adds ended_by_role to the response so the 60s heartbeat backstop (used when
-- the call_ended push is delayed or dropped) can surface who ended a call it
-- discovers is already terminal, same as the push path does.
CREATE OR REPLACE FUNCTION public.rpc_call_heartbeat(p_call uuid, p_actor text, p_peer_present boolean DEFAULT NULL::boolean)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
    'remaining_seconds', GREATEST(0, EXTRACT(epoch FROM c.deadline_at - now())::int),
    'ended_by_role', c.ended_by_role);
END $function$;

INSERT INTO _migrations (name) VALUES ('0101_call_manual_end_attribution.sql') ON CONFLICT (name) DO NOTHING;

COMMIT;

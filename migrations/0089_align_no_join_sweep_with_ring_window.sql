-- 0089 · Raise the fan-no-join sweep threshold from 30s to 60s.
--
-- The device rings for 45 seconds (CallKit `duration: 45000` in push_service.dart),
-- but cleanup_stalled_calls() writes the attempt off as MISSED_FAN_NO_JOIN once
-- partner_initiated_at is 30 seconds old. The sweep runs every minute, so it can
-- land at any point in that window — including while the fan's phone is still
-- ringing with 10+ seconds left to answer.
--
-- When it does, the fan answering is met with an error rather than a call:
-- rpc_fan_join_call only matches attempt_status IN ('PARTNER_INITIATED','IN_PROGRESS'),
-- so a swept call returns NO_ACTIVE_CALL. The fan did nothing wrong and gets
-- recorded as a no-show.
--
-- The client is the better authority here — it knows whether the ring was
-- actually presented and dismissed, and CallKit's own timeout already reports
-- MISSED_FAN_NO_JOIN on expiry. The sweep's job is the case the client can't
-- report: device off, app killed, push never delivered. Moving the threshold
-- past the ring window makes it a backstop instead of a competitor.
--
-- 60s also lines up with a constant already in the schema: rpc_partner_initiate_call
-- refuses a re-initiate while partner_initiated_at is under 60 seconds old. With
-- both at 60s, the moment a partner may retry is the moment the previous attempt
-- is guaranteed resolved — no window where the old call is still PARTNER_INITIATED
-- but the partner is allowed to start a new one.
--
-- Everything else in the function is unchanged: same assert_system() guard, same
-- single-phase sweep, same return shape.

BEGIN;

CREATE OR REPLACE FUNCTION public.cleanup_stalled_calls()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_updated int := 0;
  v_failed int := 0;
BEGIN
  -- Only the job scheduler can sweep calls.
  PERFORM public.assert_system();

  -- PARTNER_INITIATED calls where the fan never joined within the ring window.
  -- This is the ONLY sweeper in this function — the other sweepers (duration
  -- complete, heartbeat loss) are already in the BullMQ job via RPC calls.
  --
  -- NOTE: We update directly instead of calling rpc_mark_call_missed because
  -- that RPC has assert_caller_any(fan_id, partner_id) which doesn't allow
  -- system/admin roles. The sweeper needs system-level access.
  --
  -- trg_reset_fan_ready fires on this UPDATE and clears bookings.fan_ready_at,
  -- so the booking correctly leaves the top of the partner's queue.
  BEGIN
    UPDATE public.calls
    SET
      attempt_status = 'MISSED_FAN_NO_JOIN',
      ended_at = now(),
      updated_at = now()
    WHERE attempt_status = 'PARTNER_INITIATED'
      AND partner_initiated_at < now() - INTERVAL '60 seconds'
      AND fan_joined_at IS NULL;

    GET DIAGNOSTICS v_updated = ROW_COUNT;

  EXCEPTION WHEN OTHERS THEN
    v_failed := 1;
    RAISE WARNING 'cleanup-stalled-calls batch failed: %', SQLERRM;
  END;

  RETURN jsonb_build_object(
    'success', true,
    'missed_fan_no_join', v_updated,
    'failed', v_failed
  );
END $function$;

INSERT INTO _migrations (name) VALUES ('0089_align_no_join_sweep_with_ring_window.sql')
  ON CONFLICT (name) DO NOTHING;

COMMIT;

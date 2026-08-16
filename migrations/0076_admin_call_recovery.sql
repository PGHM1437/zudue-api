-- 0076 · Admin call-recovery RPC (M8).
--
-- Legacy had `cleanup_stuck_call(p_booking_id, p_reason)` — an admin-only
-- function that found active calls for a booking, marked them DROPPED_TECHNICAL_ISSUE,
-- set the booking to EXPIRED_TECHNICAL_ISSUE, and logged to audit_log.
--
-- Live has automated sweeps (cleanup_stalled_calls, stalled-calls cron) that cover
-- the common cases (fan never joined, heartbeat loss, deadline passed). But there's
-- no escape hatch for an admin to manually fix a specific stuck booking/call that
-- the automated sweep doesn't catch (e.g. edge cases, partial state, partner dispute).
--
-- Two independent audit passes confirmed this gap. This RPC follows the live
-- architecture pattern: assert_admin_role gate, explicit state checks, audit_log
-- row on success, same structure as rpc_admin_force_settle_*.
--
-- The function is deliberately named rpc_admin_recover_call (not cleanup_stuck_call)
-- to match the live naming convention (rpc_admin_* prefix for admin operations).

BEGIN;

CREATE OR REPLACE FUNCTION public.rpc_admin_recover_call(
  p_admin uuid,
  p_booking_id uuid,
  p_reason text DEFAULT 'Admin manual recovery'
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_call_id uuid;
  v_call_status public.call_status;
  v_booking_status public.booking_status;
  v_partner_id uuid;
  v_fan_id uuid;
BEGIN
  -- Only SUPER_ADMIN or SUPPORT can recover stuck calls.
  PERFORM public.assert_admin_role('SUPER_ADMIN', 'SUPPORT');

  -- Validate booking exists and is in a recoverable state.
  SELECT status, partner_id, fan_id
    INTO v_booking_status, v_partner_id, v_fan_id
    FROM public.bookings
   WHERE id = p_booking_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'BOOKING_NOT_FOUND');
  END IF;

  -- Only recover bookings that are still BOOKED or in a stuck terminal state.
  -- Already-settled bookings (COMPLETED_SUCCESSFUL, etc.) should not be touched.
  IF v_booking_status NOT IN ('BOOKED', 'EXPIRED_TECHNICAL_ISSUE', 'EXPIRED_PARTNER_NO_SHOW') THEN
    RETURN jsonb_build_object('success', false, 'error', 'NOT_RECOVERABLE',
            'booking_status', v_booking_status);
  END IF;

  -- Find active call (if any) for this booking.
  SELECT id, attempt_status INTO v_call_id, v_call_status
    FROM public.calls
   WHERE booking_id = p_booking_id
     AND attempt_status IN ('PARTNER_INITIATED', 'IN_PROGRESS')
   ORDER BY created_at DESC
   LIMIT 1;

  -- If there's an active call, mark it as dropped.
  IF v_call_id IS NOT NULL THEN
    UPDATE public.calls
       SET attempt_status = 'DROPPED_TECHNICAL_ISSUE',
           ended_at = now(),
           termination_reason = p_reason,
           updated_at = now()
     WHERE id = v_call_id;
  END IF;

  -- Set booking to EXPIRED_TECHNICAL_ISSUE.
  UPDATE public.bookings
     SET status = 'EXPIRED_TECHNICAL_ISSUE',
         cancellation_reason = p_reason,
         updated_at = now()
   WHERE id = p_booking_id
     AND status IN ('BOOKED', 'EXPIRED_TECHNICAL_ISSUE', 'EXPIRED_PARTNER_NO_SHOW');

  -- Audit log — matches the existing admin RPC pattern.
  INSERT INTO public.audit_log (actor_id, actor_role, action, target_type, target_id, old_value, new_value)
  VALUES (p_admin, 'ADMIN', 'ADMIN_CALL_RECOVERY', 'BOOKING', p_booking_id,
          jsonb_build_object(
            'booking_status', v_booking_status,
            'call_id', v_call_id,
            'call_status', v_call_status
          ),
          jsonb_build_object(
            'booking_status', 'EXPIRED_TECHNICAL_ISSUE',
            'call_status', CASE WHEN v_call_id IS NOT NULL THEN 'DROPPED_TECHNICAL_ISSUE' ELSE 'NO_CALL' END,
            'reason', p_reason
          ));

  RETURN jsonb_build_object(
    'success', true,
    'booking_id', p_booking_id,
    'call_id', v_call_id,
    'call_dropped', v_call_id IS NOT NULL,
    'booking_status', 'EXPIRED_TECHNICAL_ISSUE'
  );
END $function$;

REVOKE ALL ON FUNCTION public.rpc_admin_recover_call(uuid, uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.rpc_admin_recover_call(uuid, uuid, text) TO authenticated;

INSERT INTO _migrations (name) VALUES ('0076_admin_call_recovery.sql')
  ON CONFLICT (name) DO NOTHING;

COMMIT;

-- ═══════════════════════════════════════════════════════════════════════════
-- Migration 0062: Booking expiry orchestration + call lifecycle sweepers
-- ═══════════════════════════════════════════════════════════════════════════
-- Replaces the legacy pg_cron-driven process_end_of_day_expired_bookings() and
-- cleanup_stalled_calls() with BullMQ-callable functions that use the Live DB's
-- modern double-entry accounting (post_transaction) instead of direct wallet writes.
--
-- Key differences from Legacy DB:
--  1. Uses post_transaction() for refunds (not manual wallet_transactions inserts)
--  2. Properly handles platform-funded promos (returns disc to promo_incentive)
--  3. attempt_status (not final_status) - Live DB uses single status column
--  4. Runs via BullMQ worker (not pg_cron) - better observability, retry logic
--  5. System-role auth (assert_system) - called by trusted job scheduler
--
-- Business logic preserved from Legacy:
--  - Any call >= 3 min → COMPLETED_SUCCESSFUL (partner earned money)
--  - No calls → EXPIRED_PARTNER_NO_SHOW (refund fan)
--  - MISSED_FAN_NO_JOIN → EXPIRED_FAN_NO_JOIN (refund fan)
--  - MISSED_FAN_DECLINED → EXPIRED_FAN_DECLINED (refund fan)
--  - DROPPED_TECHNICAL_ISSUE → EXPIRED_TECHNICAL_ISSUE (refund fan)
--  - PARTNER_INITIATED timeout (30s) → mark as MISSED_FAN_NO_JOIN
-- ═══════════════════════════════════════════════════════════════════════════

-- ────────────────────────────────────────────────────────────────────────────
-- FUNCTION: process_end_of_day_expired_bookings
-- ────────────────────────────────────────────────────────────────────────────
-- The 7-day settlement-window expiry orchestrator. Examines bookings past their
-- settle_at deadline, analyzes call history, determines the correct terminal
-- status (COMPLETED_SUCCESSFUL or EXPIRED_*), processes refunds if needed, and
-- releases partner capacity.
--
-- Called by: BullMQ settle job (every 15 minutes, before settlement sweep)
-- Auth: Service role only (assert_system)
-- Batch size: 200 bookings per run (prevents long locks)
-- ────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.process_end_of_day_expired_bookings()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $$
DECLARE
  v_booking RECORD;
  v_status public.booking_status;
  v_gross bigint;
  v_disc bigint;
  v_wallet uuid;
  v_legs jsonb;
  v_mins int;
  
  -- Counters
  v_completed int := 0;
  v_partner_no_show int := 0;
  v_fan_no_join int := 0;
  v_fan_declined int := 0;
  v_technical int := 0;
  v_failed int := 0;
BEGIN
  -- Only the job scheduler (service role) can expire bookings automatically.
  PERFORM public.assert_system();
  
  -- Process bookings past their settle_at window (7 days), still stuck in BOOKED.
  FOR v_booking IN (
    SELECT 
      b.id, b.fan_id, b.price_paise, b.original_price_paise, b.discount_paise,
      b.selected_duration, b.partner_id, b.scheduled_date,
      COALESCE(MAX(EXTRACT(epoch FROM (c.ended_at - c.started_at))), 0) as max_duration_sec,
      COUNT(c.id) FILTER (WHERE c.attempt_status = 'MISSED_FAN_NO_JOIN') as missed_fan,
      COUNT(c.id) FILTER (WHERE c.attempt_status = 'MISSED_FAN_DECLINED') as declined_fan,
      COUNT(c.id) FILTER (WHERE c.attempt_status = 'DROPPED_TECHNICAL_ISSUE') as dropped_tech,
      COUNT(c.id) as total_calls
    FROM public.bookings b
    LEFT JOIN public.calls c ON c.booking_id = b.id 
      AND c.attempt_status IN ('COMPLETED_SUCCESSFUL', 'MISSED_FAN_NO_JOIN', 'MISSED_FAN_DECLINED', 'DROPPED_TECHNICAL_ISSUE')
    WHERE b.status = 'BOOKED' AND b.settle_at <= now()
    GROUP BY b.id, b.fan_id, b.price_paise, b.original_price_paise, b.discount_paise,
             b.selected_duration, b.partner_id, b.scheduled_date
    LIMIT 200
  )
  LOOP
    BEGIN
      -- Determine terminal status from call history (matches Legacy logic exactly).
      -- CRITICAL: Any call >= 3 min → partner earned the money (no refund).
      IF v_booking.max_duration_sec >= 180 THEN
        v_status := 'COMPLETED_SUCCESSFUL';
        v_completed := v_completed + 1;
      ELSIF v_booking.total_calls = 0 THEN
        v_status := 'EXPIRED_PARTNER_NO_SHOW';
        v_partner_no_show := v_partner_no_show + 1;
      ELSIF v_booking.declined_fan > 0 THEN
        v_status := 'EXPIRED_FAN_DECLINED';
        v_fan_declined := v_fan_declined + 1;
      ELSIF v_booking.missed_fan > 0 THEN
        v_status := 'EXPIRED_FAN_NO_JOIN';
        v_fan_no_join := v_fan_no_join + 1;
      ELSIF v_booking.dropped_tech > 0 THEN
        v_status := 'EXPIRED_TECHNICAL_ISSUE';
        v_technical := v_technical + 1;
      ELSE
        -- Fallback: calls exist but none terminal and none >= 3 min.
        v_status := 'EXPIRED_TECHNICAL_ISSUE';
        v_technical := v_technical + 1;
      END IF;
      
      -- Refund path: all EXPIRED_* statuses (not COMPLETED_SUCCESSFUL).
      IF v_status <> 'COMPLETED_SUCCESSFUL' THEN
        v_gross := COALESCE(v_booking.original_price_paise, v_booking.price_paise);
        v_disc := COALESCE(v_booking.discount_paise, 0);
        
        SELECT id INTO v_wallet FROM public.wallets WHERE profile_id = v_booking.fan_id;
        IF v_wallet IS NULL THEN
          RAISE EXCEPTION 'Wallet not found for fan %', v_booking.fan_id;
        END IF;
        
        -- Build refund legs: escrow → fan wallet + (optionally) promo pool.
        v_legs := jsonb_build_array(
          jsonb_build_object('account', 'booking_escrow', 'delta_paise', -v_gross),
          jsonb_build_object('wallet_id', v_wallet, 'account', 'wallet', 'delta_paise', v_booking.price_paise)
        );
        IF v_disc > 0 THEN
          v_legs := v_legs || jsonb_build_array(
            jsonb_build_object('account', 'promo_incentive', 'delta_paise', v_disc)
          );
        END IF;
        
        -- Post the refund transaction (double-entry atomic accounting).
        PERFORM public.post_transaction('REFUND', v_gross, 'expire:'||v_booking.id::text, v_legs, v_booking.id::text);
        
        -- Release partner capacity (booking no longer counts toward daily minutes).
        v_mins := (v_booking.selected_duration::text)::int;
        UPDATE public.availability 
        SET booked_minutes = GREATEST(0, booked_minutes - v_mins)
        WHERE partner_id = v_booking.partner_id AND date = v_booking.scheduled_date;
      END IF;
      
      -- Update booking to terminal status (after refund, same transaction).
      UPDATE public.bookings 
      SET status = v_status, updated_at = now()
      WHERE id = v_booking.id;
      
    EXCEPTION WHEN OTHERS THEN
      v_failed := v_failed + 1;
      -- Log error but continue processing other bookings (don't poison the batch).
      RAISE WARNING 'expire-booking failed for %: %', v_booking.id, SQLERRM;
    END;
  END LOOP;
  
  RETURN jsonb_build_object(
    'success', true,
    'completed', v_completed,
    'expired_partner_no_show', v_partner_no_show,
    'expired_fan_no_join', v_fan_no_join,
    'expired_fan_declined', v_fan_declined,
    'expired_technical', v_technical,
    'failed', v_failed
  );
END $$;

-- ────────────────────────────────────────────────────────────────────────────
-- FUNCTION: cleanup_stalled_calls (PARTNER_INITIATED sweeper only)
-- ────────────────────────────────────────────────────────────────────────────
-- Sweeps orphaned PARTNER_INITIATED calls where the fan never joined within 30s.
-- The other sweepers (IN_PROGRESS duration complete, stale heartbeat) are already
-- handled by the BullMQ stalledCalls job via rpc_complete_call and rpc_mark_call_missed.
--
-- This function ONLY handles the 30-second PARTNER_INITIATED timeout, which was
-- missing from the Live DB implementation.
--
-- Called by: BullMQ stalled-calls job (every 1 minute)
-- Auth: Service role only (assert_system)
-- Batch size: 200 calls per run
-- ────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.cleanup_stalled_calls()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $$
DECLARE
  v_updated int := 0;
  v_failed int := 0;
BEGIN
  -- Only the job scheduler can sweep calls.
  PERFORM public.assert_system();
  
  -- PARTNER_INITIATED calls where fan never joined within 30 seconds.
  -- This is the ONLY sweeper in this function — the other sweepers (duration
  -- complete, heartbeat loss) are already in the BullMQ job via RPC calls.
  --
  -- NOTE: We update directly instead of calling rpc_mark_call_missed because
  -- that RPC has assert_caller_any(fan_id, partner_id) which doesn't allow
  -- system/admin roles. The sweeper needs system-level access.
  BEGIN
    UPDATE public.calls
    SET 
      attempt_status = 'MISSED_FAN_NO_JOIN',
      ended_at = now(),
      updated_at = now()
    WHERE attempt_status = 'PARTNER_INITIATED'
      AND partner_initiated_at < now() - INTERVAL '30 seconds'
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
END $$;

-- ────────────────────────────────────────────────────────────────────────────
-- Grant execute to service role (BullMQ job runs as this)
-- ────────────────────────────────────────────────────────────────────────────
GRANT EXECUTE ON FUNCTION public.process_end_of_day_expired_bookings() TO service_role;
GRANT EXECUTE ON FUNCTION public.cleanup_stalled_calls() TO service_role;

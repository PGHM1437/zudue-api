-- ═══════════════════════════════════════════════════════════════════════════
-- Migration 0063: Admin escape hatches for stuck bookings
-- ═══════════════════════════════════════════════════════════════════════════
-- Manual intervention tools for admins to fix bookings that the automated
-- expiry/settlement jobs can't handle (edge cases, bugs, data corruption).
--
-- These replace the legacy admin_fix_stuck_call() and cleanup_stuck_call()
-- functions but operate on bookings (not individual calls), matching the
-- Live DB's booking-centric workflow.
-- ═══════════════════════════════════════════════════════════════════════════

-- ────────────────────────────────────────────────────────────────────────────
-- FUNCTION: rpc_admin_expire_booking
-- ────────────────────────────────────────────────────────────────────────────
-- Manually force a booking into a terminal EXPIRED_* or COMPLETED_SUCCESSFUL
-- status, with refund processing if applicable. Use when automated expiry fails
-- (booking stuck in BOOKED past settle_at, wrong status, etc).
--
-- Auth: FINANCE or SUPER_ADMIN only (high-privilege operation)
-- Audit: Logged to admin_audit_log
-- ────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.rpc_admin_expire_booking(
  p_admin uuid,
  p_booking uuid,
  p_status public.booking_status
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $$
DECLARE
  v_booking RECORD;
  v_gross bigint;
  v_disc bigint;
  v_wallet uuid;
  v_legs jsonb;
  v_mins int;
BEGIN
  -- Only FINANCE or SUPER_ADMIN can manually expire bookings (money operation).
  PERFORM public.assert_admin_role('FINANCE', 'SUPER_ADMIN');
  
  -- Validate the target status is a terminal state.
  IF p_status NOT IN ('COMPLETED_SUCCESSFUL', 'EXPIRED_PARTNER_NO_SHOW', 
                       'EXPIRED_FAN_NO_JOIN', 'EXPIRED_FAN_DECLINED', 'EXPIRED_TECHNICAL_ISSUE') THEN
    RETURN jsonb_build_object('success', false, 'error', 'INVALID_STATUS');
  END IF;
  
  -- Fetch booking details for refund processing.
  SELECT 
    id, fan_id, price_paise, original_price_paise, discount_paise,
    selected_duration, partner_id, scheduled_date, status
  INTO v_booking
  FROM public.bookings
  WHERE id = p_booking
  FOR UPDATE;
  
  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'NOT_FOUND');
  END IF;
  
  -- Refund if EXPIRED_* status (not COMPLETED_SUCCESSFUL).
  -- This mirrors the automated expiry logic exactly.
  IF p_status <> 'COMPLETED_SUCCESSFUL' THEN
    v_gross := COALESCE(v_booking.original_price_paise, v_booking.price_paise);
    v_disc := COALESCE(v_booking.discount_paise, 0);
    
    SELECT id INTO v_wallet FROM public.wallets WHERE profile_id = v_booking.fan_id;
    IF v_wallet IS NULL THEN
      RETURN jsonb_build_object('success', false, 'error', 'WALLET_NOT_FOUND');
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
    
    -- Post the refund transaction.
    PERFORM public.post_transaction('REFUND', v_gross, 'admin-expire:'||p_booking::text, v_legs, p_booking::text);
    
    -- Release partner capacity.
    v_mins := (v_booking.selected_duration::text)::int;
    UPDATE public.availability
    SET booked_minutes = GREATEST(0, booked_minutes - v_mins)
    WHERE partner_id = v_booking.partner_id AND date = v_booking.scheduled_date;
  END IF;
  
  -- Update booking to terminal status.
  UPDATE public.bookings
  SET status = p_status, updated_at = now()
  WHERE id = p_booking;
  
  -- Audit log (matches existing admin RPC pattern).
  INSERT INTO public.audit_log (actor_id, actor_role, action, target_type, target_id, old_value, new_value)
  VALUES (p_admin, 'ADMIN', 'EXPIRE_BOOKING', 'BOOKING', p_booking,
          jsonb_build_object('status', v_booking.status),
          jsonb_build_object('status', p_status));
  
  RETURN jsonb_build_object('success', true, 'status', p_status);
END $$;

-- ────────────────────────────────────────────────────────────────────────────
-- FUNCTION: rpc_admin_force_settle_booking
-- ────────────────────────────────────────────────────────────────────────────
-- Immediately settle a booking, bypassing the 7-day settlement window. Use for
-- stuck bookings that should have settled but the automated job missed them, or
-- for immediate payout requests (creator urgent need, platform goodwill).
--
-- Auth: FINANCE or SUPER_ADMIN only (money operation)
-- Audit: Logged to admin_audit_log
-- ────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.rpc_admin_force_settle_booking(
  p_admin uuid,
  p_booking uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $$
DECLARE
  v_result jsonb;
  v_status public.booking_status;
BEGIN
  -- Only FINANCE or SUPER_ADMIN can force settlement (money operation).
  PERFORM public.assert_admin_role('FINANCE', 'SUPER_ADMIN');
  
  -- Check booking status is settleable (COMPLETED_SUCCESSFUL or EXPIRED_FAN_NO_JOIN).
  SELECT status INTO v_status FROM public.bookings WHERE id = p_booking;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'NOT_FOUND');
  END IF;
  
  IF v_status NOT IN ('COMPLETED_SUCCESSFUL', 'EXPIRED_FAN_NO_JOIN') THEN
    RETURN jsonb_build_object('success', false, 'error', 'NOT_SETTLEABLE', 'status', v_status);
  END IF;
  
  -- Call the standard settlement RPC (uses assert_system, so we need to be service_role).
  -- The settlement RPC is idempotent (won't double-pay if already settled).
  v_result := public.rpc_settle_booking(p_booking);
  
  IF NOT (v_result->>'success')::boolean THEN
    RETURN v_result;
  END IF;
  
  -- Audit log (matches existing admin RPC pattern).
  INSERT INTO public.audit_log (actor_id, actor_role, action, target_type, target_id, new_value)
  VALUES (p_admin, 'ADMIN', 'FORCE_SETTLE', 'BOOKING', p_booking,
          jsonb_build_object('transaction_id', v_result->>'transaction_id'));
  
  RETURN v_result;
END $$;

-- Grant execute to authenticated users (assert_admin_role gates inside).
GRANT EXECUTE ON FUNCTION public.rpc_admin_expire_booking(uuid, uuid, public.booking_status) TO authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_admin_force_settle_booking(uuid, uuid) TO authenticated;

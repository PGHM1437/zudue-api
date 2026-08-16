-- 0066a · Call partial duration requires admin review.
--
-- Business rule: A call that runs at least 3 minutes but LESS than the full
-- booked duration requires admin review. Admin manually decides payment split
-- using rpc_admin_grant_credit for partner portion and manual refund for fan.
--
-- This handles scenarios like:
-- - 5-minute booking, 4:20 actual call (partner/fan ended early)
-- - Network issues caused early disconnect
-- - Any situation where partner delivered service but not full booked time
--
-- The new REQUIRES_ADMIN_REVIEW status prevents automatic settlement and holds
-- escrow until admin manually resolves the booking.

BEGIN;

-- Add new booking status for admin review of partial calls
ALTER TYPE booking_status ADD VALUE IF NOT EXISTS 'REQUIRES_ADMIN_REVIEW';

-- Update process_end_of_day_expired_bookings to detect partial calls
-- This modifies the existing function to add the partial-duration check
CREATE OR REPLACE FUNCTION public.process_end_of_day_expired_bookings()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_booking RECORD;
  v_status public.booking_status;
  v_gross bigint;
  v_disc bigint;
  v_wallet uuid;
  v_legs jsonb;
  v_mins int;
  v_booked_seconds int;

  v_completed int := 0;
  v_admin_review int := 0;
  v_partner_no_show int := 0;
  v_fan_no_join int := 0;
  v_fan_declined int := 0;
  v_technical int := 0;
  v_failed int := 0;
BEGIN
  PERFORM public.assert_system();

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
      -- Convert enum to integer (minutes) then to seconds
      v_booked_seconds := (v_booking.selected_duration::text)::int * 60;

      -- Classification logic with partial-duration detection
      IF v_booking.max_duration_sec >= v_booked_seconds THEN
        -- Call met or exceeded booked duration — full completion
        v_status := 'COMPLETED_SUCCESSFUL';
        v_completed := v_completed + 1;
      ELSIF v_booking.max_duration_sec >= 180 THEN
        -- Call >= 3 min but < booked duration — admin review needed
        v_status := 'REQUIRES_ADMIN_REVIEW';
        v_admin_review := v_admin_review + 1;
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
        v_status := 'EXPIRED_TECHNICAL_ISSUE';
        v_technical := v_technical + 1;
      END IF;

      -- Refund logic for EXPIRED_* statuses (not COMPLETED_SUCCESSFUL or REQUIRES_ADMIN_REVIEW)
      IF v_status NOT IN ('COMPLETED_SUCCESSFUL', 'REQUIRES_ADMIN_REVIEW') THEN
        v_gross := COALESCE(v_booking.original_price_paise, v_booking.price_paise);
        v_disc := COALESCE(v_booking.discount_paise, 0);

        SELECT id INTO v_wallet FROM public.wallets WHERE profile_id = v_booking.fan_id;
        IF v_wallet IS NULL THEN
          RAISE EXCEPTION 'Wallet not found for fan %', v_booking.fan_id;
        END IF;

        v_legs := jsonb_build_array(
          jsonb_build_object('account', 'booking_escrow', 'delta_paise', -v_gross),
          jsonb_build_object('wallet_id', v_wallet, 'account', 'wallet', 'delta_paise', v_booking.price_paise)
        );
        IF v_disc > 0 THEN
          v_legs := v_legs || jsonb_build_array(
            jsonb_build_object('account', 'promo_incentive', 'delta_paise', v_disc)
          );
        END IF;

        PERFORM public.post_transaction('REFUND', v_gross, 'expire:'||v_booking.id::text, v_legs, v_booking.id::text);

        v_mins := (v_booking.selected_duration::text)::int;
        UPDATE public.availability
        SET booked_minutes = GREATEST(0, booked_minutes - v_mins)
        WHERE partner_id = v_booking.partner_id AND date = v_booking.scheduled_date;
      END IF;

      -- Update booking status and settle_at
      -- Only COMPLETED_SUCCESSFUL gets a recomputed settle_at for review window
      -- REQUIRES_ADMIN_REVIEW holds indefinitely until admin acts
      -- EXPIRED_* are already refunded, settle_at is moot
      IF v_status = 'COMPLETED_SUCCESSFUL' THEN
        UPDATE public.bookings
        SET status = v_status,
            settle_at = now() + ((SELECT settlement_window_days FROM public.platform_settings WHERE id=1) * interval '1 day'),
            updated_at = now()
        WHERE id = v_booking.id;
      ELSE
        UPDATE public.bookings
        SET status = v_status, updated_at = now()
        WHERE id = v_booking.id;
      END IF;

    EXCEPTION WHEN OTHERS THEN
      v_failed := v_failed + 1;
      RAISE WARNING 'expire-booking failed for %: %', v_booking.id, SQLERRM;
    END;
  END LOOP;

  RETURN jsonb_build_object(
    'success', true,
    'completed', v_completed,
    'admin_review', v_admin_review,
    'expired_partner_no_show', v_partner_no_show,
    'expired_fan_no_join', v_fan_no_join,
    'expired_fan_declined', v_fan_declined,
    'expired_technical', v_technical,
    'failed', v_failed
  );
END $function$;

-- Create admin RPC to resolve partial calls
-- Admin manually decides payment split after reviewing call details
CREATE OR REPLACE FUNCTION public.rpc_admin_resolve_partial_call(
  p_admin uuid,
  p_booking uuid,
  p_partner_paise bigint,
  p_fan_refund_paise bigint,
  p_notes text
) RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  b public.bookings;
  v_wallet uuid;
  v_total bigint;
  v_partner_txn jsonb;
  v_refund_txn jsonb;
BEGIN
  PERFORM public.assert_is_admin_actor(p_admin);
  PERFORM public.assert_admin_role('FINANCE', 'SUPER_ADMIN');

  SELECT * INTO b FROM public.bookings WHERE id = p_booking FOR UPDATE;
  IF NOT FOUND THEN 
    RETURN jsonb_build_object('success', false, 'error', 'NOT_FOUND'); 
  END IF;

  IF b.status <> 'REQUIRES_ADMIN_REVIEW' THEN
    RETURN jsonb_build_object('success', false, 'error', 'INVALID_STATUS', 'status', b.status);
  END IF;

  -- Validate split adds up to original price
  v_total := COALESCE(b.original_price_paise, b.price_paise);
  IF p_partner_paise + p_fan_refund_paise <> v_total THEN
    RETURN jsonb_build_object('success', false, 'error', 'SPLIT_MISMATCH',
      'required_total', v_total, 'provided_total', p_partner_paise + p_fan_refund_paise);
  END IF;

  -- Idempotency check
  IF EXISTS (SELECT 1 FROM public.partner_earnings WHERE service_id = p_booking) THEN
    RETURN jsonb_build_object('success', true, 'already_resolved', true);
  END IF;

  -- Move partner portion from escrow to partner_payable
  IF p_partner_paise > 0 THEN
    v_partner_txn := public.post_transaction('PARTNER_EARNING', p_partner_paise, 
      'partial-settle:' || b.id::text,
      jsonb_build_array(
        jsonb_build_object('account', 'booking_escrow', 'delta_paise', -p_partner_paise),
        jsonb_build_object('account', 'partner_payable', 'delta_paise', p_partner_paise)
      ),
      b.id::text);

    INSERT INTO public.partner_earnings (partner_id, transaction_id, service_type, service_id, amount_paise)
    VALUES (b.partner_id, (v_partner_txn->>'transaction_id')::uuid, 'VIDEO_CALL', b.id, p_partner_paise);
  END IF;

  -- Refund fan portion from escrow to fan wallet
  IF p_fan_refund_paise > 0 THEN
    SELECT id INTO v_wallet FROM public.wallets WHERE profile_id = b.fan_id;
    IF v_wallet IS NULL THEN
      RAISE EXCEPTION 'Wallet not found for fan %', b.fan_id;
    END IF;

    v_refund_txn := public.post_transaction('REFUND', p_fan_refund_paise,
      'partial-refund:' || b.id::text,
      jsonb_build_array(
        jsonb_build_object('account', 'booking_escrow', 'delta_paise', -p_fan_refund_paise),
        jsonb_build_object('wallet_id', v_wallet, 'account', 'wallet', 'delta_paise', p_fan_refund_paise)
      ),
      b.id::text);
  END IF;

  -- Mark booking as resolved
  UPDATE public.bookings
  SET status = 'COMPLETED_SUCCESSFUL',
      updated_at = now()
  WHERE id = p_booking;

  -- Log admin action
  INSERT INTO public.audit_log (actor_id, actor_role, action, target_type, target_id, new_value)
  VALUES (p_admin, 'ADMIN', 'RESOLVE_PARTIAL_CALL', 'booking', p_booking,
    jsonb_build_object(
      'partner_paise', p_partner_paise,
      'fan_refund_paise', p_fan_refund_paise,
      'notes', p_notes
    ));

  RETURN jsonb_build_object(
    'success', true,
    'partner_paise', p_partner_paise,
    'fan_refund_paise', p_fan_refund_paise,
    'partner_txn_id', v_partner_txn->>'transaction_id',
    'refund_txn_id', v_refund_txn->>'transaction_id'
  );
END $function$;

-- Grant execute permissions
REVOKE ALL ON FUNCTION rpc_admin_resolve_partial_call(uuid, uuid, bigint, bigint, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION rpc_admin_resolve_partial_call(uuid, uuid, bigint, bigint, text) TO zudue_app;

INSERT INTO _migrations (name) VALUES ('0066a_call_partial_duration_admin_review.sql')
  ON CONFLICT (name) DO NOTHING;

COMMIT;

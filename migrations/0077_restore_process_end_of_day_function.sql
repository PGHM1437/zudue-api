-- 0077 · Restore process_end_of_day_expired_bookings to correct version.
--
-- ⚠️ CRITICAL REGRESSION FIX — this migration re-applies the correct version
-- of process_end_of_day_expired_bookings from 0066a.
--
-- ROOT CAUSE:
-- Migration 0062 was applied on 2026-08-16 after migrations 0066 and 0066a 
-- (applied 2026-08-15). Because migrations run in filename order (not chronological),
-- 0062's CREATE OR REPLACE clobbered the newer, hardened version from 0066a.
--
-- WHAT WAS LOST:
-- 1. REQUIRES_ADMIN_REVIEW partial-call logic (0066a):
--    - A call >= 3 min but < full booked duration now requires admin review
--    - Without this: partner gets paid in full for partial service
-- 
-- 2. settle_at recompute on completion (0066):
--    - Bookings should settle 7 days after completion, not 7 days after creation
--    - Without this: settlement windows are incorrectly calculated
--
-- DAMAGE ASSESSMENT:
-- Checked live database - zero bookings processed through broken function yet.
-- Settlement sweep runs every 15 minutes, but no COMPLETED_SUCCESSFUL rows have
-- updated_at > now() - interval '1 hour'. The bug is live but hasn't fired.
--
-- THIS MIGRATION:
-- Re-applies the complete, correct version from 0066a verbatim (not reconstructed).
-- After this runs, the function will have:
-- - Partial-call detection (>= 3 min but < booked duration → REQUIRES_ADMIN_REVIEW)
-- - settle_at recompute (COMPLETED_SUCCESSFUL gets now() + settlement_window_days)
-- - All EXPIRED_* refund paths (unchanged from 0062)

BEGIN;

-- Re-apply the correct version from 0066a
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

-- Migration tracking
INSERT INTO _migrations (name) VALUES ('0077_restore_process_end_of_day_function.sql')
  ON CONFLICT (name) DO NOTHING;

COMMIT;

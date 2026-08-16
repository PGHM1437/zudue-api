-- 0075 · Platform settings: IST operational hours columns.
--
-- Legacy had `call_operational_start_hour_ist` and `call_operational_end_hour_ist`
-- on platform_settings. These controlled when partners could accept calls (e.g.
-- 9 AM – 9 PM IST). Live has no equivalent — partners can operate 24/7 with no
-- time-based guard.
--
-- The DB stores the hours as integers (0–23). The gate itself lives inside
-- rpc_partner_initiate_call (see below) rather than the API layer — this
-- keeps the DB in UTC (correct) while the enforcement and the configurable
-- window both live in the one place a call attempt can actually start.
--
-- Defaults: 9 (9 AM IST) to 21 (9 PM IST) — matching legacy's effective range.
-- The existing `booking_lead_days` column already exists and is unrelated.

BEGIN;

-- Add operational hours columns (IST)
ALTER TABLE public.platform_settings
  ADD COLUMN IF NOT EXISTS operational_start_hour_ist INTEGER NOT NULL DEFAULT 9;

ALTER TABLE public.platform_settings
  ADD COLUMN IF NOT EXISTS operational_end_hour_ist INTEGER NOT NULL DEFAULT 21;

-- Add CHECK: start < end, both in 0–23 range
ALTER TABLE public.platform_settings
  DROP CONSTRAINT IF EXISTS operational_hours_bounds_check;

ALTER TABLE public.platform_settings
  ADD CONSTRAINT operational_hours_bounds
  CHECK (
    operational_start_hour_ist >= 0 AND operational_start_hour_ist <= 23
    AND operational_end_hour_ist >= 0 AND operational_end_hour_ist <= 23
    AND operational_start_hour_ist < operational_end_hour_ist
  );

-- Also add a CHECK on payout_day_of_month while we're here (identified in
-- the constraints audit as a missing CHECK). Must be 1–28 (safe for all months).
ALTER TABLE public.platform_settings
  DROP CONSTRAINT IF EXISTS payout_day_of_month_check;

ALTER TABLE public.platform_settings
  ADD CONSTRAINT payout_day_of_month_bounds
  CHECK (payout_day_of_month >= 1 AND payout_day_of_month <= 28);

-- Wire the actual gate. The two columns above were previously inert — grepped
-- apps/api and confirmed nothing read them. The enforcement point is
-- rpc_partner_initiate_call (the only place a call attempt starts), checked
-- in the DB rather than the API layer: this schema's convention is that
-- business rules live in SECURITY DEFINER RPCs so they hold regardless of
-- which client or API revision calls them, and it avoids trusting the app
-- server's clock/timezone handling for something enforceable in one place.
CREATE OR REPLACE FUNCTION public.rpc_partner_initiate_call(p_booking uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  b public.bookings; v_call uuid; v_meeting text;
  v_start_hour int; v_end_hour int; v_ist_hour int;
BEGIN
  SELECT * INTO b FROM public.bookings WHERE id = p_booking FOR UPDATE;
  IF NOT FOUND OR b.status <> 'BOOKED' THEN
    RETURN jsonb_build_object('success',false,'error','NOT_BOOKABLE'); END IF;
  PERFORM public.assert_caller(b.partner_id);

  SELECT operational_start_hour_ist, operational_end_hour_ist
    INTO v_start_hour, v_end_hour
    FROM public.platform_settings LIMIT 1;
  v_ist_hour := EXTRACT(HOUR FROM (now() AT TIME ZONE 'Asia/Kolkata'))::int;
  IF v_start_hour IS NOT NULL AND (v_ist_hour < v_start_hour OR v_ist_hour >= v_end_hour) THEN
    RETURN jsonb_build_object('success',false,'error','OUTSIDE_OPERATIONAL_HOURS',
      'start_hour_ist', v_start_hour, 'end_hour_ist', v_end_hour);
  END IF;

  IF EXISTS (SELECT 1 FROM public.calls c WHERE c.booking_id=p_booking
       AND c.attempt_status='PARTNER_INITIATED' AND c.partner_initiated_at > now()-interval '60 seconds') THEN
    RETURN jsonb_build_object('success',false,'error','ALREADY_INITIATED'); END IF;

  v_meeting := COALESCE(b.meeting_id, 'zudue-'||gen_random_uuid()::text);
  UPDATE public.bookings SET meeting_id=v_meeting, attempts=attempts+1, updated_at=now() WHERE id=p_booking;

  INSERT INTO public.calls (booking_id, fan_id, partner_id, attempt_status, meeting_id, partner_initiated_at)
  VALUES (p_booking, b.fan_id, b.partner_id, 'PARTNER_INITIATED', v_meeting, now())
  RETURNING id INTO v_call;

  RETURN jsonb_build_object('success',true,'call_id',v_call,'meeting_id',v_meeting);
END $function$;

INSERT INTO _migrations (name) VALUES ('0075_platform_settings_ist_hours.sql')
  ON CONFLICT (name) DO NOTHING;

COMMIT;

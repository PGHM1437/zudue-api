-- 0078 · Remove DB-level operational-hours enforcement from rpc_partner_initiate_call.
--
-- REVERSES part of 0075. Product decision (confirmed 2026-08-16): partners can
-- initiate a call at any hour. There is no platform-wide call window. If a
-- partner wants to go live outside typical hours, that is between them and
-- the fan — the DB should not block it.
--
-- The "is it late, are you sure" gate belongs at the UI layer: the client
-- shows a confirmation ("It's after 9 PM — are you ready to take this call?")
-- before enabling the initiate button outside typical hours, using
-- platform_settings.operational_start_hour_ist / operational_end_hour_ist as
-- the values to compare against. The columns stay — they're still useful as
-- the single source of truth for what "typical hours" means for that UI
-- prompt — but they no longer gate the RPC itself.
--
-- Everything else in rpc_partner_initiate_call (booking-status check,
-- caller-authorization check, the 60-second re-initiate guard, meeting
-- creation) is unchanged from the live 0075 version.

BEGIN;

CREATE OR REPLACE FUNCTION public.rpc_partner_initiate_call(p_booking uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  b public.bookings; v_call uuid; v_meeting text;
BEGIN
  SELECT * INTO b FROM public.bookings WHERE id = p_booking FOR UPDATE;
  IF NOT FOUND OR b.status <> 'BOOKED' THEN
    RETURN jsonb_build_object('success',false,'error','NOT_BOOKABLE'); END IF;
  PERFORM public.assert_caller(b.partner_id);

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

INSERT INTO _migrations (name) VALUES ('0078_remove_operational_hours_db_enforcement.sql')
  ON CONFLICT (name) DO NOTHING;

COMMIT;

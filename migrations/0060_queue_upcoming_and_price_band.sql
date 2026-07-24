-- 0060 · Two corrections on top of 0059.
--
-- 1. QUEUE IS TODAY, NOT THE FUTURE. 0059 dropped the upper date bound so
--    future bookings would show — but the call queue is the "act now" list, and
--    a call booked for next week does not belong there. Restore
--    scheduled_date <= CURRENT_DATE. Future bookings surface separately as
--    "Upcoming calls" (a plain bookings read in the API, no view needed).
--
-- 2. NO PER-SERVICE "BASIC AMOUNT". rpc_partner_set_service enforced a
--    per-type minimum from platform_settings.min_service_prices (₹200 / ₹100 /
--    ₹50). The creator should price freely — a single platform band of
--    ₹10–₹10,00,000 (1000–100000000 paise) is the only guard. Drop the per-type
--    floor; keep min_service_prices in sync as ₹10 across the board so nothing
--    displays a stale minimum.

BEGIN;

-- ── 1 · Queue = today and recent-unresolved only ────────────────────────
CREATE OR REPLACE VIEW vw_partner_call_queue AS
SELECT b.id AS booking_id, b.partner_id, b.fan_id, p.full_name AS fan_name,
       b.scheduled_date, b.selected_duration, b.fan_ready_at,
       CASE
         WHEN b.fan_ready_at IS NOT NULL THEN 0
         WHEN EXISTS (SELECT 1 FROM calls c WHERE c.booking_id=b.id
                        AND c.attempt_status = ANY (ARRAY['PARTNER_INITIATED'::call_status,'IN_PROGRESS'::call_status])
                        AND c.ended_at IS NULL) THEN 1
         WHEN NOT EXISTS (SELECT 1 FROM calls c WHERE c.booking_id=b.id) THEN 2
         WHEN EXISTS (SELECT 1 FROM calls c WHERE c.booking_id=b.id
                        AND c.attempt_status = ANY (ARRAY['MISSED_FAN_NO_JOIN'::call_status,'MISSED_FAN_DECLINED'::call_status,'DROPPED_TECHNICAL_ISSUE'::call_status])) THEN 3
         ELSE 4
       END AS queue_priority
  FROM bookings b
  JOIN profiles p ON p.id = b.fan_id
 WHERE b.status = ANY (ARRAY['BOOKED'::booking_status,'EXPIRED_FAN_NO_JOIN'::booking_status])
   AND b.scheduled_date >= (CURRENT_DATE - 7)
   AND b.scheduled_date <= CURRENT_DATE          -- today & recent only; future → "Upcoming calls"
   AND NOT EXISTS (SELECT 1 FROM calls c WHERE c.booking_id=b.id AND c.attempt_status='COMPLETED_SUCCESSFUL'::call_status)
 ORDER BY
   (CASE WHEN b.fan_ready_at IS NOT NULL THEN 0
         WHEN EXISTS (SELECT 1 FROM calls c WHERE c.booking_id=b.id AND c.attempt_status = ANY (ARRAY['PARTNER_INITIATED'::call_status,'IN_PROGRESS'::call_status]) AND c.ended_at IS NULL) THEN 1
         WHEN NOT EXISTS (SELECT 1 FROM calls c WHERE c.booking_id=b.id) THEN 2
         WHEN EXISTS (SELECT 1 FROM calls c WHERE c.booking_id=b.id AND c.attempt_status = ANY (ARRAY['MISSED_FAN_NO_JOIN'::call_status,'MISSED_FAN_DECLINED'::call_status,'DROPPED_TECHNICAL_ISSUE'::call_status])) THEN 3
         ELSE 4 END),
   b.scheduled_date,
   (CASE WHEN b.fan_ready_at IS NOT NULL THEN EXTRACT(epoch FROM now()-b.fan_ready_at)
         ELSE EXTRACT(epoch FROM now()-b.created_at) END);

ALTER VIEW vw_partner_call_queue SET (security_invoker = true);
REVOKE ALL ON public.vw_partner_call_queue FROM PUBLIC;
GRANT SELECT ON public.vw_partner_call_queue TO zudue_app;

-- ── 2 · Flat price band, no per-service minimum ─────────────────────────
CREATE OR REPLACE FUNCTION public.rpc_partner_set_service(
  p_partner uuid, p_type service_type_enum, p_duration call_duration_options_enum,
  p_price_paise bigint, p_active boolean DEFAULT true)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $function$
DECLARE v_status public.account_status;
BEGIN
  PERFORM public.assert_caller(p_partner);
  SELECT status INTO v_status FROM public.partner_profiles WHERE profile_id=p_partner;
  IF v_status IS DISTINCT FROM 'ACTIVE' THEN
    RETURN jsonb_build_object('success',false,'error','PARTNER_NOT_ACTIVE'); END IF;
  IF p_type = 'VIDEO_CALL' AND p_duration IS NULL THEN
    RETURN jsonb_build_object('success',false,'error','DURATION_REQUIRED'); END IF;
  IF p_type <> 'VIDEO_CALL' AND p_duration IS NOT NULL THEN
    RETURN jsonb_build_object('success',false,'error','DURATION_NOT_ALLOWED'); END IF;
  -- No per-service "basic amount": price anything within one platform band,
  -- ₹10–₹10,00,000 (1000–100000000 paise). Only enforced for an active service.
  IF p_active AND (p_price_paise < 1000 OR p_price_paise > 100000000) THEN
    RETURN jsonb_build_object('success',false,'error','PRICE_OUT_OF_RANGE',
      'min_paise',1000,'max_paise',100000000); END IF;
  INSERT INTO public.partner_services (partner_id, service_type, duration, price_paise, is_active)
    VALUES (p_partner, p_type, p_duration, p_price_paise, p_active)
    ON CONFLICT (partner_id, service_type, duration) DO UPDATE
      SET price_paise = EXCLUDED.price_paise, is_active = EXCLUDED.is_active, updated_at = now();
  RETURN jsonb_build_object('success',true);
END $function$;

-- Keep the informational floor in sync (₹10) so no stale minimum is displayed.
UPDATE public.platform_settings
   SET min_service_prices = '{"VIDEO_CALL":1000,"QUICK_QUESTION":1000,"SHOUT_OUT":1000}'::jsonb
 WHERE id = 1;

INSERT INTO _migrations (name) VALUES ('0060_queue_upcoming_and_price_band.sql')
  ON CONFLICT (name) DO NOTHING;

COMMIT;

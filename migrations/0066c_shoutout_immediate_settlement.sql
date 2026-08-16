-- 0066c · Shoutout immediate settlement on acceptance (manual or auto).
--
-- Business rule: When a fan explicitly accepts a shoutout OR when auto-confirm
-- triggers (fan took no action for 3 days), partner should be paid immediately.
-- Settlement happens on the next sweep run (~15 minutes maximum).
--
-- NOTE: This removes the grace period for reporting after auto-confirm. Once
-- auto-confirm fires, fan cannot report. This is by design - fans have 3 days
-- to review and take action (accept/correct/report). After 3 days of inaction,
-- the delivery is considered accepted.

BEGIN;

-- Update rpc_confirm_shoutout - fan manual acceptance triggers immediate settlement
CREATE OR REPLACE FUNCTION public.rpc_confirm_shoutout(p_fan uuid, p_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE r public.shout_out_requests;
BEGIN
  SELECT * INTO r FROM public.shout_out_requests WHERE id=p_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('success',false,'error','NOT_FOUND'); END IF;
  PERFORM public.assert_caller(p_fan);
  IF p_fan IS DISTINCT FROM r.fan_id THEN
    RETURN jsonb_build_object('success',false,'error','FAN_MISMATCH'); END IF;
  IF r.status <> 'VIDEO_DELIVERED_TO_FAN' THEN
    RETURN jsonb_build_object('success',false,'error','INVALID_STATE'); END IF;
  IF r.fan_confirmed_at IS NOT NULL THEN
    RETURN jsonb_build_object('success',true,'already_confirmed',true); END IF;

  -- Fan acceptance triggers immediate settlement (settle_at=now())
  -- Next settlement sweep (~15 min max) will process payment
  UPDATE public.shout_out_requests
     SET fan_confirmed_at=now(), 
         fan_confirmed_source='FAN',
         settle_at=now(),
         updated_at=now()
   WHERE id=p_id AND status='VIDEO_DELIVERED_TO_FAN' AND fan_confirmed_at IS NULL;
  IF NOT FOUND THEN RETURN jsonb_build_object('success',false,'error','INVALID_STATE'); END IF;
  
  RETURN jsonb_build_object('success',true,'confirmed',true);
END $function$;

-- Update rpc_auto_confirm_shoutout - auto-confirm also triggers immediate settlement
CREATE OR REPLACE FUNCTION public.rpc_auto_confirm_shoutout(p_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE r public.shout_out_requests;
BEGIN
  PERFORM public.assert_system();   -- settlement sweep job only
  SELECT * INTO r FROM public.shout_out_requests WHERE id=p_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('success',false,'error','NOT_FOUND'); END IF;
  IF r.status <> 'VIDEO_DELIVERED_TO_FAN' OR r.fan_confirmed_at IS NOT NULL
     OR r.review_deadline_at IS NULL OR r.review_deadline_at > now() THEN
    RETURN jsonb_build_object('success',false,'error','NOT_CONFIRMABLE'); END IF;

  -- Auto-confirm also triggers immediate settlement
  -- Fan had 3 days to act (accept/correct/report) and took no action
  -- This is considered implicit acceptance
  UPDATE public.shout_out_requests
     SET fan_confirmed_at=now(), 
         fan_confirmed_source='AUTO',
         settle_at=now(),
         updated_at=now()
   WHERE id=p_id;
   
  RETURN jsonb_build_object('success',true);
END $function$;

INSERT INTO _migrations (name) VALUES ('0066c_shoutout_immediate_settlement.sql')
  ON CONFLICT (name) DO NOTHING;

COMMIT;

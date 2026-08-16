-- 0066b · DM settlement timing uses configurable platform setting.
--
-- Business rule: When partner answers a paid question, settlement timing should
-- respect the platform's configurable settlement_window_days setting (currently
-- 7 days, can be changed by admin to 1 day or any other value).
--
-- This provides flexibility for the business to adjust settlement timing without
-- code changes. Current default is 7 days, which gives fans adequate time to
-- report issues before partners get paid.

BEGIN;

-- Update rpc_partner_answer to set settle_at using configurable window
-- Previously settle_at was set at window opening, now set when partner answers
CREATE OR REPLACE FUNCTION public.rpc_partner_answer(p_partner uuid, p_conversation uuid, p_text text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE 
  v_win public.conversation_windows;
  v_conv_partner uuid;
  v_settlement_days int;
BEGIN
  SELECT partner_id INTO v_conv_partner FROM public.conversations WHERE id=p_conversation;
  IF v_conv_partner IS NULL THEN RETURN jsonb_build_object('success',false,'error','NOT_FOUND'); END IF;
  PERFORM public.assert_caller(v_conv_partner);
  IF p_partner IS DISTINCT FROM v_conv_partner THEN
    RETURN jsonb_build_object('success',false,'error','PARTNER_MISMATCH'); END IF;

  -- Reply into the latest window whether it is still OPEN or already ANSWERED:
  -- the partner keeps talking until the fan opens a new paid window. Only a
  -- conversation the fan never opened (no window at all) is rejected.
  SELECT * INTO v_win FROM public.conversation_windows
    WHERE conversation_id=p_conversation AND status IN ('OPEN','ANSWERED')
    ORDER BY opened_at DESC LIMIT 1 FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('success',false,'error','NO_WINDOW',
      'hint','the fan has not opened a paid conversation yet'); END IF;

  INSERT INTO public.messages (window_id, sender, body) VALUES (v_win.id,'PARTNER',p_text);

  -- First reply to an OPEN window consumes the fan's paid turn. The settle job
  -- captures escrow off ANSWERED, so flip it exactly once; later replies leave
  -- it ANSWERED (no double settle).
  -- Uses platform_settings.settlement_window_days for consistency with other services.
  IF v_win.status = 'OPEN' THEN
    SELECT settlement_window_days INTO v_settlement_days FROM public.platform_settings WHERE id=1;
    
    UPDATE public.conversation_windows 
    SET status='ANSWERED', 
        closed_at=now(),
        settle_at=now() + (v_settlement_days * interval '1 day')
    WHERE id=v_win.id;
  END IF;
  
  UPDATE public.conversations SET last_activity_at=now() WHERE id=p_conversation;
  RETURN jsonb_build_object('success',true,'window_id',v_win.id);
END $function$;

INSERT INTO _migrations (name) VALUES ('0066b_dm_configurable_settlement.sql')
  ON CONFLICT (name) DO NOTHING;

COMMIT;

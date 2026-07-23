-- 0016 · DM / Quick-Question RPCs — the windowed monetized conversation, clean.
-- Rules (decoded): first contact FREE; 5 messages per window; a new fan message
-- after the partner replies opens a PAID window (escrow); partner reply closes
-- the window; 48h answer deadline; block-aware. Settlement at day-7 (job).

BEGIN;

-- Fan sends a message/question. Returns the window kind + whether charged.
CREATE OR REPLACE FUNCTION rpc_ask_question(
  p_fan uuid, p_partner uuid, p_text text, p_price_paise bigint)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_conv uuid; v_win public.conversation_windows; v_wallet uuid;
        v_count int; v_any_window boolean; v_new_win uuid; v_res jsonb;
BEGIN
  IF public.is_blocked(p_fan, p_partner, 'DM') THEN
    RETURN jsonb_build_object('success',false,'error','BLOCKED'); END IF;

  -- conversation (one per pair)
  SELECT id INTO v_conv FROM public.conversations WHERE fan_id=p_fan AND partner_id=p_partner;
  IF v_conv IS NULL THEN
    INSERT INTO public.conversations (fan_id, partner_id) VALUES (p_fan, p_partner) RETURNING id INTO v_conv;
  END IF;

  -- latest OPEN window
  SELECT * INTO v_win FROM public.conversation_windows
    WHERE conversation_id=v_conv AND status='OPEN' ORDER BY opened_at DESC LIMIT 1 FOR UPDATE;

  IF FOUND THEN
    -- add to existing window if under the 5-message cap (no charge)
    SELECT count(*) INTO v_count FROM public.messages m
      WHERE m.window_id=v_win.id AND m.sender='FAN';
    IF v_count >= v_win.message_cap THEN
      RETURN jsonb_build_object('success',false,'error','WINDOW_LIMIT',
        'messages_in_window', v_count, 'cap', v_win.message_cap); END IF;
    INSERT INTO public.messages (window_id, sender, body) VALUES (v_win.id,'FAN',p_text);
    UPDATE public.conversations SET last_activity_at=now() WHERE id=v_conv;
    RETURN jsonb_build_object('success',true,'window_id',v_win.id,'kind',v_win.kind,'charged',false);
  END IF;

  -- no open window → open a new one
  SELECT EXISTS(SELECT 1 FROM public.conversation_windows WHERE conversation_id=v_conv) INTO v_any_window;
  v_new_win := gen_random_uuid();

  IF NOT v_any_window THEN
    -- FIRST contact → FREE window
    INSERT INTO public.conversation_windows (id, conversation_id, kind, charge_paise, status)
      VALUES (v_new_win, v_conv, 'FREE', 0, 'OPEN');
  ELSE
    -- PAID window → escrow the charge, 48h deadline, day-7 settle
    SELECT id INTO v_wallet FROM public.wallets WHERE profile_id=p_fan;
    v_res := public.post_transaction('QUESTION_DEBIT', p_price_paise, 'qq:'||v_new_win::text,
      jsonb_build_array(
        jsonb_build_object('wallet_id',v_wallet,'account','wallet','delta_paise',-p_price_paise),
        jsonb_build_object('account','booking_escrow','delta_paise',p_price_paise)),
      v_new_win::text);
    INSERT INTO public.conversation_windows (id, conversation_id, kind, charge_paise, status,
        response_deadline, escrow_txn_id, settle_at)
      VALUES (v_new_win, v_conv, 'PAID', p_price_paise, 'OPEN',
        now()+interval '48 hours', (v_res->>'transaction_id')::uuid, now()+interval '7 days');
  END IF;

  INSERT INTO public.messages (window_id, sender, body) VALUES (v_new_win,'FAN',p_text);
  UPDATE public.conversations SET last_activity_at=now() WHERE id=v_conv;
  RETURN jsonb_build_object('success',true,'window_id',v_new_win,
    'kind', CASE WHEN v_any_window THEN 'PAID' ELSE 'FREE' END,
    'charged', v_any_window);
END $$;

-- Partner replies → adds message + CLOSES the window (ANSWERED). Money settles at day-7.
CREATE OR REPLACE FUNCTION rpc_partner_answer(p_partner uuid, p_conversation uuid, p_text text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_win public.conversation_windows;
BEGIN
  SELECT * INTO v_win FROM public.conversation_windows
    WHERE conversation_id=p_conversation AND status='OPEN' ORDER BY opened_at DESC LIMIT 1 FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('success',false,'error','NO_OPEN_WINDOW'); END IF;

  INSERT INTO public.messages (window_id, sender, body) VALUES (v_win.id,'PARTNER',p_text);
  UPDATE public.conversation_windows SET status='ANSWERED', closed_at=now() WHERE id=v_win.id;
  UPDATE public.conversations SET last_activity_at=now() WHERE id=p_conversation;
  RETURN jsonb_build_object('success',true,'window_id',v_win.id,'was_paid', v_win.kind='PAID');
END $$;

-- Settle a PAID window at day-7 (answered → escrow to partner + earning). Job.
CREATE OR REPLACE FUNCTION rpc_settle_window(p_window uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE w public.conversation_windows; v_partner uuid; v_res jsonb;
BEGIN
  SELECT * INTO w FROM public.conversation_windows WHERE id=p_window FOR UPDATE;
  IF NOT FOUND OR w.kind<>'PAID' OR w.charge_paise=0 THEN
    RETURN jsonb_build_object('success',false,'error','NOT_SETTLEABLE'); END IF;
  SELECT partner_id INTO v_partner FROM public.conversations WHERE id=w.conversation_id;

  v_res := public.post_transaction('PARTNER_EARNING', w.charge_paise, 'settlewin:'||w.id::text,
    jsonb_build_array(
      jsonb_build_object('account','booking_escrow','delta_paise',-w.charge_paise),
      jsonb_build_object('account','partner_payable','delta_paise',w.charge_paise)),
    w.id::text);
  INSERT INTO public.partner_earnings (partner_id, transaction_id, service_type, service_id, amount_paise)
    VALUES (v_partner, (v_res->>'transaction_id')::uuid, 'QUICK_QUESTION', w.id, w.charge_paise);
  RETURN jsonb_build_object('success',true);
END $$;

REVOKE ALL ON FUNCTION rpc_ask_question(uuid,uuid,text,bigint) FROM PUBLIC;
REVOKE ALL ON FUNCTION rpc_partner_answer(uuid,uuid,text) FROM PUBLIC;
REVOKE ALL ON FUNCTION rpc_settle_window(uuid) FROM PUBLIC;

COMMIT;

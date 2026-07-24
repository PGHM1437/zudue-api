-- 0059 · Correct three flows to the intended (legacy) design.
--
-- 1. PARTNER DM REPLIES. rpc_partner_answer required an OPEN window and set it
--    to ANSWERED after ONE reply, so a partner could send exactly one message
--    and the next failed with NO_OPEN_WINDOW. The intended model: a fan pays to
--    open a window and may send up to the message cap; the PARTNER may then send
--    ANY NUMBER of replies until the fan opens a new (paid) window. The first
--    partner reply consumes the fan's paid turn (window -> ANSWERED, which the
--    settle job later captures), but further partner replies are allowed while
--    ANSWERED. The fan side (rpc_ask_question) already requires a fresh window
--    once the current one is answered, so no change is needed there.
--
-- 2. PARTNER BOOKING VISIBILITY. vw_partner_call_queue filtered
--    scheduled_date <= CURRENT_DATE, hiding every FUTURE booking — so a call
--    booked for tomorrow was invisible to the creator. Show today and upcoming
--    (drop the upper bound); the existing queue_priority still floats
--    ready-now fans to the top.
--
-- 3. SHOUT-OUT IS ADMIN-MONITORED. rpc_upload_shoutout set the status straight
--    to VIDEO_DELIVERED_TO_FAN — the partner delivered directly to the fan. The
--    real flow: the partner submits a video LINK, it goes to the admin
--    (VIDEO_RECEIVED_BY_ADMIN), and the admin reviews and delivers offline.
--    rpc_admin_deliver_shoutout is the review/deliver step (approve -> delivered,
--    reject -> back to the partner with a note). Settlement still runs off
--    VIDEO_DELIVERED_TO_FAN, so the creator is paid only after admin delivery.

BEGIN;

-- ── 1 · Partner may send unlimited replies within a window ───────────────
CREATE OR REPLACE FUNCTION rpc_partner_answer(p_partner uuid, p_conversation uuid, p_text text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_win public.conversation_windows; v_conv_partner uuid;
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
  IF v_win.status = 'OPEN' THEN
    UPDATE public.conversation_windows SET status='ANSWERED', closed_at=now() WHERE id=v_win.id;
  END IF;
  UPDATE public.conversations SET last_activity_at=now() WHERE id=p_conversation;
  RETURN jsonb_build_object('success',true,'window_id',v_win.id);
END $$;

-- ── 2 · Partner queue includes upcoming bookings ─────────────────────────
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
   AND b.scheduled_date >= (CURRENT_DATE - 7)   -- keep recent unresolved; no upper bound so FUTURE bookings show
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

-- ── 3 · Shout-out: partner submits a link → admin review → admin delivers ─
CREATE OR REPLACE FUNCTION rpc_upload_shoutout(p_id uuid, p_video_path text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE r public.shout_out_requests;
BEGIN
  SELECT * INTO r FROM public.shout_out_requests WHERE id=p_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('success',false,'error','NOT_FOUND'); END IF;
  PERFORM public.assert_caller(r.partner_id);
  IF btrim(coalesce(p_video_path,'')) = '' THEN
    RETURN jsonb_build_object('success',false,'error','LINK_REQUIRED'); END IF;

  -- Submits the video LINK to the admin for review — NOT to the fan. Admin
  -- delivers offline via rpc_admin_deliver_shoutout.
  UPDATE public.shout_out_requests
     SET partner_video_storage_path = p_video_path,
         delivered_video_link       = p_video_path,
         partner_video_submitted_at = now(),
         status                     = 'VIDEO_RECEIVED_BY_ADMIN',
         updated_at                 = now()
   WHERE id=p_id AND status='AWAITING_PARTNER_VIDEO';
  IF NOT FOUND THEN RETURN jsonb_build_object('success',false,'error','INVALID_STATE'); END IF;

  INSERT INTO public.notifications (recipient_id, event_type, title, message, related_entity_type, related_entity_id)
    SELECT a.id,'SHOUTOUT_NEW_REQUEST_ADMIN_CC_PARTNER','Shout-out video submitted',
           'A creator submitted a shout-out video for review.','shoutout',p_id
      FROM public.profiles a WHERE a.role='ADMIN' LIMIT 1;

  RETURN jsonb_build_object('success',true,'status','VIDEO_RECEIVED_BY_ADMIN');
END $$;

CREATE OR REPLACE FUNCTION rpc_admin_deliver_shoutout(
  p_admin uuid, p_id uuid, p_approve boolean, p_note text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE r public.shout_out_requests;
BEGIN
  PERFORM public.assert_is_admin_actor(p_admin);
  PERFORM public.assert_admin_role('SUPER_ADMIN','SUPPORT','MODERATOR');
  SELECT * INTO r FROM public.shout_out_requests WHERE id=p_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('success',false,'error','NOT_FOUND'); END IF;
  IF r.status <> 'VIDEO_RECEIVED_BY_ADMIN' THEN
    RETURN jsonb_build_object('success',false,'error','NOT_AWAITING_REVIEW','status',r.status); END IF;

  IF p_approve THEN
    -- Delivered offline by the platform; we just record it. Settlement runs off
    -- VIDEO_DELIVERED_TO_FAN, so the creator is paid only after this.
    UPDATE public.shout_out_requests
       SET status='VIDEO_DELIVERED_TO_FAN', delivered_at=now(),
           admin_handler_id=p_admin, admin_review_notes=p_note, updated_at=now()
     WHERE id=p_id;
    INSERT INTO public.notifications (recipient_id, event_type, title, message, related_entity_type, related_entity_id)
      VALUES (r.fan_id,'SHOUTOUT_STATUS_UPDATE_FAN','Your shout-out is ready',
              'Your personalised shout-out video has been delivered.','shoutout',p_id);
  ELSE
    -- Sent back to the creator to redo, with the reason.
    UPDATE public.shout_out_requests
       SET status='AWAITING_PARTNER_VIDEO', admin_handler_id=p_admin,
           admin_review_notes=COALESCE(p_note,'Please resubmit the video'), updated_at=now()
     WHERE id=p_id;
    INSERT INTO public.notifications (recipient_id, event_type, title, message, related_entity_type, related_entity_id)
      VALUES (r.partner_id,'SHOUTOUT_VIDEO_NEEDED_PARTNER','Shout-out needs changes',
              COALESCE(p_note,'Your shout-out video was not accepted. Please resubmit.'),'shoutout',p_id);
  END IF;

  INSERT INTO public.audit_log (actor_id, actor_role, action, target_type, target_id, new_value)
    VALUES (p_admin,'ADMIN','DELIVER_SHOUTOUT','shoutout',p_id,
            jsonb_build_object('approved',p_approve,'note',p_note));
  RETURN jsonb_build_object('success',true,'delivered',p_approve);
END $$;

REVOKE ALL ON FUNCTION rpc_admin_deliver_shoutout(uuid,uuid,boolean,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION rpc_admin_deliver_shoutout(uuid,uuid,boolean,text) TO zudue_app;

INSERT INTO _migrations (name) VALUES ('0059_flow_corrections.sql')
  ON CONFLICT (name) DO NOTHING;

COMMIT;

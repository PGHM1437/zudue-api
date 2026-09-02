-- 0094 · Stop five notification writers from throwing on a repeat.
--
-- WHY
-- notifications_unique_active_event is a plain UNIQUE index on
--   (recipient_id, event_type, related_entity_type, related_entity_id)
-- with no WHERE clause (ported from legacy in 0065). ~33 functions write into
-- that table; most add ON CONFLICT handling, but these five do not -- so the
-- SECOND time the same key is written the INSERT raises a unique_violation,
-- unhandled, and the whole function rolls back. Each one breaks a real,
-- designed flow:
--
--   rpc_upload_shoutout            -- a creator re-uploading a CORRECTED video
--                                    hits the same (fan, SHOUTOUT_STATUS_UPDATE
--                                    _FAN, shoutout, id) key as the first
--                                    delivery -> throw -> the corrected upload
--                                    fails, shout-out stuck AWAITING_PARTNER_VIDEO.
--   rpc_request_correction        -- a fan's 2nd (paid) correction round throws.
--   rpc_admin_deliver_shoutout    -- an admin rejecting a shout-out a fan
--                                    already flagged throws.
--   rpc_admin_resolve_shoutout_report (REWORK) -- same.
--   rpc_notify_waitlist           -- a creator returns online after a fan
--                                    re-joined their waitlist -> the batch
--                                    INSERT..SELECT throws -> NO waitlisted fan
--                                    gets notified, waitlist rows never clear.
--
-- FIX
-- These five events are all *prompts* -- "your video is ready", "changes
-- needed", "a creator is available". Re-firing one SHOULD bump it back to the
-- top, which is exactly what ON CONFLICT ... DO UPDATE SET is_read=false,
-- created_at=now() does. Add the clause that was missing. No schema change,
-- no key change, no client change (GET /notifications returns only id /
-- event_type / title / message / is_read / created_at -- the entity columns
-- are server-only).
--
-- Live state: 0 shoutout_corrections and 0 waitlist rows ever, so none of this
-- has fired yet. Each fires the first time the corresponding repeat happens.

BEGIN;

-- ── rpc_notify_waitlist ──────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.rpc_notify_waitlist(p_partner uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE v_count int;
BEGIN
  PERFORM public.assert_caller(p_partner);   -- partner comes back online → triggers own fan-out; or system/admin
  INSERT INTO public.notifications (recipient_id, event_type, title, message, related_entity_type, related_entity_id)
    SELECT w.fan_id, 'PLATFORM_ANNOUNCEMENT', 'A creator is available',
           'A creator you follow is now available to book.', 'user_profile', p_partner
    FROM public.waitlist w WHERE w.partner_id=p_partner AND w.status='WAITING'
  ON CONFLICT (recipient_id, event_type, related_entity_type, related_entity_id)
  DO UPDATE SET is_read=false, created_at=now();
  GET DIAGNOSTICS v_count = ROW_COUNT;
  UPDATE public.waitlist SET status='NOTIFIED', notified_at=now()
    WHERE partner_id=p_partner AND status='WAITING';
  RETURN jsonb_build_object('success',true,'notified',v_count);
END $function$;

-- ── rpc_upload_shoutout ──────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.rpc_upload_shoutout(p_id uuid, p_video_path text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE r public.shout_out_requests; v_review_days int; v_settle_days int;
BEGIN
  SELECT * INTO r FROM public.shout_out_requests WHERE id=p_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('success',false,'error','NOT_FOUND'); END IF;
  PERFORM public.assert_caller(r.partner_id);
  IF btrim(coalesce(p_video_path,'')) = '' THEN
    RETURN jsonb_build_object('success',false,'error','LINK_REQUIRED'); END IF;

  SELECT shoutout_review_days, settlement_window_days INTO v_review_days, v_settle_days
    FROM public.platform_settings WHERE id=1;

  UPDATE public.shout_out_requests
     SET partner_video_storage_path = p_video_path,
         delivered_video_link       = p_video_path,
         partner_video_submitted_at = now(),
         delivered_at               = now(),
         status                     = 'VIDEO_DELIVERED_TO_FAN',
         fan_confirmed_at           = NULL,
         fan_confirmed_source       = NULL,
         admin_confirmed_by         = NULL,
         review_deadline_at         = now() + (v_review_days || ' days')::interval,
         settle_at                  = now() + (v_settle_days || ' days')::interval,
         updated_at                 = now()
   WHERE id=p_id AND status='AWAITING_PARTNER_VIDEO';
  IF NOT FOUND THEN RETURN jsonb_build_object('success',false,'error','INVALID_STATE'); END IF;

  -- Close every open correction round with the video that answers it.
  UPDATE public.shoutout_corrections
     SET resubmitted_at=now(), video_path=p_video_path
   WHERE shoutout_id=p_id AND resubmitted_at IS NULL;

  INSERT INTO public.notifications (recipient_id, event_type, title, message, related_entity_type, related_entity_id)
    VALUES (r.fan_id,'SHOUTOUT_STATUS_UPDATE_FAN','Your shout-out is ready',
            'Your personalised shout-out video has been delivered.','shoutout',p_id)
  ON CONFLICT (recipient_id, event_type, related_entity_type, related_entity_id)
  DO UPDATE SET is_read=false, created_at=now(), message=excluded.message;

  RETURN jsonb_build_object('success',true,'status','VIDEO_DELIVERED_TO_FAN');
END $function$;

-- ── rpc_request_correction ───────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.rpc_request_correction(p_fan uuid, p_id uuid, p_note text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE r public.shout_out_requests; v_wallet uuid; v_fee bigint;
        v_corr uuid; v_res jsonb; v_kind text;
BEGIN
  SELECT * INTO r FROM public.shout_out_requests WHERE id=p_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('success',false,'error','NOT_FOUND'); END IF;
  PERFORM public.assert_caller(p_fan);
  IF p_fan IS DISTINCT FROM r.fan_id THEN
    RETURN jsonb_build_object('success',false,'error','FAN_MISMATCH'); END IF;
  IF r.status <> 'VIDEO_DELIVERED_TO_FAN' OR r.fan_confirmed_at IS NOT NULL OR r.disputed_at IS NOT NULL THEN
    RETURN jsonb_build_object('success',false,'error','INVALID_STATE'); END IF;

  IF r.free_correction_used_at IS NULL THEN
    -- The fan's ONE free correction round.
    v_kind := 'FREE';
    UPDATE public.shout_out_requests
       SET free_correction_used_at=now(), status='AWAITING_PARTNER_VIDEO', updated_at=now()
     WHERE id=p_id;
    INSERT INTO public.shoutout_corrections (shoutout_id, kind, fee_paise, fan_note)
      VALUES (p_id, 'FREE', 0, p_note);
  ELSE
    -- Every further round is PAID. The correction row, the wallet debit and
    -- the status flip live in one exception block: if the wallet CHECK fires
    -- (insufficient balance), the subtransaction rolls back and NOTHING of
    -- this round persists — no orphan correction row, no state change.
    v_kind := 'PAID';
    SELECT shoutout_correction_fee_paise INTO v_fee FROM public.platform_settings WHERE id=1;
    SELECT id INTO v_wallet FROM public.wallets WHERE profile_id=r.fan_id;
    BEGIN
      INSERT INTO public.shoutout_corrections (shoutout_id, kind, fee_paise, fan_note)
        VALUES (p_id, 'PAID', v_fee, p_note) RETURNING id INTO v_corr;
      v_res := public.post_transaction('SHOUTOUT_DEBIT', v_fee, 'so-corr:'||v_corr::text,
        jsonb_build_array(
          jsonb_build_object('wallet_id',v_wallet,'account','wallet','delta_paise',-v_fee),
          jsonb_build_object('account','booking_escrow','delta_paise',v_fee)),
        v_corr::text);
      UPDATE public.shoutout_corrections SET fee_txn_id=(v_res->>'transaction_id')::uuid WHERE id=v_corr;
      UPDATE public.shout_out_requests SET status='AWAITING_PARTNER_VIDEO', updated_at=now() WHERE id=p_id;
    EXCEPTION WHEN check_violation THEN
      RETURN jsonb_build_object('success',false,'error','INSUFFICIENT_BALANCE');
    END;
  END IF;

  INSERT INTO public.notifications (recipient_id, event_type, title, message, related_entity_type, related_entity_id)
    VALUES (r.partner_id,'SHOUTOUT_VIDEO_NEEDED_PARTNER','Shout-out correction requested',
            COALESCE(p_note,'The fan asked for changes to this shout-out video. Please resubmit.'),'shoutout',p_id)
  ON CONFLICT (recipient_id, event_type, related_entity_type, related_entity_id)
  DO UPDATE SET is_read=false, created_at=now(), message=excluded.message;
  RETURN jsonb_build_object('success',true,'kind',v_kind);
END $function$;

-- ── rpc_admin_deliver_shoutout ───────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.rpc_admin_deliver_shoutout(p_admin uuid, p_id uuid, p_approve boolean, p_note text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE r public.shout_out_requests;
BEGIN
  PERFORM public.assert_is_admin_actor(p_admin);
  PERFORM public.assert_admin_role('SUPER_ADMIN','SUPPORT','MODERATOR');
  SELECT * INTO r FROM public.shout_out_requests WHERE id=p_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('success',false,'error','NOT_FOUND'); END IF;
  IF r.status NOT IN ('VIDEO_DELIVERED_TO_FAN','ISSUE_REPORTED_BY_FAN') OR r.fan_confirmed_at IS NOT NULL THEN
    RETURN jsonb_build_object('success',false,'error','INVALID_STATE','status',r.status); END IF;

  IF p_approve THEN
    UPDATE public.shout_out_requests
       SET fan_confirmed_at=now(), fan_confirmed_source='ADMIN', admin_confirmed_by=p_admin,
           status='VIDEO_DELIVERED_TO_FAN', admin_handler_id=p_admin,
           admin_review_notes=p_note, updated_at=now()
     WHERE id=p_id;
    UPDATE public.reports SET status='RESOLVED', resolution=p_note, resolved_by=p_admin, resolved_at=now()
      WHERE target_type='SHOUTOUT' AND target_id=p_id AND status IN ('PENDING','REVIEWING');
    INSERT INTO public.notifications (recipient_id, event_type, title, message, related_entity_type, related_entity_id)
      VALUES (r.fan_id,'SHOUTOUT_STATUS_UPDATE_FAN','Your shout-out is confirmed',
              'Your shout-out delivery has been confirmed.','shoutout',p_id)
    ON CONFLICT (recipient_id, event_type, related_entity_type, related_entity_id)
    DO UPDATE SET is_read=false, created_at=now(), title=excluded.title, message=excluded.message;
  ELSE
    UPDATE public.shout_out_requests
       SET status='AWAITING_PARTNER_VIDEO', admin_handler_id=p_admin,
           admin_review_notes=COALESCE(p_note,'Please resubmit the video'), updated_at=now()
     WHERE id=p_id;
    INSERT INTO public.notifications (recipient_id, event_type, title, message, related_entity_type, related_entity_id)
      VALUES (r.partner_id,'SHOUTOUT_VIDEO_NEEDED_PARTNER','Shout-out needs changes',
              COALESCE(p_note,'Your shout-out video was not accepted. Please resubmit.'),'shoutout',p_id)
    ON CONFLICT (recipient_id, event_type, related_entity_type, related_entity_id)
    DO UPDATE SET is_read=false, created_at=now(), title=excluded.title, message=excluded.message;
  END IF;

  INSERT INTO public.audit_log (actor_id, actor_role, action, target_type, target_id, new_value)
    VALUES (p_admin,'ADMIN','DELIVER_SHOUTOUT','shoutout',p_id,
            jsonb_build_object('approved',p_approve,'note',p_note));
  RETURN jsonb_build_object('success',true,'delivered',p_approve);
END $function$;

-- ── rpc_admin_resolve_shoutout_report ────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.rpc_admin_resolve_shoutout_report(p_admin uuid, p_shoutout uuid, p_action text, p_notes text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE r public.shout_out_requests; v_res jsonb; v_review_days int; v_settle_days int;
BEGIN
  PERFORM public.assert_is_admin_actor(p_admin);
  IF p_action = 'REFUND' THEN
    PERFORM public.assert_admin_role('FINANCE','SUPER_ADMIN');
  END IF;
  SELECT * INTO r FROM public.shout_out_requests WHERE id=p_shoutout FOR UPDATE;
  IF NOT FOUND OR r.status <> 'ISSUE_REPORTED_BY_FAN' THEN
    RETURN jsonb_build_object('success',false,'error','NOT_FLAGGED'); END IF;

  IF p_action = 'REFUND' THEN
    v_res := public.rpc_admin_cancel_shoutout(p_admin, p_shoutout, p_notes);
    IF v_res->>'success' <> 'true' THEN RETURN v_res; END IF;
    INSERT INTO public.audit_log (actor_id, actor_role, action, target_type, target_id, new_value)
      VALUES (p_admin,'ADMIN','RESOLVE_SHOUTOUT_REPORT','shout_out_request',p_shoutout, jsonb_build_object('action','REFUND'));
    RETURN jsonb_build_object('success',true,'refunded',true);
  ELSIF p_action = 'REWORK' THEN
    UPDATE public.shout_out_requests SET status='AWAITING_PARTNER_VIDEO', admin_review_notes=p_notes, updated_at=now() WHERE id=p_shoutout;
    UPDATE public.reports SET status='RESOLVED', resolution=p_notes, resolved_by=p_admin, resolved_at=now()
      WHERE target_type='SHOUTOUT' AND target_id=p_shoutout AND status IN ('PENDING','REVIEWING');
    INSERT INTO public.notifications (recipient_id, event_type, title, message, related_entity_type, related_entity_id)
      VALUES (r.partner_id, 'SHOUTOUT_VIDEO_NEEDED_PARTNER', 'Rework needed',
              COALESCE(p_notes,'Please redo this shout-out video.'), 'shoutout', p_shoutout)
    ON CONFLICT (recipient_id, event_type, related_entity_type, related_entity_id)
    DO UPDATE SET is_read=false, created_at=now(), title=excluded.title, message=excluded.message;
    INSERT INTO public.audit_log (actor_id, actor_role, action, target_type, target_id, new_value)
      VALUES (p_admin,'ADMIN','RESOLVE_SHOUTOUT_REPORT','shout_out_request',p_shoutout, jsonb_build_object('action','REWORK'));
    RETURN jsonb_build_object('success',true,'reworked',true);
  ELSIF p_action = 'DISMISS' THEN
    SELECT shoutout_review_days, settlement_window_days INTO v_review_days, v_settle_days
      FROM public.platform_settings WHERE id=1;
    UPDATE public.shout_out_requests
       SET status='VIDEO_DELIVERED_TO_FAN', admin_review_notes=p_notes,
           review_deadline_at = now() + (v_review_days || ' days')::interval,
           settle_at          = now() + (v_settle_days || ' days')::interval,
           updated_at=now()
     WHERE id=p_shoutout;
    UPDATE public.reports SET status='RESOLVED', resolution=p_notes, resolved_by=p_admin, resolved_at=now()
      WHERE target_type='SHOUTOUT' AND target_id=p_shoutout AND status IN ('PENDING','REVIEWING');
    INSERT INTO public.audit_log (actor_id, actor_role, action, target_type, target_id, new_value)
      VALUES (p_admin,'ADMIN','RESOLVE_SHOUTOUT_REPORT','shout_out_request',p_shoutout, jsonb_build_object('action','DISMISS'));
    RETURN jsonb_build_object('success',true,'dismissed',true);
  ELSE
    RETURN jsonb_build_object('success',false,'error','INVALID_ACTION');
  END IF;
END $function$;

INSERT INTO _migrations (name) VALUES ('0094_notification_hard_failures.sql') ON CONFLICT (name) DO NOTHING;

COMMIT;

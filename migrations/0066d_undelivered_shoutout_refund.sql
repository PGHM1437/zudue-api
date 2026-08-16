-- 0066d · Undelivered shoutout auto-refund.
--
-- Business rule: If partner never uploads a shoutout video by settle_at (7 days
-- from booking), fan gets a full refund automatically. Money currently stuck in
-- escrow indefinitely is now properly returned to fans.
--
-- This closes a critical gap where 1 shoutout in production is stuck in
-- AWAITING_PARTNER_VIDEO with no refund mechanism.

BEGIN;

-- Add new status for expired undelivered shoutouts
ALTER TYPE shout_out_status_enum ADD VALUE IF NOT EXISTS 'EXPIRED_PARTNER_NO_DELIVERY';

-- Create function to refund undelivered shoutouts
CREATE OR REPLACE FUNCTION public.rpc_expire_shoutout(p_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE 
  s public.shout_out_requests;
  v_wallet uuid;
  v_res jsonb;
BEGIN
  PERFORM public.assert_system();  -- settlement sweep job only
  SELECT * INTO s FROM public.shout_out_requests WHERE id=p_id FOR UPDATE;
  IF NOT FOUND THEN 
    RETURN jsonb_build_object('success',false,'error','NOT_FOUND'); 
  END IF;
  
  -- Only expire if still awaiting delivery past settle_at
  IF s.status <> 'AWAITING_PARTNER_VIDEO' OR s.settle_at > now() THEN
    RETURN jsonb_build_object('success',false,'error','NOT_EXPIRABLE'); 
  END IF;

  -- Idempotency check - if already refunded, exit cleanly
  IF EXISTS (
    SELECT 1 FROM public.transactions t
    WHERE t.idempotency_key = 'so-expire:' || s.id::text
  ) THEN
    RETURN jsonb_build_object('success',true,'already_refunded',true);
  END IF;

  -- Full refund to fan
  SELECT id INTO v_wallet FROM public.wallets WHERE profile_id=s.fan_id;
  IF v_wallet IS NULL THEN
    RAISE EXCEPTION 'Wallet not found for fan %', s.fan_id;
  END IF;

  v_res := public.post_transaction('REFUND', s.price_paise, 'so-expire:'||s.id::text,
    jsonb_build_array(
      jsonb_build_object('account','booking_escrow','delta_paise',-s.price_paise),
      jsonb_build_object('wallet_id',v_wallet,'account','wallet','delta_paise',s.price_paise)),
    s.id::text);

  UPDATE public.shout_out_requests
     SET status='EXPIRED_PARTNER_NO_DELIVERY', updated_at=now()
   WHERE id=p_id;

  -- Notify fan of refund
  INSERT INTO public.notifications (recipient_id, event_type, title, message, related_entity_type, related_entity_id)
    VALUES (s.fan_id,'REFUND_PROCESSED_FAN','Shout-out refunded',
            'Your shout-out request was not delivered and has been refunded to your wallet.','shoutout',p_id);

  RETURN jsonb_build_object('success',true,'refunded_paise',s.price_paise,'transaction_id',v_res->>'transaction_id');
END $function$;

-- Add index to support the expiry query efficiently
-- WHERE status='AWAITING_PARTNER_VIDEO' AND settle_at <= now()
CREATE INDEX IF NOT EXISTS shoutout_expire_due_idx 
  ON public.shout_out_requests (settle_at)
  WHERE status = 'AWAITING_PARTNER_VIDEO';

-- Grant execute permissions
REVOKE ALL ON FUNCTION rpc_expire_shoutout(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION rpc_expire_shoutout(uuid) TO zudue_app;

INSERT INTO _migrations (name) VALUES ('0066d_undelivered_shoutout_refund.sql')
  ON CONFLICT (name) DO NOTHING;

COMMIT;

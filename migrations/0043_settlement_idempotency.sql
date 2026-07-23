-- 0043 · Make settlement idempotent in the DATABASE, not just in the caller.
--
-- Found while testing 0042. Calling rpc_settle_booking three times on one
-- booking produces ONE ledger transaction (post_transaction dedupes on
-- idempotency_key) but THREE partner_earnings rows. rpc_create_payout_batch
-- sums PENDING_PAYOUT earnings, so the creator would be paid 3x for a single
-- call — against escrow that only ever received 1x. Reproduced:
--   settle x3 -> transactions: 1, partner_earnings: 3 rows / 300000 paise
--
-- Why it has not fired: the settle job's SELECT carries a
--   NOT EXISTS (SELECT 1 FROM partner_earnings WHERE service_id = ...)
-- guard, so the normal scheduled path is protected. But that guard lives in
-- the CALLER. The worker runs concurrency 4 and (correctly) settles each item
-- in its own transaction, so two overlapping runs can both pass that SELECT
-- before either COMMITs its insert — a plain TOCTOU race. Any other caller
-- (ops tooling, a manual retry, a future endpoint) has no protection at all.
--
-- This is exactly the invariant the architecture claims: "money never moves
-- outside a DB RPC; the database guarantees idempotency." For settlement the
-- database did not guarantee it — the job did. Note rpc_settle_shoutout (0036)
-- already had the internal guard; booking and window were the inconsistent two.
--
-- Two layers, deliberately:
--   1. UNIQUE (service_id) on partner_earnings — one service, one earning, as
--      a schema fact no code path can bypass. service_id is NOT NULL and every
--      insert supplies it, so this is semantically exact. Verified: zero
--      existing duplicates on both databases.
--   2. An EXISTS early-return inside each RPC — so a legitimate replay returns
--      {success:true, already_settled:true} rather than raising a constraint
--      violation the caller has to interpret. The SELECT ... FOR UPDATE at the
--      top of each function serialises concurrent settles of the same row, so
--      the second caller observes the first's committed insert.

BEGIN;

ALTER TABLE public.partner_earnings
  ADD CONSTRAINT partner_earnings_service_uq UNIQUE (service_id);

CREATE OR REPLACE FUNCTION public.rpc_settle_booking(p_booking uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE b public.bookings; v_res jsonb; v_gross bigint;
BEGIN
  PERFORM public.assert_system();   -- settlement sweep job / admin only
  SELECT * INTO b FROM public.bookings WHERE id=p_booking FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('success',false,'error','NOT_FOUND'); END IF;

  -- Idempotency (0043): the row lock above serialises concurrent settles of
  -- this booking, so a replay sees the committed earning and exits cleanly.
  IF EXISTS (SELECT 1 FROM public.partner_earnings e WHERE e.service_id = p_booking) THEN
    RETURN jsonb_build_object('success',true,'already_settled',true); END IF;

  -- Escrow holds the list price; the creator is settled that, not the
  -- discounted amount the fan paid. COALESCE guards rows predating 0042.
  v_gross := COALESCE(b.original_price_paise, b.price_paise);

  v_res := public.post_transaction('PARTNER_EARNING', v_gross, 'settle:'||b.id::text,
    jsonb_build_array(
      jsonb_build_object('account','booking_escrow','delta_paise',-v_gross),
      jsonb_build_object('account','partner_payable','delta_paise',v_gross)),
    b.id::text);

  INSERT INTO public.partner_earnings (partner_id, transaction_id, service_type, service_id, amount_paise)
  VALUES (b.partner_id, (v_res->>'transaction_id')::uuid, 'VIDEO_CALL', b.id, v_gross);

  RETURN jsonb_build_object('success',true,'transaction_id',v_res->>'transaction_id');
END $function$;

CREATE OR REPLACE FUNCTION public.rpc_settle_window(p_window uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE w public.conversation_windows; v_partner uuid; v_res jsonb;
BEGIN
  PERFORM public.assert_system();
  SELECT * INTO w FROM public.conversation_windows WHERE id=p_window FOR UPDATE;
  IF NOT FOUND OR w.kind<>'PAID' OR w.charge_paise=0 THEN
    RETURN jsonb_build_object('success',false,'error','NOT_SETTLEABLE'); END IF;

  -- Idempotency (0043) — see rpc_settle_booking.
  IF EXISTS (SELECT 1 FROM public.partner_earnings e WHERE e.service_id = p_window) THEN
    RETURN jsonb_build_object('success',true,'already_settled',true); END IF;

  SELECT partner_id INTO v_partner FROM public.conversations WHERE id=w.conversation_id;

  v_res := public.post_transaction('PARTNER_EARNING', w.charge_paise, 'settlewin:'||w.id::text,
    jsonb_build_array(
      jsonb_build_object('account','booking_escrow','delta_paise',-w.charge_paise),
      jsonb_build_object('account','partner_payable','delta_paise',w.charge_paise)),
    w.id::text);
  INSERT INTO public.partner_earnings (partner_id, transaction_id, service_type, service_id, amount_paise)
    VALUES (v_partner, (v_res->>'transaction_id')::uuid, 'QUICK_QUESTION', w.id, w.charge_paise);
  RETURN jsonb_build_object('success',true,'transaction_id',v_res->>'transaction_id');
END $function$;

DO $$
DECLARE v_dupes text;
BEGIN
  SELECT string_agg(DISTINCT p.proname, ', ') INTO v_dupes
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname LIKE 'rpc_%'
  GROUP BY p.proname HAVING count(*) > 1;
  IF v_dupes IS NOT NULL THEN
    RAISE EXCEPTION 'Duplicate RPC overloads detected (fix before deploy): %', v_dupes;
  END IF;
END $$;

COMMIT;

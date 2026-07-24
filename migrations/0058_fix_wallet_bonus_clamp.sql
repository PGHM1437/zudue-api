-- 0058 · Fix: spending violated wallet_bonus_bounds, blocking all debits.
--
-- The funded test wallet had bonus_balance_paise = balance_paise. The
-- constraint requires bonus <= balance. post_transaction moved balance down on
-- a debit but left bonus unchanged, so the first spend made bonus > balance and
-- the CHECK aborted the whole transaction. Every booking, question and
-- shout-out for ANY wallet holding a bonus therefore 500'd with:
--     new row for relation "wallets" violates check constraint "wallet_bonus_bounds"
-- Reproduced directly against prod.
--
-- Bonus is a sub-accounting tag of balance, not a separate pot — the real money
-- is `balance_paise`, tracked by the double-entry ledger. Clamping bonus to the
-- new balance on every wallet write keeps the invariant without touching the
-- ledger, so settlement/escrow/earnings are unaffected. This recreates
-- post_transaction from the live definition with only that one line changed.

BEGIN;

CREATE OR REPLACE FUNCTION public.post_transaction(p_type txn_type, p_amount_paise bigint, p_idempotency_key text, p_legs jsonb, p_external_ref text DEFAULT NULL::text, p_meta jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_existing uuid;
  v_txn_id   uuid;
  v_leg      jsonb;
  v_sum      bigint := 0;
  v_wallet   uuid;
BEGIN
  -- Validate legs: array, integer paise, balanced.
  IF p_legs IS NULL OR jsonb_typeof(p_legs) <> 'array' OR jsonb_array_length(p_legs) < 2 THEN
    RAISE EXCEPTION 'post_transaction: p_legs must be an array of >= 2 legs';
  END IF;
  FOR v_leg IN SELECT * FROM jsonb_array_elements(p_legs) LOOP
    v_sum := v_sum + (v_leg->>'delta_paise')::bigint;
  END LOOP;
  IF v_sum <> 0 THEN
    RAISE EXCEPTION 'post_transaction: legs must sum to 0, got %', v_sum;
  END IF;
  IF p_amount_paise IS NULL OR p_amount_paise <= 0 THEN
    RAISE EXCEPTION 'post_transaction: amount_paise must be positive';
  END IF;

  -- Idempotency: replay returns the original, applies nothing.
  SELECT id INTO v_existing FROM public.transactions
   WHERE idempotency_key = p_idempotency_key;
  IF v_existing IS NOT NULL THEN
    RETURN jsonb_build_object('transaction_id', v_existing, 'replayed', true);
  END IF;

  -- Lock wallets in deterministic (sorted) order to avoid deadlocks.
  FOR v_wallet IN
    SELECT DISTINCT (l->>'wallet_id')::uuid
      FROM jsonb_array_elements(p_legs) l
     WHERE l->>'wallet_id' IS NOT NULL
     ORDER BY 1
  LOOP
    PERFORM 1 FROM public.wallets WHERE id = v_wallet FOR UPDATE;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'post_transaction: wallet % not found', v_wallet;
    END IF;
  END LOOP;

  -- Concurrency-safe idempotency: if two calls race past the SELECT above, the
  -- unique constraint wins here — catch it and return the original cleanly.
  BEGIN
    INSERT INTO public.transactions (type, status, amount_paise, idempotency_key, external_ref, meta)
    VALUES (p_type, 'SUCCESSFUL', p_amount_paise, p_idempotency_key, p_external_ref, p_meta)
    RETURNING id INTO v_txn_id;
  EXCEPTION WHEN unique_violation THEN
    SELECT id INTO v_existing FROM public.transactions
     WHERE idempotency_key = p_idempotency_key;
    RETURN jsonb_build_object('transaction_id', v_existing, 'replayed', true);
  END;

  FOR v_leg IN SELECT * FROM jsonb_array_elements(p_legs) LOOP
    INSERT INTO public.ledger_entries (transaction_id, wallet_id, account, delta_paise)
    VALUES (
      v_txn_id,
      (v_leg->>'wallet_id')::uuid,
      v_leg->>'account',
      (v_leg->>'delta_paise')::bigint
    );

    IF v_leg->>'wallet_id' IS NOT NULL THEN
      -- Move cached balance (+ optional bonus-bucket movement). The table
      -- CHECKs are the hard backstop: negative balance or bonus > balance
      -- aborts the whole transaction.
      -- Clamp the bonus bucket to the NEW balance. Bonus is a sub-tag of
      -- balance (how much is promotional), never a second pot of money, so it
      -- can never exceed balance. Debits (booking, question, shout-out) reduce
      -- balance but carry no bonus_delta, so without this clamp any wallet
      -- holding bonus violates wallet_bonus_bounds on its first spend and the
      -- whole transaction aborts — which 500'd every booking/question/shout-out
      -- for a funded wallet. The ledger (delta_paise) is untouched, so
      -- double-entry integrity is unchanged; only the cached bonus tag moves.
      UPDATE public.wallets
         SET balance_paise       = balance_paise + (v_leg->>'delta_paise')::bigint,
             bonus_balance_paise = GREATEST(0, LEAST(
                                     bonus_balance_paise + COALESCE((v_leg->>'bonus_delta_paise')::bigint, 0),
                                     balance_paise + (v_leg->>'delta_paise')::bigint)),
             updated_at          = now()
       WHERE id = (v_leg->>'wallet_id')::uuid;
    END IF;
  END LOOP;

  RETURN jsonb_build_object('transaction_id', v_txn_id, 'replayed', false);
END $function$;

INSERT INTO _migrations (name) VALUES ('0058_fix_wallet_bonus_clamp.sql')
  ON CONFLICT (name) DO NOTHING;

COMMIT;

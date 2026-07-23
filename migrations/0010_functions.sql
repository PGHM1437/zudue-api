-- 0010 · The handful of retained DB functions. All SECURITY DEFINER functions
-- pin search_path (the audit found 50 that didn't). Business logic lives in the
-- NestJS layer; these are only auth/RLS helpers + a generic timestamp trigger.
-- The API sets `SET LOCAL app.user_id = '<uuid>'` per request; RLS reads it.

BEGIN;

-- Current authenticated profile id (from the per-request GUC the API sets).
CREATE OR REPLACE FUNCTION current_user_id()
RETURNS uuid LANGUAGE sql STABLE SET search_path = '' AS $$
  SELECT NULLIF(current_setting('app.user_id', true), '')::uuid
$$;

-- Is the current user an admin? Used by RLS policies (search_path pinned).
CREATE OR REPLACE FUNCTION is_admin()
RETURNS boolean LANGUAGE sql STABLE SET search_path = '' AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.profiles
    WHERE id = public.current_user_id() AND role = 'ADMIN'
  )
$$;

-- Owns this partner profile?
CREATE OR REPLACE FUNCTION is_partner(p_partner_id uuid)
RETURNS boolean LANGUAGE sql STABLE SET search_path = '' AS $$
  SELECT p_partner_id = public.current_user_id()
$$;

-- Generic updated_at trigger (used sparingly; most timestamps set in the app).
CREATE OR REPLACE FUNCTION set_updated_at()
RETURNS trigger LANGUAGE plpgsql SET search_path = '' AS $$
BEGIN
  NEW.updated_at := now();
  RETURN NEW;
END $$;

-- ─────────────────────────────────────────────────────────────────────────
-- post_transaction — THE atomic money primitive (see DELEGATION_AND_SCALE.md).
-- The backend decides WHICH posting to make; this function guarantees it is
-- applied atomically, idempotently, balanced, and within wallet constraints.
--
--   p_legs: jsonb array of {wallet_id?, account, delta_paise, bonus_delta_paise?}
--   Returns {transaction_id, replayed}.
--
-- Guarantees (all enforced here or by table constraints):
--   • idempotent: same p_idempotency_key → returns original txn, applies nothing
--   • balanced:   SUM(delta_paise) must equal 0 (also backstopped by the
--                 deferred ledger_balanced_check trigger)
--   • locked:     wallet rows locked in deterministic order (no deadlocks)
--   • bounded:    wallet CHECKs reject negative balance / bonus > balance
-- ─────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION post_transaction(
  p_type            txn_type,
  p_amount_paise    bigint,
  p_idempotency_key text,
  p_legs            jsonb,
  p_external_ref    text DEFAULT NULL,
  p_meta            jsonb DEFAULT '{}'
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
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
      UPDATE public.wallets
         SET balance_paise       = balance_paise + (v_leg->>'delta_paise')::bigint,
             bonus_balance_paise = bonus_balance_paise
                                   + COALESCE((v_leg->>'bonus_delta_paise')::bigint, 0),
             updated_at          = now()
       WHERE id = (v_leg->>'wallet_id')::uuid;
    END IF;
  END LOOP;

  RETURN jsonb_build_object('transaction_id', v_txn_id, 'replayed', false);
END $$;

-- Only the API's role may execute the money primitive.
REVOKE ALL ON FUNCTION post_transaction(txn_type, bigint, text, jsonb, text, jsonb) FROM PUBLIC;

COMMIT;

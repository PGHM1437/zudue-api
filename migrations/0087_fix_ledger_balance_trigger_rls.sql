-- assert_ledger_balanced() is an integrity check: it must see EVERY leg of a
-- transaction to verify they sum to zero. It was not SECURITY DEFINER, so it
-- re-read ledger_entries as whoever triggered the insert — and it fires from a
-- DEFERRABLE INITIALLY DEFERRED constraint trigger, i.e. at COMMIT, outside
-- post_transaction's own SECURITY DEFINER context.
--
-- Under RLS that is fatal. ledger_owner_read only exposes rows matching
--   wallet_id IN (SELECT id FROM wallets WHERE profile_id = current_user_id())
-- and every non-wallet leg (booking_escrow, partner_payable, gst_payable,
-- razorpay_clearing, promo_incentive) carries wallet_id IS NULL. `NULL IN (…)`
-- is NULL, never true, so those legs are invisible to the check. The trigger
-- summed the fan's debit leg alone and aborted every money movement with
-- "Ledger unbalanced … sum=-<price>": bookings, shout-outs, questions, top-ups.
--
-- This never fired on Supabase because the API connected through the pooler as
-- the `postgres` superuser, which bypasses RLS — the trigger saw all legs. On
-- self-hosted Postgres the API connects as least-privilege zudue_app with RLS
-- genuinely enforced, which surfaced the latent bug rather than causing it.
--
-- SECURITY DEFINER pins the read to the function owner (zudue_owner, BYPASSRLS)
-- so the invariant is evaluated against the true ledger, independent of who is
-- committing. Widening the RLS policy instead would be wrong: it would expose
-- platform-account movements to end users to satisfy an internal check.
CREATE OR REPLACE FUNCTION public.assert_ledger_balanced()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE v_sum bigint;
BEGIN
  SELECT COALESCE(SUM(delta_paise), 0) INTO v_sum
  FROM public.ledger_entries WHERE transaction_id = NEW.transaction_id;
  IF v_sum <> 0 THEN
    RAISE EXCEPTION 'Ledger unbalanced for transaction %: sum=%', NEW.transaction_id, v_sum;
  END IF;
  RETURN NULL;
END $$;

-- SECURITY DEFINER functions are executable by PUBLIC by default; this one is
-- only ever reached through the trigger, but revoke the direct-call path anyway
-- so it cannot be invoked as the owner from an ordinary session.
REVOKE ALL ON FUNCTION public.assert_ledger_balanced() FROM PUBLIC;

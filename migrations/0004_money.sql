-- 0004 · Money core (PAISE) — mirrors apps/api/src/db/schema/money.ts + MONEY_MODEL.md
-- Escrow model: recharge(+GST) → wallet credits → book(held) → settle(day7, full
-- to creator) → monthly payout. No in-app commission/TDS deduction (offline).
-- Credit buckets: PAID (GST paid, bank-refundable) vs BONUS (referral/promo).

BEGIN;

-- ── Fan wallet (total + bonus bucket) ───────────────────────────────────
CREATE TABLE wallets (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  profile_id         uuid NOT NULL UNIQUE REFERENCES profiles(id) ON DELETE CASCADE, -- fan
  balance_paise      bigint NOT NULL DEFAULT 0,          -- total shown to user
  bonus_balance_paise bigint NOT NULL DEFAULT 0,         -- referral/promo (no GST, spent first)
  created_at         timestamptz NOT NULL DEFAULT now(),
  updated_at         timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT wallet_non_negative CHECK (balance_paise >= 0),
  CONSTRAINT wallet_bonus_bounds CHECK (bonus_balance_paise >= 0 AND bonus_balance_paise <= balance_paise)
);

-- ── One logical money event, idempotency-keyed ──────────────────────────
CREATE TABLE transactions (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  type            txn_type NOT NULL,
  status          txn_status NOT NULL DEFAULT 'PENDING',
  amount_paise    bigint NOT NULL,
  idempotency_key text NOT NULL,
  external_ref    text,
  meta            jsonb NOT NULL DEFAULT '{}',
  created_at      timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT txn_amount_positive CHECK (amount_paise > 0),
  CONSTRAINT txn_idempotency_key_uq UNIQUE (idempotency_key)
);
CREATE INDEX txn_external_ref_idx ON transactions (external_ref);

-- ── Double-entry ledger; legs per txn MUST sum to zero ──────────────────
-- Accounts: wallet · gst_payable · booking_escrow · partner_payable · razorpay_clearing
CREATE TABLE ledger_entries (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  transaction_id uuid NOT NULL REFERENCES transactions(id),
  wallet_id      uuid REFERENCES wallets(id),
  account        text NOT NULL,
  delta_paise    bigint NOT NULL,
  created_at     timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ledger_txn_idx    ON ledger_entries (transaction_id);
CREATE INDEX ledger_wallet_idx ON ledger_entries (wallet_id);

CREATE OR REPLACE FUNCTION assert_ledger_balanced()
RETURNS trigger LANGUAGE plpgsql SET search_path = '' AS $$
DECLARE v_sum bigint;
BEGIN
  SELECT COALESCE(SUM(delta_paise), 0) INTO v_sum
  FROM public.ledger_entries WHERE transaction_id = NEW.transaction_id;
  IF v_sum <> 0 THEN
    RAISE EXCEPTION 'Ledger unbalanced for transaction %: sum=%', NEW.transaction_id, v_sum;
  END IF;
  RETURN NULL;
END $$;

CREATE CONSTRAINT TRIGGER ledger_balanced_check
  AFTER INSERT ON ledger_entries
  DEFERRABLE INITIALLY DEFERRED
  FOR EACH ROW EXECUTE FUNCTION assert_ledger_balanced();

-- ── Razorpay top-up: credits + GST collected at recharge ────────────────
CREATE TABLE topup_orders (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  profile_id          uuid NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  credit_paise        bigint NOT NULL,        -- wallet credits the fan receives
  gst_paise           bigint NOT NULL DEFAULT 0,
  amount_paise        bigint NOT NULL,        -- total charged = credit + gst
  razorpay_order_id   text NOT NULL UNIQUE,
  razorpay_payment_id text,
  status              txn_status NOT NULL DEFAULT 'PENDING',
  transaction_id      uuid REFERENCES transactions(id),
  error_message       text,
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT topup_credit_positive CHECK (credit_paise > 0),
  CONSTRAINT topup_amount_consistent CHECK (amount_paise = credit_paise + gst_paise)
);
CREATE INDEX topup_profile_idx ON topup_orders (profile_id);

-- ── Partner earnings (created at day-7 settlement; FULL amount owed) ─────
-- Commission is NOT attached to any service. It is a partner-level rate
-- (partner_profiles.commission_rate) settled OFFLINE at payout per agreement.
CREATE TABLE partner_earnings (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  partner_id      uuid NOT NULL REFERENCES partner_profiles(profile_id) ON DELETE CASCADE,
  transaction_id  uuid NOT NULL REFERENCES transactions(id),
  service_type    service_type_enum NOT NULL,
  service_id      uuid NOT NULL,
  amount_paise    bigint NOT NULL,            -- full amount owed to the creator
  status          earning_status NOT NULL DEFAULT 'PENDING_PAYOUT',
  payout_id       uuid,
  settled_at      timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT earning_amount_positive CHECK (amount_paise >= 0)
);
CREATE INDEX earning_partner_idx ON partner_earnings (partner_id);
CREATE INDEX earning_status_idx  ON partner_earnings (status) WHERE status = 'PENDING_PAYOUT';

-- ── Payout destinations (single home) ───────────────────────────────────
CREATE TABLE payout_methods (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  partner_id          uuid NOT NULL REFERENCES partner_profiles(profile_id) ON DELETE CASCADE,
  method_type         payout_method_type NOT NULL,
  account_holder_name text, account_number text, ifsc_code text, bank_name text, upi_id text,
  is_primary          boolean NOT NULL DEFAULT false,
  is_verified         boolean NOT NULL DEFAULT false,
  verified_by_admin_id uuid, verified_at timestamptz,
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX payout_methods_partner_idx ON payout_methods (partner_id);
CREATE UNIQUE INDEX payout_methods_one_primary ON payout_methods (partner_id) WHERE is_primary;

-- ── Monthly payout batch (drains settled earnings to bank) ──────────────
CREATE TABLE partner_payouts (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  partner_id       uuid NOT NULL REFERENCES partner_profiles(profile_id) ON DELETE CASCADE,
  amount_paise     bigint NOT NULL,
  status           payout_status NOT NULL DEFAULT 'REQUESTED',
  payout_method_id uuid REFERENCES payout_methods(id),
  transaction_id   uuid REFERENCES transactions(id),
  reference        text,
  requested_at     timestamptz NOT NULL DEFAULT now(),
  processed_at     timestamptz,
  CONSTRAINT payout_amount_positive CHECK (amount_paise > 0)
);
CREATE INDEX payout_partner_idx ON partner_payouts (partner_id);

ALTER TABLE partner_earnings
  ADD CONSTRAINT earning_payout_fk FOREIGN KEY (payout_id) REFERENCES partner_payouts(id);

COMMIT;

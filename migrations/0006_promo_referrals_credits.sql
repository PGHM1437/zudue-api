-- 0006 · Promo codes, referrals, and BONUS credit grants
-- Promo discounts are platform-funded; referral rewards are BONUS credits.

BEGIN;

CREATE TYPE credit_source AS ENUM ('PAID', 'REFERRAL', 'PROMO', 'GOODWILL', 'REFUND');

CREATE TABLE promo_codes (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  code               text NOT NULL UNIQUE,
  description        text,
  discount_type      promo_code_discount_type_enum NOT NULL,
  discount_value     numeric NOT NULL,                       -- % or fixed paise
  applies_to         promo_code_service_applicability_enum NOT NULL DEFAULT 'ALL',
  max_uses_total     integer,
  max_uses_per_user  integer,
  current_total_uses integer NOT NULL DEFAULT 0,
  min_booking_paise  bigint NOT NULL DEFAULT 0,
  start_date         timestamptz,
  expiry_date        timestamptz,
  is_active          boolean NOT NULL DEFAULT true,
  created_by_admin_id uuid,
  created_at         timestamptz NOT NULL DEFAULT now(),
  updated_at         timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX promo_codes_active_idx ON promo_codes (code) WHERE is_active;

CREATE TABLE promo_code_usages (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  promo_code_id  uuid NOT NULL REFERENCES promo_codes(id),
  fan_id         uuid NOT NULL REFERENCES profiles(id),
  transaction_id uuid REFERENCES transactions(id),
  discount_paise bigint NOT NULL,
  used_at        timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX promo_usage_code_idx ON promo_code_usages (promo_code_id);
CREATE INDEX promo_usage_fan_idx  ON promo_code_usages (fan_id);

CREATE TABLE referrals (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  referrer_id        uuid NOT NULL REFERENCES profiles(id),
  referee_id         uuid NOT NULL REFERENCES profiles(id),
  code_used          text NOT NULL,
  status             referral_status_enum NOT NULL DEFAULT 'PENDING_REFEREE_SIGNUP',
  referrer_reward_paise bigint,
  referee_reward_paise  bigint,
  referrer_credited_at  timestamptz,
  referee_credited_at   timestamptz,
  created_at         timestamptz NOT NULL DEFAULT now(),
  updated_at         timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT referral_pair_uq UNIQUE (referee_id)          -- one referrer per referee
);
CREATE INDEX referral_referrer_idx ON referrals (referrer_id);

-- Audit trail for every BONUS credit issued (referral/promo/goodwill).
CREATE TABLE credit_grants (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  profile_id     uuid NOT NULL REFERENCES profiles(id),
  source         credit_source NOT NULL,
  amount_paise   bigint NOT NULL,
  transaction_id uuid REFERENCES transactions(id),
  reference      text,                                      -- referral id / promo id / admin note
  created_at     timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT credit_grant_positive CHECK (amount_paise > 0)
);
CREATE INDEX credit_grant_profile_idx ON credit_grants (profile_id);

-- bookings.promo_code_id was created in 0005 before promo_codes existed — wire it now.
ALTER TABLE bookings
  ADD CONSTRAINT bookings_promo_code_fk FOREIGN KEY (promo_code_id) REFERENCES promo_codes(id);

COMMIT;

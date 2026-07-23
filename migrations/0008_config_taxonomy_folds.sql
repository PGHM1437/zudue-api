-- 0008 · Platform config, discovery taxonomy, and folded-in columns.
-- Admin data lives in admin_profiles (0002, kept SEPARATE). Here we fold only
-- the truly-universal notification prefs onto profiles, and commission_rate
-- (partner-only) onto partner_profiles. (admin_role enum is in 0001.)

BEGIN;

-- Singleton config row (enforced id = 1). Amounts in PAISE.
CREATE TABLE platform_settings (
  id                       integer PRIMARY KEY DEFAULT 1,
  -- wallet bounds
  min_wallet_topup_paise   bigint NOT NULL DEFAULT 10000,   -- ₹100
  max_wallet_topup_paise   bigint NOT NULL DEFAULT 10000000,
  max_wallet_balance_paise bigint NOT NULL DEFAULT 50000000,
  min_withdrawal_paise     bigint NOT NULL DEFAULT 100000,
  -- tax (reference; GST charged at recharge)
  gst_rate                 numeric(5,4) NOT NULL DEFAULT 0.18,
  tds_rate                 numeric(5,4) NOT NULL DEFAULT 0.01,
  default_commission_rate  numeric(5,4) NOT NULL DEFAULT 0.20, -- reference default
  -- timing
  booking_lead_days        integer NOT NULL DEFAULT 3,
  availability_lead_days   integer NOT NULL DEFAULT 7,
  settlement_window_days   integer NOT NULL DEFAULT 7,       -- universal refund/settle window
  question_sla_hours       integer NOT NULL DEFAULT 48,
  shoutout_sla_business_days integer NOT NULL DEFAULT 5,
  call_operational_start_hour_ist integer NOT NULL DEFAULT 8,
  call_operational_end_hour_ist   integer NOT NULL DEFAULT 18,
  payout_day_of_month      integer NOT NULL DEFAULT 5,
  -- durations as a config allow-list (minutes) — not a rigid enum
  call_durations_minutes   integer[] NOT NULL DEFAULT ARRAY[1,2,3,5,7,9,12,15],
  -- referral
  referral_referrer_reward_paise bigint NOT NULL DEFAULT 5000,
  referral_referee_reward_paise  bigint NOT NULL DEFAULT 5000,
  is_referral_program_active boolean NOT NULL DEFAULT true,
  -- limits & templates
  content_limits           jsonb NOT NULL DEFAULT '{"partner_bio_max_chars":150,"call_fan_note_max_chars":60,"question_text_max_chars":300,"question_answer_max_chars":500,"shoutout_message_max_chars":200}',
  notification_templates   jsonb NOT NULL DEFAULT '{}',
  updated_at               timestamptz NOT NULL DEFAULT now(),
  last_updated_by_admin_id uuid,
  CONSTRAINT platform_settings_singleton CHECK (id = 1)
);
INSERT INTO platform_settings (id) VALUES (1);

-- Universal notification prefs — ONE home for all roles (was duplicated on
-- profiles + partner_profiles; the partner copy was removed in 0002).
ALTER TABLE profiles
  ADD COLUMN notification_prefs jsonb NOT NULL DEFAULT '{"push":true,"email":true,"in_app":true}';
-- Partner-only reference commission rate (offline settlement).
ALTER TABLE partner_profiles
  ADD COLUMN commission_rate    numeric(5,4);

-- Discovery taxonomy (structured categories + free tags).
CREATE TABLE categories (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  slug       text NOT NULL UNIQUE,
  name       text NOT NULL,
  sort_order integer NOT NULL DEFAULT 0,
  is_active  boolean NOT NULL DEFAULT true
);

CREATE TABLE partner_categories (
  partner_id  uuid NOT NULL REFERENCES partner_profiles(profile_id) ON DELETE CASCADE,
  category_id uuid NOT NULL REFERENCES categories(id) ON DELETE CASCADE,
  PRIMARY KEY (partner_id, category_id)
);

CREATE TABLE partner_tags (
  partner_id uuid NOT NULL REFERENCES partner_profiles(profile_id) ON DELETE CASCADE,
  tag        text NOT NULL,
  PRIMARY KEY (partner_id, tag)
);
CREATE INDEX partner_tags_tag_idx ON partner_tags (tag);

COMMIT;

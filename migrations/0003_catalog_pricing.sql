-- 0003 · Catalog & pricing
-- Consolidation applied: partner_pricing + partner_service_settings → ONE
-- partner_services table (video-call rows carry a duration; question/shout-out
-- rows have duration NULL). Prices in PAISE.

BEGIN;

-- Unified per-partner service catalog + pricing.
CREATE TABLE partner_services (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  partner_id    uuid NOT NULL REFERENCES partner_profiles(profile_id) ON DELETE CASCADE,
  service_type  service_type_enum NOT NULL,
  duration      call_duration_options_enum,        -- NULL for QUICK_QUESTION / SHOUT_OUT
  price_paise   bigint NOT NULL,
  is_active     boolean NOT NULL DEFAULT true,      -- partner offers it
  is_available_for_platform boolean NOT NULL DEFAULT true, -- admin gate
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT partner_services_price_positive CHECK (price_paise > 0),
  -- video calls must have a duration; the others must not
  CONSTRAINT partner_services_duration_shape CHECK (
    (service_type = 'VIDEO_CALL' AND duration IS NOT NULL) OR
    (service_type <> 'VIDEO_CALL' AND duration IS NULL)),
  CONSTRAINT partner_services_unique UNIQUE (partner_id, service_type, duration)
);
CREATE INDEX partner_services_partner_idx ON partner_services (partner_id) WHERE is_active;

-- Approved-before-public social links.
CREATE TABLE partner_social_links (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  partner_id         uuid NOT NULL REFERENCES partner_profiles(profile_id) ON DELETE CASCADE,
  platform           social_platform_enum NOT NULL,
  url                text NOT NULL,
  is_approved        boolean NOT NULL DEFAULT false,
  approved_by_admin_id uuid,
  created_at         timestamptz NOT NULL DEFAULT now(),
  updated_at         timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT partner_social_links_unique UNIQUE (partner_id, platform)
);
CREATE INDEX partner_social_links_partner_idx ON partner_social_links (partner_id);

-- Minutes-based daily availability (rolling window).
CREATE TABLE availability (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  partner_id         uuid NOT NULL REFERENCES partner_profiles(profile_id) ON DELETE CASCADE,
  date               date NOT NULL,
  is_available       boolean NOT NULL DEFAULT false,
  threshold_minutes  integer NOT NULL DEFAULT 0,     -- minutes the partner opens
  booked_minutes     integer NOT NULL DEFAULT 0,     -- minutes already booked
  created_at         timestamptz NOT NULL DEFAULT now(),
  updated_at         timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT availability_unique UNIQUE (partner_id, date),
  CONSTRAINT availability_minutes_nonneg CHECK (booked_minutes >= 0 AND threshold_minutes >= 0)
);
CREATE INDEX availability_partner_date_idx ON availability (partner_id, date);

-- Featured placement: is_featured flag lives on partner_profiles (0002); here we
-- add who/when/why for the audit of a featuring action:
ALTER TABLE partner_profiles
  ADD COLUMN featured_at       timestamptz,
  ADD COLUMN featured_by_admin_id uuid,
  ADD COLUMN featured_reason   text;

COMMIT;

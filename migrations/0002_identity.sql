-- 0002 · Identity: profiles, partner/admin profiles, KYC, applications
-- Consolidation applied: payout bank details REMOVED from profiles (single home
-- is payout_methods, migration 0004). `is_minor` kept as a generated column.

BEGIN;

-- Core profile. id mirrors the auth user id (managed auth).
CREATE TABLE profiles (
  id                   uuid PRIMARY KEY,                    -- = auth.users.id
  role                 user_role NOT NULL,
  email                text NOT NULL,
  full_name            text,
  mobile_number        text,
  mobile_verified_at   timestamptz,
  age                  integer,
  gender               gender_enum,
  is_minor             boolean GENERATED ALWAYS AS (age IS NOT NULL AND age < 18) STORED,
  guardian_full_name   text,
  guardian_relationship text,
  guardian_contact_details text,
  -- KYC
  verification_status  verification_status NOT NULL DEFAULT 'NOT_SUBMITTED',
  kyc_submitted_at     timestamptz,
  kyc_verified_at      timestamptz,
  kyc_verified_by_admin_id uuid,
  kyc_rejection_reason text,
  -- Universal only. Partner flags live on partner_profiles; admin data on
  -- admin_profiles. No role-specific columns pollute this base identity table.
  referral_code        text UNIQUE,
  created_at           timestamptz NOT NULL DEFAULT now(),
  updated_at           timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT profiles_email_lower_uq UNIQUE (email)
);
CREATE INDEX profiles_role_idx        ON profiles (role);
CREATE INDEX profiles_referral_idx    ON profiles (referral_code);

-- Partner-specific profile (1:1 with a PARTNER profile).
CREATE TABLE partner_profiles (
  profile_id           uuid PRIMARY KEY REFERENCES profiles(id) ON DELETE CASCADE,
  display_name         text NOT NULL,
  bio                  text,
  profile_image_path   text,
  status               account_status NOT NULL DEFAULT 'PENDING_APPROVAL',
  approved_by_admin_id uuid,
  approved_at          timestamptz,
  rejection_reason     text,
  is_active            boolean NOT NULL DEFAULT true,
  vacation_mode        boolean NOT NULL DEFAULT false,
  deactivation_reason  text,
  daily_call_minute_threshold_override integer,
  -- Partner-only attributes (moved OFF profiles — clean role separation):
  is_premium           boolean NOT NULL DEFAULT false,
  is_featured          boolean NOT NULL DEFAULT false,
  profile_complete     boolean NOT NULL DEFAULT false,
  -- (commission_rate added in 0008; notification prefs live once on profiles)
  updated_at           timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX partner_profiles_status_idx ON partner_profiles (status) WHERE is_active;
CREATE INDEX partner_profiles_featured_idx ON partner_profiles (is_featured) WHERE is_featured;

-- Admin-specific profile (1:1, kept SEPARATE — role data does not belong on the
-- base profiles table). role + scoped permissions for admin RBAC.
CREATE TABLE admin_profiles (
  profile_id   uuid PRIMARY KEY REFERENCES profiles(id) ON DELETE CASCADE,
  admin_role   admin_role NOT NULL DEFAULT 'SUPPORT',
  permissions  jsonb NOT NULL DEFAULT '{}',
  created_at   timestamptz NOT NULL DEFAULT now(),
  updated_at   timestamptz NOT NULL DEFAULT now()
);

-- Account-deletion requests (DPDP / Play compliance): grace-period queue with a
-- confirmation step, so deletion is auditable and reversible until it executes.
CREATE TABLE deletion_requests (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  profile_id    uuid NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  reason        text,
  status        text NOT NULL DEFAULT 'REQUESTED',   -- REQUESTED | CONFIRMED | CANCELLED | COMPLETED
  requested_at  timestamptz NOT NULL DEFAULT now(),
  confirm_token text,
  confirmed_at  timestamptz,
  scheduled_purge_at timestamptz,                     -- grace period end
  completed_at  timestamptz
);
CREATE INDEX deletion_requests_profile_idx ON deletion_requests (profile_id);
CREATE INDEX deletion_requests_purge_idx ON deletion_requests (scheduled_purge_at)
  WHERE status = 'CONFIRMED';

-- KYC documents (private storage paths).
CREATE TABLE kyc_documents (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  profile_id    uuid NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  document_type text NOT NULL,
  storage_path  text NOT NULL,
  file_name     text,
  uploaded_at   timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX kyc_documents_profile_idx ON kyc_documents (profile_id);

-- Partner onboarding applications (pre-approval workflow).
CREATE TABLE partner_applications (
  id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  applicant_full_name  text NOT NULL,
  email                text NOT NULL,
  mobile_number        text,
  primary_social_link  text,
  expertise_description text,
  status               partner_application_status_enum NOT NULL DEFAULT 'PENDING_INITIAL_REVIEW',
  profile_id           uuid REFERENCES profiles(id) ON DELETE SET NULL,
  admin_notes          text,
  submitted_at         timestamptz NOT NULL DEFAULT now(),
  initial_review_at    timestamptz,
  initial_reviewed_by_admin_id uuid,
  final_review_at      timestamptz,
  final_reviewed_by_admin_id uuid,
  updated_at           timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX partner_applications_status_idx ON partner_applications (status);

COMMIT;

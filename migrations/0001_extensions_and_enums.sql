-- 0001 · Extensions + domain enums
-- Foundation for the lean Zudue schema. Types must exist before tables.
-- Cleaned from the live DB: dropped test_enum and status enums that the
-- consolidated money model no longer needs; kept every domain enum that
-- encodes a real product state (see docs/FEATURES.md).

BEGIN;

CREATE EXTENSION IF NOT EXISTS pgcrypto;      -- gen_random_uuid()

-- ── Identity & roles ────────────────────────────────────────────────────
CREATE TYPE user_role            AS ENUM ('FAN', 'PARTNER', 'ADMIN');
CREATE TYPE gender_enum          AS ENUM ('MALE', 'FEMALE', 'OTHER', 'PREFER_NOT_TO_SAY');
CREATE TYPE verification_status  AS ENUM ('NOT_SUBMITTED', 'PENDING_VERIFICATION', 'VERIFIED', 'REJECTED');
CREATE TYPE account_status       AS ENUM ('PENDING_APPROVAL', 'ACTIVE', 'INACTIVE', 'REJECTED_ONBOARDING', 'SUSPENDED');
CREATE TYPE partner_application_status_enum AS ENUM (
  'PENDING_INITIAL_REVIEW', 'AWAITING_KYC_AND_PROFILE_COMPLETION',
  'PENDING_FINAL_ADMIN_APPROVAL', 'ACTIVE',
  'REJECTED_INITIAL', 'REJECTED_KYC', 'REJECTED_FINAL');
CREATE TYPE admin_role AS ENUM ('SUPER_ADMIN', 'FINANCE', 'SUPPORT', 'MODERATOR');

-- ── Catalog / services ──────────────────────────────────────────────────
CREATE TYPE service_type_enum    AS ENUM ('VIDEO_CALL', 'QUICK_QUESTION', 'SHOUT_OUT');
CREATE TYPE call_duration_options_enum AS ENUM ('1','2','3','5','7','9','12','15');
CREATE TYPE social_platform_enum AS ENUM ('YOUTUBE', 'INSTAGRAM', 'FACEBOOK', 'TWITTER');

-- ── Booking & call lifecycle ────────────────────────────────────────────
CREATE TYPE booking_status AS ENUM (
  'PAYMENT_PENDING', 'BOOKED', 'COMPLETED_SUCCESSFUL',
  'EXPIRED_PARTNER_NO_SHOW', 'EXPIRED_FAN_NO_JOIN', 'EXPIRED_FAN_DECLINED',
  'EXPIRED_TECHNICAL_ISSUE', 'CANCELLED_BY_FAN', 'CANCELLED_BY_ADMIN');
CREATE TYPE call_status AS ENUM (
  'SCHEDULED', 'PARTNER_INITIATED', 'IN_PROGRESS', 'COMPLETED_SUCCESSFUL',
  'MISSED_FAN_NO_JOIN', 'MISSED_FAN_DECLINED', 'DROPPED_TECHNICAL_ISSUE');

-- ── Messaging: the windowed DM model uses dm_window_kind/status (in 0005).
-- The old quick_question_* and dm_report_* enums are NOT used by the new schema
-- (windows model + unified reports table) and are intentionally omitted.

-- ── Shout-outs ──────────────────────────────────────────────────────────
CREATE TYPE shout_out_status_enum AS ENUM (
  'PAYMENT_PENDING', 'PENDING_ADMIN_REVIEW', 'AWAITING_PARTNER_VIDEO',
  'VIDEO_RECEIVED_BY_ADMIN', 'VIDEO_DELIVERED_TO_FAN',
  'ISSUE_REPORTED_BY_FAN', 'REFUNDED_BY_ADMIN');

-- ── Money (paise; double-entry fan ledger + partner earnings) ───────────
CREATE TYPE txn_type AS ENUM (
  'TOPUP', 'BOOKING_DEBIT', 'QUESTION_DEBIT', 'SHOUTOUT_DEBIT',
  'REFUND', 'PARTNER_EARNING', 'PLATFORM_COMMISSION',
  'PAYOUT_DEBIT', 'PROMO_DISCOUNT', 'ADJUSTMENT');
CREATE TYPE txn_status     AS ENUM ('PENDING', 'SUCCESSFUL', 'FAILED', 'REVERSED');
CREATE TYPE earning_status AS ENUM ('PENDING_PAYOUT', 'INCLUDED_IN_PAYOUT', 'PAID', 'REVERSED');
CREATE TYPE payout_status  AS ENUM ('REQUESTED', 'APPROVED', 'PROCESSING', 'PAID', 'REJECTED');
CREATE TYPE payout_method_type AS ENUM ('BANK_ACCOUNT', 'UPI');

-- ── Promo & referrals ───────────────────────────────────────────────────
CREATE TYPE promo_code_discount_type_enum        AS ENUM ('PERCENTAGE', 'FIXED_AMOUNT');
CREATE TYPE promo_code_service_applicability_enum AS ENUM ('ALL', 'VIDEO_CALL', 'QUICK_QUESTION', 'SHOUT_OUT');
CREATE TYPE referral_status_enum AS ENUM (
  'PENDING_REFEREE_SIGNUP', 'PENDING_REFEREE_FIRST_ACTION', 'COMPLETED_REWARDED', 'EXPIRED');

-- ── Notifications ───────────────────────────────────────────────────────
CREATE TYPE notification_channel_enum AS ENUM ('EMAIL', 'DASHBOARD_ALERT', 'PUSH_NOTIFICATION');
CREATE TYPE notification_related_entity_type_enum AS ENUM (
  'booking', 'call', 'question', 'shoutout', 'user_profile', 'payout', 'system');
CREATE TYPE notification_event_type_enum AS ENUM (
  'WELCOME_MESSAGE', 'KYC_STATUS_UPDATE', 'PARTNER_APPLICATION_STATUS_UPDATE',
  'VIDEO_CALL_BOOKING_CONFIRMED_FAN', 'VIDEO_CALL_BOOKING_NEW_PARTNER',
  'VIDEO_CALL_REMINDER_FAN', 'VIDEO_CALL_REMINDER_PARTNER',
  'VIDEO_CALL_INITIATED_FOR_FAN', 'VIDEO_CALL_MISSED_ATTEMPT_FAN',
  'VIDEO_CALL_FAN_READY_PARTNER', 'VIDEO_CALL_COMPLETED_FAN', 'VIDEO_CALL_COMPLETED_PARTNER',
  'VIDEO_CALL_EXPIRED_PARTNER_NO_SHOW_FAN', 'VIDEO_CALL_CANCELLED_FAN', 'VIDEO_CALL_CANCELLED_PARTNER',
  'QUESTION_NEW_REQUEST_PARTNER', 'QUESTION_ANSWERED_BY_PARTNER_FAN',
  'QUESTION_ANSWER_REMINDER_PARTNER', 'QUESTION_EXPIRED_NO_RESPONSE_FAN',
  'SHOUTOUT_NEW_REQUEST_ADMIN_CC_PARTNER', 'SHOUTOUT_STATUS_UPDATE_FAN', 'SHOUTOUT_VIDEO_NEEDED_PARTNER',
  'PAYMENT_SUCCESSFUL_FAN', 'PAYMENT_FAILED_FAN', 'REFUND_PROCESSED_FAN',
  'PAYOUT_PROCESSED_PARTNER', 'PAYOUT_FAILED_PARTNER', 'PLATFORM_ANNOUNCEMENT');

COMMIT;

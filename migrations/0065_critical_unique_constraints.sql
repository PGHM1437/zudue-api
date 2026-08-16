-- 0065 · Critical UNIQUE/CHECK constraints lost in the legacy→live rewrite.
--
-- Found by diffing the legacy and live databases directly (both connections
-- available), not by re-reading old audit docs. Each one below is verified
-- against the LIVE column names as they exist today — a previous pass at
-- these same fixes used stale legacy column names (referrer_profile_id
-- instead of referrer_id) that would have made the ALTER TABLE fail outright.
--
-- ADD CONSTRAINT natively validates every existing row before committing, so
-- if any of these fail, it's telling you real bad data exists — that's a
-- signal to go look, not a reason to force the migration through.
--
-- C2: topup_orders.razorpay_payment_id had no UNIQUE constraint (legacy did,
-- on the predecessor `transactions` table). A replayed/duplicate Razorpay
-- webhook can currently create two topup_orders rows for one payment,
-- double-crediting a wallet.
--
-- H1: profiles.mobile_number had no UNIQUE constraint (legacy did). Two
-- accounts can currently share a phone number.
--
-- H3: referrals had no self-referral CHECK (legacy did:
-- chk_different_referrer_referee). Live columns are referrer_id/referee_id
-- (renamed from *_profile_id) — self-referral is currently unblocked.
--
-- M6: partner_applications has zero unique/check constraints live. Legacy
-- had UNIQUE(profile_id) — a partner can currently file multiple
-- applications.
--
-- M7: notifications has no dedup constraint. Legacy had
-- UNIQUE(recipient_profile_id, event_type, related_entity_type,
-- related_entity_id) — live has the equivalent columns
-- (recipient_id/event_type/related_entity_type/related_entity_id), just no
-- constraint.

BEGIN;

ALTER TABLE public.topup_orders
  ADD CONSTRAINT topup_orders_razorpay_payment_id_key UNIQUE (razorpay_payment_id);

ALTER TABLE public.profiles
  ADD CONSTRAINT profiles_mobile_number_key UNIQUE (mobile_number);

ALTER TABLE public.referrals
  ADD CONSTRAINT chk_different_referrer_referee CHECK (referrer_id <> referee_id);

ALTER TABLE public.partner_applications
  ADD CONSTRAINT partner_applications_profile_id_key UNIQUE (profile_id);

ALTER TABLE public.notifications
  ADD CONSTRAINT notifications_unique_active_event
  UNIQUE (recipient_id, event_type, related_entity_type, related_entity_id);

INSERT INTO _migrations (name) VALUES ('0065_critical_unique_constraints.sql')
  ON CONFLICT (name) DO NOTHING;

COMMIT;

-- 0050 · Design/architecture audit: referential integrity, dead weight, ledger.
--
-- ══ 1. THE DEPLOYMENT GAP (most serious finding) ═══════════════════════
-- scripts/migrate.mjs is idempotent via a `_migrations` ledger it creates and
-- consults. Neither database HAS that table, because every migration to date
-- was applied by hand with `psql -f`. Consequence: running the documented
-- deploy command (`pnpm db:migrate`) against either database would find an
-- empty ledger and attempt to replay all migrations from 0001. Most are
-- re-runnable, but several are categorically not —
--   0047 ALTER TABLE ... RENAME COLUMN reference TO utr
--   0043 ALTER TABLE ... ADD CONSTRAINT partner_earnings_service_uq
--   0047 CREATE UNIQUE INDEX partner_payouts_utr_uq   (no IF NOT EXISTS)
--   0049 ALTER TABLE ... ADD CONSTRAINT booking_price_identity
-- so the replay would abort partway and leave the schema half-migrated.
-- Creating and backfilling the ledger makes the deploy path correct.
--
-- ══ 2. REFERENTIAL INTEGRITY ═══════════════════════════════════════════
-- 12 uuid columns recording "which admin did this" had no foreign key, so a
-- garbage uuid was storable and the attribution could dangle. ON DELETE SET
-- NULL: an admin leaving must never block deleting their profile, nor silently
-- rewrite history — the action stays, the attribution becomes unknown.
--
-- Four other FK-less uuid columns are CORRECT as they are and deliberately
-- untouched: audit_log.target_id, notifications.related_entity_id,
-- reports.target_id and partner_earnings.service_id are polymorphic — they
-- point at different tables depending on a sibling type column, which no
-- single FK can express.
--
-- ══ 3. DEAD WEIGHT ═════════════════════════════════════════════════════
-- 409 columns scanned against every migration, the API, the admin app and the
-- Flutter client. 18 appear nowhere but their own definition. Verified none is
-- referenced by any function or view before dropping.
--
-- Two of these are worth naming rather than quietly removing:
--   profiles.guardian_* — minor-user handling was designed (is_minor is a
--     GENERATED column from age) but the guardian-consent flow was never
--     built. Dropping three unused text columns does not remove a working
--     safeguard; it removes the illusion of one. If minors are in scope, this
--     needs designing properly, not three orphan columns.
--   notifications.channels_sent / delivery_status — per-channel delivery
--     receipts were never recorded; push goes out via FCM/OneSignal and
--     nothing writes back. Re-add with the feature if it is built.

BEGIN;

-- ── 1 · Migration ledger, backfilled to current state ───────────────────
CREATE TABLE IF NOT EXISTS _migrations (
  name       text PRIMARY KEY,
  applied_at timestamptz NOT NULL DEFAULT now()
);

-- Backfill every migration up to and including this one. Recorded as applied
-- because the schema already reflects them; this is a statement of fact, not
-- a replay. 0050 itself is inserted so the next `pnpm db:migrate` is a no-op.
INSERT INTO _migrations (name) VALUES
  ('0001_extensions_and_enums.sql'),
  ('0002_identity.sql'),
  ('0003_catalog_pricing.sql'),
  ('0004_money.sql'),
  ('0005_services.sql'),
  ('0006_promo_referrals_credits.sql'),
  ('0007_notifications_push_waitlist.sql'),
  ('0008_config_taxonomy_folds.sql'),
  ('0009_trust_audit.sql'),
  ('0010_functions.sql'),
  ('0011_rls.sql'),
  ('0012_admin_controls_and_blocking.sql'),
  ('0013_triggers.sql'),
  ('0014_rpc_booking.sql'),
  ('0015_rpc_calls.sql'),
  ('0016_rpc_messaging.sql'),
  ('0017_rpc_shoutout_payout.sql'),
  ('0018_rpc_admin_moderation.sql'),
  ('0019_read_models.sql'),
  ('0020_categories_and_gaps.sql'),
  ('0021_close_gaps.sql'),
  ('0022_drop_vulnerable_overloads.sql'),
  ('0023_rpc_authorization_hardening.sql'),
  ('0024_admin_full_administration.sql'),
  ('0025_production_hardening.sql'),
  ('0026_view_security_invoker.sql'),
  ('0027_admin_read_models.sql'),
  ('0028_fix_signup_rls.sql'),
  ('0029_fix_pii_leak_and_view_hardening.sql'),
  ('0030_admin_complete_management.sql'),
  ('0031_fix_settings_audit_trigger.sql'),
  ('0032_prune_admin_read_layer.sql'),
  ('0033_admin_reset_payout_methods.sql'),
  ('0034_feature_parity_gaps.sql'),
  ('0035_push_onesignal.sql'),
  ('0036_settle_shoutout_and_purge.sql'),
  ('0037_expose_payout_method_id.sql'),
  ('0038_partner_services_nulls_not_distinct.sql'),
  ('0039_audit_cleanup.sql'),
  ('0040_wire_config_knobs.sql'),
  ('0041_drop_redundant_indexes.sql'),
  ('0042_platform_funded_promos.sql'),
  ('0043_settlement_idempotency.sql'),
  ('0044_drop_partner_tags.sql'),
  ('0045_disputes_and_audit_read.sql'),
  ('0046_favourites_and_search.sql'),
  ('0047_payout_utr.sql'),
  ('0048_settings_editor_and_limits.sql'),
  ('0049_audit_hardening.sql'),
  ('0050_schema_hygiene.sql')
ON CONFLICT (name) DO NOTHING;

-- ── 2 · Missing foreign keys on admin-attribution columns ───────────────
ALTER TABLE public.partner_applications
  ADD CONSTRAINT partner_applications_initial_reviewer_fk
    FOREIGN KEY (initial_reviewed_by_admin_id) REFERENCES public.profiles(id) ON DELETE SET NULL,
  ADD CONSTRAINT partner_applications_final_reviewer_fk
    FOREIGN KEY (final_reviewed_by_admin_id) REFERENCES public.profiles(id) ON DELETE SET NULL;

ALTER TABLE public.partner_profiles
  ADD CONSTRAINT partner_profiles_approved_by_fk
    FOREIGN KEY (approved_by_admin_id) REFERENCES public.profiles(id) ON DELETE SET NULL,
  ADD CONSTRAINT partner_profiles_featured_by_fk
    FOREIGN KEY (featured_by_admin_id) REFERENCES public.profiles(id) ON DELETE SET NULL,
  ADD CONSTRAINT partner_profiles_premium_by_fk
    FOREIGN KEY (premium_by_admin_id) REFERENCES public.profiles(id) ON DELETE SET NULL;

ALTER TABLE public.partner_social_links
  ADD CONSTRAINT partner_social_links_approved_by_fk
    FOREIGN KEY (approved_by_admin_id) REFERENCES public.profiles(id) ON DELETE SET NULL;

ALTER TABLE public.payout_methods
  ADD CONSTRAINT payout_methods_verified_by_fk
    FOREIGN KEY (verified_by_admin_id) REFERENCES public.profiles(id) ON DELETE SET NULL;

ALTER TABLE public.platform_settings
  ADD CONSTRAINT platform_settings_updated_by_fk
    FOREIGN KEY (last_updated_by_admin_id) REFERENCES public.profiles(id) ON DELETE SET NULL;

ALTER TABLE public.profiles
  ADD CONSTRAINT profiles_kyc_verified_by_fk
    FOREIGN KEY (kyc_verified_by_admin_id) REFERENCES public.profiles(id) ON DELETE SET NULL,
  ADD CONSTRAINT profiles_status_changed_by_fk
    FOREIGN KEY (status_changed_by) REFERENCES public.profiles(id) ON DELETE SET NULL;

ALTER TABLE public.promo_codes
  ADD CONSTRAINT promo_codes_created_by_fk
    FOREIGN KEY (created_by_admin_id) REFERENCES public.profiles(id) ON DELETE SET NULL;

ALTER TABLE public.shout_out_requests
  ADD CONSTRAINT shout_out_requests_admin_handler_fk
    FOREIGN KEY (admin_handler_id) REFERENCES public.profiles(id) ON DELETE SET NULL;

-- Index the new FKs that sit on tables which will actually grow, so the
-- ON DELETE SET NULL scan is not a seq scan. The single-row platform_settings
-- and the low-cardinality admin tables do not warrant one.
CREATE INDEX IF NOT EXISTS partner_profiles_approved_by_idx
  ON public.partner_profiles (approved_by_admin_id) WHERE approved_by_admin_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS profiles_status_changed_by_idx
  ON public.profiles (status_changed_by) WHERE status_changed_by IS NOT NULL;

-- ── 3 · Dead function ───────────────────────────────────────────────────
-- is_partner() is referenced by no function, view, policy, trigger or
-- application code. Partner checks are done via partner_profiles.status.
DROP FUNCTION IF EXISTS public.is_partner(uuid);
DROP FUNCTION IF EXISTS public.is_partner();

-- ── 4 · Dead columns ────────────────────────────────────────────────────
ALTER TABLE public.audit_log            DROP COLUMN IF EXISTS user_agent;
ALTER TABLE public.deletion_requests    DROP COLUMN IF EXISTS confirmed_at;
ALTER TABLE public.notifications        DROP COLUMN IF EXISTS channels_sent,
                                        DROP COLUMN IF EXISTS delivery_status;
ALTER TABLE public.partner_profiles     DROP COLUMN IF EXISTS daily_call_minute_threshold_override;
ALTER TABLE public.profiles             DROP COLUMN IF EXISTS guardian_contact_details,
                                        DROP COLUMN IF EXISTS guardian_full_name,
                                        DROP COLUMN IF EXISTS guardian_relationship,
                                        DROP COLUMN IF EXISTS mobile_verified_at;
ALTER TABLE public.shout_out_requests   DROP COLUMN IF EXISTS pronunciation_guide;
ALTER TABLE public.platform_settings    DROP COLUMN IF EXISTS availability_lead_days,
                                        DROP COLUMN IF EXISTS call_durations_minutes,
                                        DROP COLUMN IF EXISTS call_operational_end_hour_ist,
                                        DROP COLUMN IF EXISTS call_operational_start_hour_ist,
                                        DROP COLUMN IF EXISTS content_limits,
                                        DROP COLUMN IF EXISTS notification_templates,
                                        DROP COLUMN IF EXISTS shoutout_sla_business_days,
                                        DROP COLUMN IF EXISTS tds_rate;

-- notification_delivery_status was only ever used by the column just dropped.
DROP TYPE IF EXISTS public.notification_delivery_status;

COMMIT;

-- 0028 · CRITICAL FIX: new user signup was completely broken under real RLS
-- enforcement. Two compounding gaps, both invisible until this moment because
-- nothing had ever exercised a `profiles` INSERT through the actual
-- non-superuser application role until now:
--
-- 1. `profiles` had SELECT and UPDATE policies from migration 0011, but no
--    INSERT policy at all. RLS defaults to deny for any operation with no
--    matching policy — every INSERT INTO profiles (i.e. every signup, for
--    every fan and partner, ever) would be rejected outright.
-- 2. Even with (1) fixed, `provision_fan_wallet()` (the trigger that
--    auto-creates a fan's wallet) is not SECURITY DEFINER, so its own
--    INSERT INTO wallets would run as the same unprivileged caller — and
--    `wallets` has no INSERT policy either. The trigger would fail and roll
--    back the entire signup.
--
-- Fix: allow a caller to insert their own profile row (id must match their
-- own verified identity — the same pattern used everywhere else in this
-- schema), and make wallet auto-provisioning SECURITY DEFINER, since it's
-- system-provisioned infrastructure, not a user's own direct table write.

BEGIN;

CREATE POLICY profiles_self_insert ON profiles FOR INSERT WITH CHECK (id = current_user_id() OR is_admin());

CREATE OR REPLACE FUNCTION provision_fan_wallet()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  IF NEW.role = 'FAN' THEN
    INSERT INTO public.wallets (profile_id) VALUES (NEW.id)
      ON CONFLICT (profile_id) DO NOTHING;
  END IF;
  RETURN NEW;
END $$;

-- Same audit, same class of bug, found across the rest of the self-service
-- surface before it could bite in production one table at a time:

-- Partner onboarding creates their OWN partner_profiles row (status starts
-- PENDING_APPROVAL; rpc_admin_approve_partner only ever UPDATEs an existing
-- row — something has to create it first). No INSERT policy existed at all.
CREATE POLICY partner_profiles_self_insert ON partner_profiles FOR INSERT
  WITH CHECK (profile_id = current_user_id() OR is_admin());

-- An applicant may already have an account (profile_id = self) or may be
-- pre-account (profile_id NULL, matched by email later, per the documented
-- design). No INSERT policy existed at all.
CREATE POLICY application_self_insert ON partner_applications FOR INSERT
  WITH CHECK (profile_id = current_user_id() OR profile_id IS NULL OR is_admin());

-- A fan must create their OWN topup_orders row (status=PENDING) before the
-- gateway confirms and rpc_verify_topup runs — that's the entire top-up
-- initiation flow. No INSERT policy existed at all.
CREATE POLICY topup_self_insert ON topup_orders FOR INSERT
  WITH CHECK (profile_id = current_user_id());

-- A new signup using a referral code needs to record who referred them. No
-- INSERT policy existed at all — referrals could only ever be read, never
-- created, by anyone other than admin.
CREATE POLICY referral_self_insert ON referrals FOR INSERT
  WITH CHECK (referee_id = current_user_id());

-- webhook_events and disputes only checked is_admin() — but Razorpay
-- webhook ingestion (idempotency logging, chargeback creation) runs as a
-- trusted system process reacting to an inbound HTTP call, not an
-- authenticated admin session. Extended to allow the service role too.
DROP POLICY webhook_admin ON webhook_events;
CREATE POLICY webhook_admin ON webhook_events FOR ALL USING (is_admin() OR is_service_role());

DROP POLICY dispute_admin ON disputes;
CREATE POLICY dispute_admin ON disputes FOR ALL USING (is_admin() OR is_service_role());

COMMIT;

-- 0011 · Row-Level Security on EVERY table (the audit's #1 fix, done right).
-- One consistent pattern: owner can read/write own rows; admin sees all; money
-- tables are read-own but mutated only by the trusted API (service role, which
-- bypasses RLS). Reference/config tables are readable, admin-writable.

BEGIN;

-- Helper macro pattern is applied explicitly per table for clarity.

-- ── Identity ────────────────────────────────────────────────────────────
ALTER TABLE profiles ENABLE ROW LEVEL SECURITY;
CREATE POLICY profiles_self_read  ON profiles FOR SELECT USING (id = current_user_id() OR is_admin());
CREATE POLICY profiles_self_write ON profiles FOR UPDATE USING (id = current_user_id() OR is_admin());
CREATE POLICY profiles_public_partner ON profiles FOR SELECT USING (role = 'PARTNER'); -- discovery

ALTER TABLE partner_profiles ENABLE ROW LEVEL SECURITY;
CREATE POLICY partner_public_read ON partner_profiles FOR SELECT USING (true);         -- browse
CREATE POLICY partner_self_write  ON partner_profiles FOR UPDATE USING (profile_id = current_user_id() OR is_admin());

ALTER TABLE kyc_documents ENABLE ROW LEVEL SECURITY;
CREATE POLICY kyc_owner ON kyc_documents FOR ALL USING (profile_id = current_user_id() OR is_admin());

ALTER TABLE partner_applications ENABLE ROW LEVEL SECURITY;
CREATE POLICY application_owner ON partner_applications FOR SELECT
  USING (profile_id = current_user_id() OR is_admin());

ALTER TABLE deletion_requests ENABLE ROW LEVEL SECURITY;
CREATE POLICY deletion_owner ON deletion_requests FOR ALL
  USING (profile_id = current_user_id() OR is_admin());

ALTER TABLE admin_profiles ENABLE ROW LEVEL SECURITY;
CREATE POLICY admin_profiles_self ON admin_profiles FOR SELECT
  USING (profile_id = current_user_id() OR is_admin());

-- ── Catalog (public read; partner/admin write) ──────────────────────────
ALTER TABLE partner_services ENABLE ROW LEVEL SECURITY;
CREATE POLICY services_public_read ON partner_services FOR SELECT USING (true);
CREATE POLICY services_owner_write ON partner_services FOR ALL
  USING (partner_id = current_user_id() OR is_admin());

ALTER TABLE partner_social_links ENABLE ROW LEVEL SECURITY;
CREATE POLICY social_public_read ON partner_social_links FOR SELECT USING (is_approved OR partner_id = current_user_id() OR is_admin());
CREATE POLICY social_owner_write ON partner_social_links FOR ALL USING (partner_id = current_user_id() OR is_admin());

ALTER TABLE availability ENABLE ROW LEVEL SECURITY;
CREATE POLICY availability_public_read ON availability FOR SELECT USING (true);
CREATE POLICY availability_owner_write ON availability FOR ALL USING (partner_id = current_user_id() OR is_admin());

ALTER TABLE categories ENABLE ROW LEVEL SECURITY;
CREATE POLICY categories_read ON categories FOR SELECT USING (true);
CREATE POLICY categories_admin ON categories FOR ALL USING (is_admin());
ALTER TABLE partner_categories ENABLE ROW LEVEL SECURITY;
CREATE POLICY partner_categories_read ON partner_categories FOR SELECT USING (true);
CREATE POLICY partner_categories_write ON partner_categories FOR ALL USING (partner_id = current_user_id() OR is_admin());
ALTER TABLE partner_tags ENABLE ROW LEVEL SECURITY;
CREATE POLICY partner_tags_read ON partner_tags FOR SELECT USING (true);
CREATE POLICY partner_tags_write ON partner_tags FOR ALL USING (partner_id = current_user_id() OR is_admin());

-- ── Money (read-own; mutated only by trusted API / admin) ───────────────
ALTER TABLE wallets ENABLE ROW LEVEL SECURITY;
CREATE POLICY wallet_owner_read ON wallets FOR SELECT USING (profile_id = current_user_id() OR is_admin());
ALTER TABLE transactions ENABLE ROW LEVEL SECURITY;
CREATE POLICY txn_admin_read ON transactions FOR SELECT USING (is_admin());
ALTER TABLE ledger_entries ENABLE ROW LEVEL SECURITY;
CREATE POLICY ledger_admin_read ON ledger_entries FOR SELECT USING (is_admin());
ALTER TABLE topup_orders ENABLE ROW LEVEL SECURITY;
CREATE POLICY topup_owner_read ON topup_orders FOR SELECT USING (profile_id = current_user_id() OR is_admin());
ALTER TABLE partner_earnings ENABLE ROW LEVEL SECURITY;
CREATE POLICY earning_owner_read ON partner_earnings FOR SELECT USING (partner_id = current_user_id() OR is_admin());
ALTER TABLE payout_methods ENABLE ROW LEVEL SECURITY;
CREATE POLICY payout_method_owner ON payout_methods FOR ALL USING (partner_id = current_user_id() OR is_admin());
ALTER TABLE partner_payouts ENABLE ROW LEVEL SECURITY;
CREATE POLICY payout_owner_read ON partner_payouts FOR SELECT USING (partner_id = current_user_id() OR is_admin());
ALTER TABLE credit_grants ENABLE ROW LEVEL SECURITY;
CREATE POLICY credit_grant_owner ON credit_grants FOR SELECT USING (profile_id = current_user_id() OR is_admin());

-- ── Services (participants + admin) ─────────────────────────────────────
ALTER TABLE bookings ENABLE ROW LEVEL SECURITY;
CREATE POLICY booking_party ON bookings FOR SELECT USING (fan_id = current_user_id() OR partner_id = current_user_id() OR is_admin());
ALTER TABLE calls ENABLE ROW LEVEL SECURITY;
CREATE POLICY call_party ON calls FOR SELECT USING (fan_id = current_user_id() OR partner_id = current_user_id() OR is_admin());
ALTER TABLE conversations ENABLE ROW LEVEL SECURITY;
CREATE POLICY conversation_party ON conversations FOR SELECT USING (fan_id = current_user_id() OR partner_id = current_user_id() OR is_admin());
ALTER TABLE conversation_windows ENABLE ROW LEVEL SECURITY;
CREATE POLICY window_party ON conversation_windows FOR SELECT USING (
  EXISTS (SELECT 1 FROM conversations c WHERE c.id = conversation_id
          AND (c.fan_id = current_user_id() OR c.partner_id = current_user_id())) OR is_admin());
ALTER TABLE messages ENABLE ROW LEVEL SECURITY;
CREATE POLICY message_party ON messages FOR SELECT USING (
  EXISTS (SELECT 1 FROM conversation_windows w JOIN conversations c ON c.id = w.conversation_id
          WHERE w.id = window_id AND (c.fan_id = current_user_id() OR c.partner_id = current_user_id())) OR is_admin());
ALTER TABLE shout_out_requests ENABLE ROW LEVEL SECURITY;
CREATE POLICY shoutout_party ON shout_out_requests FOR SELECT USING (fan_id = current_user_id() OR partner_id = current_user_id() OR is_admin());

-- ── Growth ──────────────────────────────────────────────────────────────
ALTER TABLE promo_codes ENABLE ROW LEVEL SECURITY;
CREATE POLICY promo_admin ON promo_codes FOR ALL USING (is_admin());          -- validated server-side; not enumerable
ALTER TABLE promo_code_usages ENABLE ROW LEVEL SECURITY;
CREATE POLICY promo_usage_owner ON promo_code_usages FOR SELECT USING (fan_id = current_user_id() OR is_admin());
ALTER TABLE referrals ENABLE ROW LEVEL SECURITY;
CREATE POLICY referral_owner ON referrals FOR SELECT USING (referrer_id = current_user_id() OR referee_id = current_user_id() OR is_admin());

-- ── Engagement ──────────────────────────────────────────────────────────
ALTER TABLE notifications ENABLE ROW LEVEL SECURITY;
CREATE POLICY notification_owner ON notifications FOR ALL USING (recipient_id = current_user_id() OR is_admin());
ALTER TABLE push_tokens ENABLE ROW LEVEL SECURITY;
CREATE POLICY push_owner ON push_tokens FOR ALL USING (profile_id = current_user_id() OR is_admin());
ALTER TABLE waitlist ENABLE ROW LEVEL SECURITY;
CREATE POLICY waitlist_owner ON waitlist FOR ALL USING (fan_id = current_user_id() OR is_admin());

-- ── Config (read-all; admin-write) ──────────────────────────────────────
ALTER TABLE platform_settings ENABLE ROW LEVEL SECURITY;
CREATE POLICY settings_read  ON platform_settings FOR SELECT USING (true);
CREATE POLICY settings_admin ON platform_settings FOR UPDATE USING (is_admin());

-- ── Trust & audit (admin; reporters see own) ────────────────────────────
ALTER TABLE user_blocks ENABLE ROW LEVEL SECURITY;
CREATE POLICY block_owner ON user_blocks FOR ALL USING (blocker_id = current_user_id() OR is_admin());
ALTER TABLE reports ENABLE ROW LEVEL SECURITY;
CREATE POLICY report_reporter ON reports FOR SELECT USING (reporter_id = current_user_id() OR is_admin());
CREATE POLICY report_create   ON reports FOR INSERT WITH CHECK (reporter_id = current_user_id());
ALTER TABLE disputes ENABLE ROW LEVEL SECURITY;
CREATE POLICY dispute_admin ON disputes FOR ALL USING (is_admin());
ALTER TABLE webhook_events ENABLE ROW LEVEL SECURITY;
CREATE POLICY webhook_admin ON webhook_events FOR ALL USING (is_admin());
ALTER TABLE audit_log ENABLE ROW LEVEL SECURITY;
CREATE POLICY audit_admin ON audit_log FOR SELECT USING (is_admin());

COMMIT;

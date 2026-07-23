-- 0029 · CRITICAL FIX: profiles_public_partner leaked every partner's email
-- and mobile_number to any caller.
--
-- `profiles_public_partner ON profiles FOR SELECT USING (role = 'PARTNER')`
-- was written for one narrow purpose — "discovery" (per its own comment) —
-- but RLS is row-level, not column-level: making a partner's PROFILE ROW
-- visible for browsing also makes every column on that row visible,
-- including email, mobile_number, verification_status, and kyc_rejection_reason.
-- Confirmed while testing vw_admin_manage_partners: a plain non-admin partner
-- querying it got back another partner's row with commission_rate and
-- pending_earnings_paise — because BOTH partner_profiles (intentionally
-- public) and profiles (via this policy) were readable by anyone.
--
-- The home-page discovery view (vw_discover_partners) turns out to only need
-- `profiles` for one thing: checking account_status='ACTIVE' in its WHERE
-- clause — it never actually selects a profiles column. So the fix is to stop
-- needing that join at all: keep partner_profiles.is_active in sync with the
-- account-level ban/suspend decision via a trigger, then discovery only ever
-- touches partner_profiles (public by design, contains no PII), and the
-- leaky policy can be dropped outright.
--
-- Also hardening all 10 admin views from 0027 with an explicit `is_admin()`
-- guard in their own WHERE clause — not relying solely on however permissive
-- the underlying tables' policies happen to be. This is the second time an
-- admin view turned out to be only as restrictive as its most permissive
-- joined table; making it a property of the view itself closes that whole
-- class of bug instead of re-auditing table-by-table each time.

BEGIN;

-- Keep partner_profiles.is_active in sync with account-level bans, so
-- discovery never needs to consult `profiles` for that check again.
CREATE OR REPLACE FUNCTION sync_partner_account_ban()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  IF NEW.role = 'PARTNER' AND NEW.account_status <> 'ACTIVE' THEN
    UPDATE public.partner_profiles
      SET is_active = false,
          deactivation_reason = COALESCE(deactivation_reason, 'Account status: ' || NEW.account_status::text)
      WHERE profile_id = NEW.id;
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_sync_partner_account_ban AFTER UPDATE OF account_status ON profiles
  FOR EACH ROW WHEN (OLD.account_status IS DISTINCT FROM NEW.account_status)
  EXECUTE FUNCTION sync_partner_account_ban();

-- Discovery no longer needs `profiles` at all.
CREATE OR REPLACE VIEW vw_discover_partners AS
SELECT pp.profile_id, pp.display_name, pp.bio, pp.profile_image_path,
       pp.is_premium, pp.is_featured,
       (SELECT min(price_paise) FROM partner_services s
          WHERE s.partner_id=pp.profile_id AND s.service_type='VIDEO_CALL' AND s.is_active) AS min_call_price_paise,
       (SELECT price_paise FROM partner_services s
          WHERE s.partner_id=pp.profile_id AND s.service_type='QUICK_QUESTION' AND s.is_active) AS question_price_paise,
       (SELECT price_paise FROM partner_services s
          WHERE s.partner_id=pp.profile_id AND s.service_type='SHOUT_OUT' AND s.is_active) AS shoutout_price_paise,
       (SELECT array_agg(c.slug) FROM partner_categories pc
          JOIN categories c ON c.id=pc.category_id WHERE pc.partner_id=pp.profile_id) AS categories,
       (CASE WHEN pp.is_featured THEN 0 WHEN pp.is_premium THEN 1 ELSE 2 END) AS suggest_rank
FROM partner_profiles pp
WHERE pp.status='ACTIVE' AND pp.is_active AND NOT pp.vacation_mode
ORDER BY suggest_rank, pp.display_name;
ALTER VIEW vw_discover_partners SET (security_invoker = true);

-- Now safe to drop — nothing depends on it, and it was the source of the leak.
DROP POLICY profiles_public_partner ON profiles;

-- ── Harden the 10 admin views: explicit is_admin() gate, not inherited RLS ──
CREATE OR REPLACE VIEW vw_admin_manage_partners AS
SELECT pp.profile_id, pp.display_name, p.email, p.mobile_number, p.account_status,
       p.verification_status, pp.status AS partner_status, pp.is_active, pp.vacation_mode,
       pp.is_premium, pp.is_featured, pp.commission_rate, pp.approved_at,
       (SELECT array_agg(c.slug) FROM partner_categories pc JOIN categories c ON c.id = pc.category_id
          WHERE pc.partner_id = pp.profile_id) AS categories,
       (SELECT count(*) FROM partner_services s WHERE s.partner_id = pp.profile_id AND s.is_active) AS active_services_count,
       (SELECT count(*) FROM bookings b WHERE b.partner_id = pp.profile_id AND b.status = 'COMPLETED_SUCCESSFUL') AS completed_bookings,
       (SELECT COALESCE(sum(amount_paise), 0) FROM partner_earnings e WHERE e.partner_id = pp.profile_id AND e.status = 'PENDING_PAYOUT') AS pending_earnings_paise,
       p.created_at
FROM partner_profiles pp
JOIN profiles p ON p.id = pp.profile_id
WHERE is_admin();
ALTER VIEW vw_admin_manage_partners SET (security_invoker = true);

CREATE OR REPLACE VIEW vw_admin_manage_fans AS
SELECT p.id AS profile_id, p.full_name, p.email, p.mobile_number, p.account_status,
       p.verification_status, p.created_at,
       w.balance_paise, w.bonus_balance_paise,
       (SELECT count(*) FROM bookings b WHERE b.fan_id = p.id) AS total_bookings,
       (SELECT count(*) FROM reports r WHERE r.target_id = p.id AND r.target_type = 'PROFILE') AS reports_against
FROM profiles p
LEFT JOIN wallets w ON w.profile_id = p.id
WHERE p.role = 'FAN' AND is_admin();
ALTER VIEW vw_admin_manage_fans SET (security_invoker = true);

CREATE OR REPLACE VIEW vw_admin_pending_kyc_verifications AS
SELECT p.id AS profile_id, p.full_name, p.email, p.role, p.verification_status, p.kyc_submitted_at,
       (SELECT jsonb_agg(jsonb_build_object('type', d.document_type, 'path', d.storage_path,
          'file_name', d.file_name, 'uploaded_at', d.uploaded_at))
        FROM kyc_documents d WHERE d.profile_id = p.id) AS documents
FROM profiles p
WHERE p.verification_status = 'PENDING_VERIFICATION' AND is_admin();
ALTER VIEW vw_admin_pending_kyc_verifications SET (security_invoker = true);

CREATE OR REPLACE VIEW vw_admin_pending_partner_applications AS
SELECT a.id, a.applicant_full_name, a.email, a.mobile_number, a.primary_social_link,
       a.expertise_description, a.status, a.admin_notes, a.submitted_at, a.profile_id
FROM partner_applications a
WHERE a.status NOT IN ('ACTIVE', 'REJECTED_INITIAL', 'REJECTED_KYC', 'REJECTED_FINAL') AND is_admin();
ALTER VIEW vw_admin_pending_partner_applications SET (security_invoker = true);

CREATE OR REPLACE VIEW vw_admin_pending_withdrawals AS
SELECT po.id AS payout_id, po.partner_id, pp.display_name, po.amount_paise, po.status, po.requested_at,
       pm.method_type, pm.account_holder_name, pm.account_number, pm.ifsc_code, pm.bank_name,
       pm.upi_id, pm.is_verified
FROM partner_payouts po
JOIN partner_profiles pp ON pp.profile_id = po.partner_id
JOIN payout_methods pm ON pm.id = po.payout_method_id
WHERE po.status IN ('REQUESTED', 'APPROVED', 'PROCESSING') AND is_admin();
ALTER VIEW vw_admin_pending_withdrawals SET (security_invoker = true);

CREATE OR REPLACE VIEW vw_admin_processed_payouts AS
SELECT po.id AS payout_id, po.partner_id, pp.display_name, po.amount_paise, po.status,
       po.reference, po.processed_at, pm.method_type
FROM partner_payouts po
JOIN partner_profiles pp ON pp.profile_id = po.partner_id
JOIN payout_methods pm ON pm.id = po.payout_method_id
WHERE po.status IN ('PAID', 'REJECTED') AND is_admin();
ALTER VIEW vw_admin_processed_payouts SET (security_invoker = true);

CREATE OR REPLACE VIEW vw_admin_wallet_overview AS
SELECT count(*) AS total_wallets,
       COALESCE(sum(balance_paise), 0) AS total_balance_paise,
       COALESCE(sum(bonus_balance_paise), 0) AS total_bonus_paise,
       COALESCE(sum(balance_paise) FILTER (WHERE balance_paise > 0), 0) AS total_positive_balance_paise
FROM wallets
WHERE is_admin();
ALTER VIEW vw_admin_wallet_overview SET (security_invoker = true);

CREATE OR REPLACE VIEW vw_admin_all_video_calls AS
SELECT b.id AS booking_id, b.fan_id, fp.full_name AS fan_name, b.partner_id, pp.display_name AS partner_name,
       b.scheduled_date, b.selected_duration, b.price_paise, b.status AS booking_status,
       lc.id AS call_id, lc.attempt_status AS call_status, lc.started_at, lc.ended_at, lc.actual_duration_seconds
FROM bookings b
JOIN profiles fp ON fp.id = b.fan_id
JOIN partner_profiles pp ON pp.profile_id = b.partner_id
LEFT JOIN LATERAL (
  SELECT * FROM calls c WHERE c.booking_id = b.id ORDER BY c.partner_initiated_at DESC LIMIT 1
) lc ON true
WHERE is_admin();
ALTER VIEW vw_admin_all_video_calls SET (security_invoker = true);

CREATE OR REPLACE VIEW vw_admin_all_shout_outs AS
SELECT s.id, s.fan_id, fp.full_name AS fan_name, s.partner_id, pp.display_name AS partner_name,
       s.recipient_name, s.price_paise, s.status, s.created_at, s.delivered_at
FROM shout_out_requests s
JOIN profiles fp ON fp.id = s.fan_id
JOIN partner_profiles pp ON pp.profile_id = s.partner_id
WHERE is_admin();
ALTER VIEW vw_admin_all_shout_outs SET (security_invoker = true);

CREATE OR REPLACE VIEW vw_admin_manage_questions AS
SELECT w.id AS window_id, c.fan_id, fp.full_name AS fan_name, c.partner_id, pp.display_name AS partner_name,
       w.kind, w.charge_paise, w.status, w.opened_at, w.response_deadline,
       (SELECT count(*) FROM messages m WHERE m.window_id = w.id) AS message_count
FROM conversation_windows w
JOIN conversations c ON c.id = w.conversation_id
JOIN profiles fp ON fp.id = c.fan_id
JOIN partner_profiles pp ON pp.profile_id = c.partner_id
WHERE is_admin();
ALTER VIEW vw_admin_manage_questions SET (security_invoker = true);

COMMIT;

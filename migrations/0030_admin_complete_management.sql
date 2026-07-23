-- 0030 · Complete the admin management surface.
--
-- Honest gap analysis of the 0027 views against the actual admin panel
-- (Dashboard, Manage Partners, Manage Fans, KYC, Video Calls, DMs, Shout-Outs,
-- Payments, Withdrawals, Reports & Analytics, Promo & Referrals, Settings)
-- found six screens with NO backing view at all and three too thin to manage
-- from. This migration closes every gap and enriches the thin ones. Every
-- view is is_admin()-gated + security_invoker=true (the pattern proven in
-- 0029). New matview gets its zudue_app default-grant revoked (the 0025
-- footgun) and is exposed only through an is_admin() wrapper.

BEGIN;

-- ═══ 1. DASHBOARD — one-row operational KPI snapshot (had nothing) ═══
CREATE VIEW vw_admin_dashboard_stats AS
SELECT
  (SELECT count(*) FROM profiles WHERE role='FAN') AS total_fans,
  (SELECT count(*) FROM partner_profiles WHERE status='ACTIVE') AS active_partners,
  (SELECT count(*) FROM profiles WHERE account_status<>'ACTIVE') AS suspended_or_banned_users,
  (SELECT count(*) FROM profiles WHERE verification_status='PENDING_VERIFICATION') AS pending_kyc,
  (SELECT count(*) FROM partner_applications WHERE status NOT IN ('ACTIVE','REJECTED_INITIAL','REJECTED_KYC','REJECTED_FINAL')) AS pending_applications,
  (SELECT count(*) FROM partner_payouts WHERE status IN ('REQUESTED','APPROVED','PROCESSING')) AS pending_withdrawals,
  (SELECT COALESCE(sum(amount_paise),0) FROM partner_payouts WHERE status IN ('REQUESTED','APPROVED','PROCESSING')) AS pending_withdrawal_amount_paise,
  (SELECT count(*) FROM reports WHERE status IN ('PENDING','REVIEWING')) AS open_reports,
  (SELECT count(*) FROM disputes WHERE status IN ('OPEN','UNDER_REVIEW')) AS open_disputes,
  (SELECT count(*) FROM shout_out_requests WHERE status='AWAITING_PARTNER_VIDEO') AS shoutouts_awaiting_video,
  (SELECT count(*) FROM bookings WHERE status='BOOKED') AS active_bookings,
  (SELECT COALESCE(sum(amount_paise),0) FROM transactions WHERE type='TOPUP' AND status='SUCCESSFUL') AS gross_topups_all_time_paise,
  (SELECT COALESCE(sum(balance_paise),0) FROM wallets) AS total_wallet_liability_paise,
  (SELECT COALESCE(sum(amount_paise),0) FROM partner_earnings WHERE status='PENDING_PAYOUT') AS unpaid_partner_earnings_paise
WHERE is_admin();
ALTER VIEW vw_admin_dashboard_stats SET (security_invoker = true);

-- ═══ 2. PAYMENTS — incoming wallet top-ups with the fan behind them ═══
CREATE VIEW vw_admin_payments AS
SELECT o.id AS topup_id, o.profile_id, p.full_name AS fan_name, p.email,
       o.credit_paise, o.gst_paise, o.amount_paise, o.status,
       o.razorpay_order_id, o.razorpay_payment_id, o.error_message,
       o.transaction_id, o.created_at, o.updated_at
FROM topup_orders o
JOIN profiles p ON p.id = o.profile_id
WHERE is_admin();
ALTER VIEW vw_admin_payments SET (security_invoker = true);

-- ═══ 3. TRANSACTIONS LEDGER — full money-movement audit, with the party
--      derived from the wallet leg (transactions don't FK a profile directly;
--      the affected user is whichever wallet the entry touched). ═══
CREATE VIEW vw_admin_transactions AS
SELECT t.id AS transaction_id, t.type, t.status, t.amount_paise, t.refund_reason,
       t.external_ref, t.created_at,
       (SELECT w.profile_id FROM ledger_entries le JOIN wallets w ON w.id = le.wallet_id
          WHERE le.transaction_id = t.id LIMIT 1) AS wallet_profile_id,
       (SELECT string_agg(le.account || ':' || le.delta_paise, ', ' ORDER BY le.account)
          FROM ledger_entries le WHERE le.transaction_id = t.id) AS ledger_legs
FROM transactions t
WHERE is_admin();
ALTER VIEW vw_admin_transactions SET (security_invoker = true);

-- ═══ 4. PROMO CODES — management list with REAL usage rollups, not just the
--      denormalized counter (Promo & Referrals screen). ═══
CREATE VIEW vw_admin_promo_codes AS
SELECT pc.id, pc.code, pc.description, pc.discount_type, pc.discount_value, pc.applies_to,
       pc.max_uses_total, pc.max_uses_per_user, pc.current_total_uses,
       pc.min_booking_paise, pc.start_date, pc.expiry_date, pc.is_active,
       (SELECT count(DISTINCT u.fan_id) FROM promo_code_usages u WHERE u.promo_code_id = pc.id) AS unique_users,
       (SELECT COALESCE(sum(u.discount_paise),0) FROM promo_code_usages u WHERE u.promo_code_id = pc.id) AS total_discount_given_paise,
       (CASE WHEN NOT pc.is_active THEN 'INACTIVE'
             WHEN pc.expiry_date IS NOT NULL AND pc.expiry_date < now() THEN 'EXPIRED'
             WHEN pc.max_uses_total IS NOT NULL AND pc.current_total_uses >= pc.max_uses_total THEN 'EXHAUSTED'
             ELSE 'ACTIVE' END) AS effective_status,
       pc.created_at
FROM promo_codes pc
WHERE is_admin();
ALTER VIEW vw_admin_promo_codes SET (security_invoker = true);

-- ═══ 5. REFERRALS — referral program tracking (both parties resolved) ═══
CREATE VIEW vw_admin_referrals AS
SELECT r.id, r.referrer_id, rp.full_name AS referrer_name, rp.email AS referrer_email,
       r.referee_id, ep.full_name AS referee_name, ep.email AS referee_email,
       r.code_used, r.status, r.referrer_reward_paise, r.referee_reward_paise,
       r.referrer_credited_at, r.referee_credited_at, r.created_at
FROM referrals r
JOIN profiles rp ON rp.id = r.referrer_id
LEFT JOIN profiles ep ON ep.id = r.referee_id
WHERE is_admin();
ALTER VIEW vw_admin_referrals SET (security_invoker = true);

-- ═══ 6. MODERATION QUEUE — the reports table (built the resolve RPC in 0024,
--      but there was no way to SEE the queue). Polymorphic target_type is
--      surfaced as-is; admin drills into the specific object by id. ═══
CREATE VIEW vw_admin_reports_queue AS
SELECT r.id, r.reporter_id, rp.full_name AS reporter_name,
       r.target_type, r.target_id, r.reason, r.details, r.status,
       r.resolution, r.refund_paise, r.resolved_by, xp.full_name AS resolved_by_name,
       r.resolved_at, r.created_at
FROM reports r
JOIN profiles rp ON rp.id = r.reporter_id
LEFT JOIN profiles xp ON xp.id = r.resolved_by
WHERE is_admin();
ALTER VIEW vw_admin_reports_queue SET (security_invoker = true);

-- ═══ 7. DISPUTES — chargeback queue, affected user derived from the txn ═══
CREATE VIEW vw_admin_disputes AS
SELECT d.id, d.transaction_id, d.razorpay_dispute_id, d.amount_paise, d.reason,
       d.status, d.opened_at, d.resolved_at,
       (SELECT w.profile_id FROM ledger_entries le JOIN wallets w ON w.id = le.wallet_id
          WHERE le.transaction_id = d.transaction_id LIMIT 1) AS affected_profile_id
FROM disputes d
WHERE is_admin();
ALTER VIEW vw_admin_disputes SET (security_invoker = true);

-- ═══ 8. KYC MANAGEMENT — ALL submitted KYC (any state), not just pending.
--      The pending view stays as the actionable queue; this is the full
--      management/review surface the screen title implies. ═══
CREATE VIEW vw_admin_kyc_management AS
SELECT p.id AS profile_id, p.full_name, p.email, p.role, p.verification_status,
       p.kyc_submitted_at, p.kyc_verified_at, p.kyc_verified_by_admin_id, p.kyc_rejection_reason,
       (SELECT count(*) FROM kyc_documents d WHERE d.profile_id = p.id) AS document_count
FROM profiles p
WHERE p.verification_status <> 'NOT_SUBMITTED' AND is_admin();
ALTER VIEW vw_admin_kyc_management SET (security_invoker = true);

-- ═══ 9. ENRICH Manage Partners — the thin version couldn't actually manage a
--      partner (no lifetime money, no trust signals). Recreated richer.
--      DROP first: CREATE OR REPLACE cannot reorder/rename existing columns. ═══
DROP VIEW vw_admin_manage_partners;
CREATE VIEW vw_admin_manage_partners AS
SELECT pp.profile_id, pp.display_name, p.email, p.mobile_number, p.account_status,
       p.verification_status, pp.status AS partner_status, pp.is_active, pp.vacation_mode,
       pp.is_premium, pp.is_featured, pp.commission_rate, pp.approved_at,
       (SELECT array_agg(c.slug) FROM partner_categories pc JOIN categories c ON c.id = pc.category_id
          WHERE pc.partner_id = pp.profile_id) AS categories,
       (SELECT count(*) FROM partner_services s WHERE s.partner_id = pp.profile_id AND s.is_active) AS active_services_count,
       (SELECT count(*) FROM bookings b WHERE b.partner_id = pp.profile_id AND b.status = 'COMPLETED_SUCCESSFUL') AS completed_bookings,
       (SELECT COALESCE(sum(amount_paise),0) FROM partner_earnings e WHERE e.partner_id = pp.profile_id AND e.status <> 'REVERSED') AS lifetime_earned_paise,
       (SELECT COALESCE(sum(amount_paise),0) FROM partner_earnings e WHERE e.partner_id = pp.profile_id AND e.status = 'PAID') AS total_paid_out_paise,
       (SELECT COALESCE(sum(amount_paise),0) FROM partner_earnings e WHERE e.partner_id = pp.profile_id AND e.status = 'PENDING_PAYOUT') AS pending_earnings_paise,
       (SELECT count(*) FROM reports r WHERE r.target_type='PROFILE' AND r.target_id = pp.profile_id) AS reports_against,
       EXISTS(SELECT 1 FROM payout_methods pm WHERE pm.partner_id = pp.profile_id AND pm.is_verified) AS has_verified_payout_method,
       p.created_at
FROM partner_profiles pp
JOIN profiles p ON p.id = pp.profile_id
WHERE is_admin();
ALTER VIEW vw_admin_manage_partners SET (security_invoker = true);

-- ═══ 10. ENRICH Shout-Outs — add the fields an admin needs to actually
--       handle one: the video, the reported flag, occasion, handler. ═══
DROP VIEW vw_admin_all_shout_outs;
CREATE VIEW vw_admin_all_shout_outs AS
SELECT s.id, s.fan_id, fp.full_name AS fan_name, s.partner_id, pp.display_name AS partner_name,
       s.recipient_name, s.gifter_name, s.occasion, s.price_paise, s.status,
       s.partner_video_storage_path, s.partner_video_submitted_at,
       s.delivered_video_link, s.delivered_at, s.admin_handler_id, s.admin_review_notes,
       EXISTS(SELECT 1 FROM reports r WHERE r.target_type='SHOUTOUT' AND r.target_id = s.id) AS is_reported,
       s.settle_at, s.created_at
FROM shout_out_requests s
JOIN profiles fp ON fp.id = s.fan_id
JOIN partner_profiles pp ON pp.profile_id = s.partner_id
WHERE is_admin();
ALTER VIEW vw_admin_all_shout_outs SET (security_invoker = true);

-- ═══ 11. USAGE analytics (the Reports & Analytics "Usage" tab) — daily
--       completed calls / answered questions / delivered shout-outs. ═══
CREATE MATERIALIZED VIEW mv_admin_daily_usage AS
SELECT u.day,
       sum(u.calls) AS completed_calls,
       sum(u.questions) AS answered_questions,
       sum(u.shoutouts) AS delivered_shoutouts
FROM (
  SELECT date_trunc('day', c.ended_at)::date AS day, 1 AS calls, 0 AS questions, 0 AS shoutouts
    FROM calls c WHERE c.attempt_status='COMPLETED_SUCCESSFUL' AND c.ended_at IS NOT NULL
  UNION ALL
  SELECT date_trunc('day', w.closed_at)::date, 0, 1, 0
    FROM conversation_windows w WHERE w.status='ANSWERED' AND w.closed_at IS NOT NULL
  UNION ALL
  SELECT date_trunc('day', s.delivered_at)::date, 0, 0, 1
    FROM shout_out_requests s WHERE s.delivered_at IS NOT NULL
) u
GROUP BY u.day;
CREATE UNIQUE INDEX mv_admin_daily_usage_day_idx ON mv_admin_daily_usage (day);
-- revoke the 0025 default-privilege auto-grant; expose only via wrapper
REVOKE ALL ON mv_admin_daily_usage FROM zudue_app;

CREATE VIEW vw_admin_usage AS SELECT * FROM mv_admin_daily_usage WHERE is_admin();

GRANT SELECT ON vw_admin_dashboard_stats, vw_admin_payments, vw_admin_transactions,
  vw_admin_promo_codes, vw_admin_referrals, vw_admin_reports_queue, vw_admin_disputes,
  vw_admin_kyc_management, vw_admin_usage TO zudue_app;

COMMIT;

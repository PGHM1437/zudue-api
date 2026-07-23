-- 0027 · Admin-facing consolidated read models.
--
-- Reconsidered per your pushback: the 20 views dropped in 0019 were correctly
-- removed (single-table, per-user wrappers — SELECT * FROM x WHERE
-- fan_id=$1 gains nothing from a view; a plain view provides ZERO caching or
-- "fewer DB calls," it's inlined into the query plan identically either way).
-- But the ADMIN-facing ones were a different animal: an activity-intense
-- panel managing partners/fans/KYC/payouts/moderation genuinely needs one
-- query that already joins several tables into the exact row-shape a list
-- screen renders — that's real consolidation, not a wrapper. Recreating those,
-- this time with security_invoker=true from creation (0026 found out the
-- hard way what happens without it).
--
-- These are admin-only in every underlying table's RLS (every policy touched
-- here already includes "OR is_admin()"), so with security_invoker=true and
-- an admin session's GUC set, these views correctly see everything — no new
-- RLS policy needed, unlike the counterparty-read gap found in 0026.

BEGIN;

CREATE VIEW vw_admin_manage_partners AS
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
JOIN profiles p ON p.id = pp.profile_id;
ALTER VIEW vw_admin_manage_partners SET (security_invoker = true);

CREATE VIEW vw_admin_manage_fans AS
SELECT p.id AS profile_id, p.full_name, p.email, p.mobile_number, p.account_status,
       p.verification_status, p.created_at,
       w.balance_paise, w.bonus_balance_paise,
       (SELECT count(*) FROM bookings b WHERE b.fan_id = p.id) AS total_bookings,
       (SELECT count(*) FROM reports r WHERE r.target_id = p.id AND r.target_type = 'PROFILE') AS reports_against
FROM profiles p
LEFT JOIN wallets w ON w.profile_id = p.id
WHERE p.role = 'FAN';
ALTER VIEW vw_admin_manage_fans SET (security_invoker = true);

CREATE VIEW vw_admin_pending_kyc_verifications AS
SELECT p.id AS profile_id, p.full_name, p.email, p.role, p.verification_status, p.kyc_submitted_at,
       (SELECT jsonb_agg(jsonb_build_object('type', d.document_type, 'path', d.storage_path,
          'file_name', d.file_name, 'uploaded_at', d.uploaded_at))
        FROM kyc_documents d WHERE d.profile_id = p.id) AS documents
FROM profiles p
WHERE p.verification_status = 'PENDING_VERIFICATION';
ALTER VIEW vw_admin_pending_kyc_verifications SET (security_invoker = true);

CREATE VIEW vw_admin_pending_partner_applications AS
SELECT a.id, a.applicant_full_name, a.email, a.mobile_number, a.primary_social_link,
       a.expertise_description, a.status, a.admin_notes, a.submitted_at, a.profile_id
FROM partner_applications a
WHERE a.status NOT IN ('ACTIVE', 'REJECTED_INITIAL', 'REJECTED_KYC', 'REJECTED_FINAL');
ALTER VIEW vw_admin_pending_partner_applications SET (security_invoker = true);

CREATE VIEW vw_admin_pending_withdrawals AS
SELECT po.id AS payout_id, po.partner_id, pp.display_name, po.amount_paise, po.status, po.requested_at,
       pm.method_type, pm.account_holder_name, pm.account_number, pm.ifsc_code, pm.bank_name,
       pm.upi_id, pm.is_verified
FROM partner_payouts po
JOIN partner_profiles pp ON pp.profile_id = po.partner_id
JOIN payout_methods pm ON pm.id = po.payout_method_id
WHERE po.status IN ('REQUESTED', 'APPROVED', 'PROCESSING');
ALTER VIEW vw_admin_pending_withdrawals SET (security_invoker = true);

CREATE VIEW vw_admin_processed_payouts AS
SELECT po.id AS payout_id, po.partner_id, pp.display_name, po.amount_paise, po.status,
       po.reference, po.processed_at, pm.method_type
FROM partner_payouts po
JOIN partner_profiles pp ON pp.profile_id = po.partner_id
JOIN payout_methods pm ON pm.id = po.payout_method_id
WHERE po.status IN ('PAID', 'REJECTED');
ALTER VIEW vw_admin_processed_payouts SET (security_invoker = true);

CREATE VIEW vw_admin_wallet_overview AS
SELECT count(*) AS total_wallets,
       COALESCE(sum(balance_paise), 0) AS total_balance_paise,
       COALESCE(sum(bonus_balance_paise), 0) AS total_bonus_paise,
       COALESCE(sum(balance_paise) FILTER (WHERE balance_paise > 0), 0) AS total_positive_balance_paise
FROM wallets;
ALTER VIEW vw_admin_wallet_overview SET (security_invoker = true);

CREATE VIEW vw_admin_all_video_calls AS
SELECT b.id AS booking_id, b.fan_id, fp.full_name AS fan_name, b.partner_id, pp.display_name AS partner_name,
       b.scheduled_date, b.selected_duration, b.price_paise, b.status AS booking_status,
       lc.id AS call_id, lc.attempt_status AS call_status, lc.started_at, lc.ended_at, lc.actual_duration_seconds
FROM bookings b
JOIN profiles fp ON fp.id = b.fan_id
JOIN partner_profiles pp ON pp.profile_id = b.partner_id
LEFT JOIN LATERAL (
  SELECT * FROM calls c WHERE c.booking_id = b.id ORDER BY c.partner_initiated_at DESC LIMIT 1
) lc ON true;
ALTER VIEW vw_admin_all_video_calls SET (security_invoker = true);

CREATE VIEW vw_admin_all_shout_outs AS
SELECT s.id, s.fan_id, fp.full_name AS fan_name, s.partner_id, pp.display_name AS partner_name,
       s.recipient_name, s.price_paise, s.status, s.created_at, s.delivered_at
FROM shout_out_requests s
JOIN profiles fp ON fp.id = s.fan_id
JOIN partner_profiles pp ON pp.profile_id = s.partner_id;
ALTER VIEW vw_admin_all_shout_outs SET (security_invoker = true);

CREATE VIEW vw_admin_manage_questions AS
SELECT w.id AS window_id, c.fan_id, fp.full_name AS fan_name, c.partner_id, pp.display_name AS partner_name,
       w.kind, w.charge_paise, w.status, w.opened_at, w.response_deadline,
       (SELECT count(*) FROM messages m WHERE m.window_id = w.id) AS message_count
FROM conversation_windows w
JOIN conversations c ON c.id = w.conversation_id
JOIN profiles fp ON fp.id = c.fan_id
JOIN partner_profiles pp ON pp.profile_id = c.partner_id;
ALTER VIEW vw_admin_manage_questions SET (security_invoker = true);

GRANT SELECT ON vw_admin_manage_partners, vw_admin_manage_fans, vw_admin_pending_kyc_verifications,
  vw_admin_pending_partner_applications, vw_admin_pending_withdrawals, vw_admin_processed_payouts,
  vw_admin_wallet_overview, vw_admin_all_video_calls, vw_admin_all_shout_outs, vw_admin_manage_questions
  TO zudue_app;

-- ── Analytics: the 2 materialized views, real caching this time ──
-- Unlike the list views above, these are aggregates where a few minutes/hours
-- of staleness is correct and expected (a revenue trend chart doesn't need
-- to be live to the second) — the actual use case "refreshes occasionally"
-- describes. Recomputing SUM/COUNT over all of `transactions`/`profiles` on
-- every Reports-page load doesn't scale; a scheduled REFRESH does.
CREATE MATERIALIZED VIEW mv_admin_daily_financial_summary AS
SELECT date_trunc('day', t.created_at)::date AS day,
       COALESCE(sum(t.amount_paise) FILTER (WHERE t.type = 'TOPUP' AND t.status = 'SUCCESSFUL'), 0) AS gross_topups_paise,
       COALESCE(sum(t.amount_paise) FILTER (WHERE t.type = 'PARTNER_EARNING' AND t.status = 'SUCCESSFUL'), 0) AS partner_earnings_paise,
       COALESCE(sum(t.amount_paise) FILTER (WHERE t.type = 'REFUND' AND t.status = 'SUCCESSFUL'), 0) AS refunds_paise,
       COALESCE(sum(t.amount_paise) FILTER (WHERE t.type = 'PAYOUT_DEBIT' AND t.status = 'SUCCESSFUL'), 0) AS payouts_paise,
       count(*) FILTER (WHERE t.type = 'TOPUP' AND t.status = 'SUCCESSFUL') AS topup_count
FROM transactions t
GROUP BY 1;
CREATE UNIQUE INDEX mv_admin_daily_financial_summary_day_idx ON mv_admin_daily_financial_summary (day);

CREATE MATERIALIZED VIEW mv_admin_user_growth_daily AS
SELECT date_trunc('day', created_at)::date AS day,
       count(*) FILTER (WHERE role = 'FAN') AS new_fans,
       count(*) FILTER (WHERE role = 'PARTNER') AS new_partners
FROM profiles
GROUP BY 1;
CREATE UNIQUE INDEX mv_admin_user_growth_daily_day_idx ON mv_admin_user_growth_daily (day);

-- Migration 0025's `ALTER DEFAULT PRIVILEGES ... ON TABLES` silently includes
-- materialized views (confirmed via pg_class.relacl, not
-- information_schema.role_table_grants — that catalog view doesn't cover
-- matviews at all, which is why checking it looked clean when it wasn't).
-- So zudue_app got automatic direct arwd access to both raw matviews the
-- instant they were created above — the opposite of intended. Revoke it
-- explicitly; access must go through the is_admin()-gated views below.
REVOKE ALL ON mv_admin_daily_financial_summary, mv_admin_user_growth_daily FROM zudue_app;

-- Materialized views cannot have RLS at all (Postgres limitation — confirmed
-- by the failed ALTER MATERIALIZED VIEW ... ENABLE ROW LEVEL SECURITY on
-- first attempt). Gating instead with a thin wrapping view using a blanket
-- WHERE is_admin() — correct here because this is an all-or-nothing gate
-- (admin sees every row, non-admin sees none), not per-row ownership
-- filtering, so it doesn't need security_invoker. Left at the DEFAULT
-- (security_invoker=false) deliberately: zudue_app has no direct grant on
-- the raw matview (just revoked above), only on this view, and the
-- ownership chain is what makes that work — the pre-RLS view-security
-- pattern, applied on purpose.
CREATE VIEW vw_admin_financial_summary AS
SELECT * FROM mv_admin_daily_financial_summary WHERE is_admin();

CREATE VIEW vw_admin_user_growth AS
SELECT * FROM mv_admin_user_growth_daily WHERE is_admin();

GRANT SELECT ON vw_admin_financial_summary, vw_admin_user_growth TO zudue_app;

COMMIT;

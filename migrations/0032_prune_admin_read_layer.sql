-- 0032 · Prune the admin read layer back to lean.
--
-- Course-correction. 0027/0030 over-built: materialized views paired with
-- wrapper views (two objects per analytic — the "two financial summaries"),
-- plus a set of single-table "views" that are just filtered reads. Grounding
-- against the reference frontend confirmed two things:
--   1. Admin analytics (revenue/payouts/KPIs) is computed ON DEMAND, not from
--      stored snapshots — so the materialized views are the wrong tool: they
--      add staleness + a refresh scheduler that was never wired, and surface
--      as UNRESTRICTED objects that can't carry RLS.
--   2. The screens that need a DB view need a genuine multi-table JOIN shape;
--      the rest (reports queue, disputes, referrals, promo list, a KPI tile
--      row) are single-table reads the backend does directly against tables
--      that already admin-gate via RLS.
--
-- Rule applied: a view earns its place only if it joins >=2 tables into a
-- shape a screen reuses. Everything else is a backend read-time query.
-- Net effect: 14 objects removed, 0 added. Analytics/reporting is unchanged
-- as a CAPABILITY — the data (transactions, ledger_entries, partner_earnings)
-- is all present; the backend aggregates it live (always fresh, no matview).

BEGIN;

-- Analytics: drop the 3 materialized views; CASCADE removes their wrapper
-- views (vw_admin_financial_summary / _usage / _user_growth).
DROP MATERIALIZED VIEW IF EXISTS mv_admin_daily_financial_summary CASCADE;
DROP MATERIALIZED VIEW IF EXISTS mv_admin_daily_usage CASCADE;
DROP MATERIALIZED VIEW IF EXISTS mv_admin_user_growth_daily CASCADE;

-- Invented single-table "views" — backend reads these tables directly
-- (RLS already restricts them to admins).
DROP VIEW IF EXISTS vw_admin_dashboard_stats;
DROP VIEW IF EXISTS vw_admin_disputes;
DROP VIEW IF EXISTS vw_admin_reports_queue;
DROP VIEW IF EXISTS vw_admin_referrals;
DROP VIEW IF EXISTS vw_admin_payments;
DROP VIEW IF EXISTS vw_admin_transactions;
DROP VIEW IF EXISTS vw_admin_kyc_management;
DROP VIEW IF EXISTS vw_admin_promo_codes;

COMMIT;

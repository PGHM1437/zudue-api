-- 0025 · Production hardening.
--
-- Finding 1: call_events never got RLS enabled — the one table 0011 missed
-- despite its own header claiming "RLS on every table." Fixed with a policy
-- mirroring calls' party-based access (fan/partner of the underlying call, or admin).
--
-- Finding 2 (the important one): every migration and every test so far has
-- connected as a Postgres superuser (supabase_admin locally, postgres on
-- Supabase). Superusers and table owners BYPASS RLS by Postgres design,
-- regardless of policy content. The 0023/0024 authorization fixes are
-- role-independent and genuinely proven (they check a session GUC via
-- current_user_id()/is_admin(), not RLS), but the RLS policies themselves
-- have never been exercised as a real restriction on direct table reads —
-- if the live API connects using the postgres credential, RLS silently does
-- nothing and every direct SELECT/UPDATE sees/touches every row.
--
-- Fix: a dedicated least-privilege role with no superuser, no ownership, no
-- BYPASSRLS — the role the API must actually connect as for RLS to mean
-- anything. Table-level grants are intentionally broad (SELECT/INSERT/UPDATE/
-- DELETE on everything); RLS policies are what narrow it per row, and a table
-- with RLS enabled but no matching policy for an operation denies it entirely
-- regardless of the table-level grant — that's what already protects
-- RPC-only tables like bookings/calls/wallets/ledger_entries/admin_profiles,
-- which have no owner-write policy at all.

BEGIN;

ALTER TABLE call_events ENABLE ROW LEVEL SECURITY;
CREATE POLICY call_event_party ON call_events FOR SELECT USING (
  EXISTS (SELECT 1 FROM calls c WHERE c.id = call_events.call_id
          AND (c.fan_id = current_user_id() OR c.partner_id = current_user_id()))
  OR is_admin());

DO $$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'zudue_app') THEN
    EXECUTE format('CREATE ROLE zudue_app LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOBYPASSRLS PASSWORD %L',
      current_setting('zudue.app_role_password'));
  END IF;
END $$;

GRANT USAGE ON SCHEMA public TO zudue_app;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO zudue_app;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA public TO zudue_app;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO zudue_app;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT EXECUTE ON FUNCTIONS TO zudue_app;

COMMIT;

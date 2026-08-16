-- 0071 · Missing columns fix (M5).
--
-- Originally proposed 2 new audit tables (admin_action_logs,
-- withdrawal_audit_log) plus 2 calls columns. Revised after live review:
--
-- The two proposed tables are dropped from this migration. This schema
-- already has a single generic `audit_log` (actor_id, actor_role, action,
-- target_type, target_id, old_value, new_value) that every admin RPC in the
-- codebase already writes to — confirmed live in rpc_admin_verify_payout_method,
-- rpc_admin_reset_payout_methods, rpc_admin_recover_call (0076), and others.
-- Two more parallel per-domain audit tables would duplicate a mechanism
-- that already works, and nothing in the codebase was going to write to
-- them (grepped apps/ — zero references). If withdrawal actions need
-- fields audit_log doesn't carry (ip_address, user_agent), extend audit_log
-- or add those as optional columns on it — don't fork the audit trail.
--
-- The original version also used `CREATE POLICY IF NOT EXISTS`, which is not
-- valid PostgreSQL syntax (no such clause exists for CREATE POLICY), and
-- checked `auth.uid()` — a Supabase-Auth-JWT convention this codebase
-- doesn't use. This app's RLS runs on current_user_id(), which reads the
-- app.user_id session var the API sets per request; that's now moot since
-- the tables are gone, but the same mistake must not recur if either table
-- comes back.
--
-- What's left: the two calls columns, kept as cheap additive nullable
-- columns. Neither has a writer or reader yet (metadata is a general
-- debugging escape hatch; remaining_duration_seconds would need a live
-- ticking updater to stay accurate and the mobile call screen currently has
-- no countdown UI reading it — grepped apps/mobile/lib, no call-screen
-- countdown exists). They're safe to leave for whichever feature needs them
-- next; unlike the tables, a nullable column costs nothing sitting unused.

BEGIN;

ALTER TABLE public.calls
  ADD COLUMN IF NOT EXISTS metadata JSONB;

CREATE INDEX IF NOT EXISTS idx_calls_metadata ON public.calls USING GIN (metadata);

ALTER TABLE public.calls
  ADD COLUMN IF NOT EXISTS remaining_duration_seconds INTEGER;

INSERT INTO _migrations (name) VALUES ('0071_missing_tables_and_columns.sql')
  ON CONFLICT (name) DO NOTHING;

COMMIT;

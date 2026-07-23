-- 0052 · Lock down the migration ledger.
--
-- Introduced by my own 0050: `_migrations` was the ONLY table in the schema
-- without RLS, and a default ACL on the public schema
--     zudue_app=arwd/supabase_admin
-- silently granted the least-privilege application role INSERT/SELECT/UPDATE/
-- DELETE on it the moment it was created.
--
-- Why this is more than cosmetic: the ledger is what stops `pnpm db:migrate`
-- replaying all migrations from 0001. Several are not re-runnable (RENAME
-- COLUMN, ADD CONSTRAINT, CREATE UNIQUE INDEX without IF NOT EXISTS), so a
-- truncated ledger re-arms exactly the half-migration failure 0050 removed.
-- Anything able to DELETE from this table can therefore break the next deploy.
-- The application has no business reading or writing it at all — migrate.mjs
-- connects as the owner via DATABASE_URL_MIGRATE, and table owners bypass RLS.
--
-- Worth noting the broader shape this exposes: that default ACL means EVERY
-- new table in public is born with full app-role write access, and RLS is the
-- only thing holding it back. That is a deliberate Supabase-style posture
-- (grant broadly, restrict with RLS) — but it means "every table has RLS" is
-- not hygiene, it is the actual security boundary. A future table created
-- without RLS is wide open by default, not closed by default.

BEGIN;

REVOKE ALL ON TABLE public._migrations FROM zudue_app;

-- ENABLE, deliberately NOT FORCE. FORCE would subject the table OWNER to RLS
-- as well, and the owner is exactly who migrate.mjs connects as to INSERT each
-- applied migration — forcing it would break the ledger this migration exists
-- to protect.
ALTER TABLE public._migrations ENABLE ROW LEVEL SECURITY;

-- Admins may read deployment history for support/debugging; nobody but the
-- owner may write it.
CREATE POLICY migrations_admin_read ON public._migrations
  FOR SELECT USING (public.is_admin());

INSERT INTO _migrations (name) VALUES ('0052_protect_migration_ledger.sql')
  ON CONFLICT (name) DO NOTHING;

COMMIT;

-- 0000 · Bootstrap roles Supabase auto-creates on every project.
--
-- These migrations were authored against Supabase, which always provisions
-- `anon`, `authenticated`, and `service_role` Postgres roles automatically.
-- On a plain PostgreSQL instance (OCI Database with PostgreSQL) those roles
-- don't exist, so the GRANT ... TO authenticated / TO service_role statements
-- in 0062, 0063, 0069, 0070, and 0076 would fail with "role does not exist".
--
-- `anon` isn't referenced by any GRANT in this schema, but it's created here
-- too since it's part of the same Supabase convention and costs nothing to
-- have present if something assumes it later.
--
-- NOLOGIN: these are grantee roles for privilege bundling, not the actual
-- application connection role (that's zudue_app, created in 0025).

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon') THEN
    CREATE ROLE anon NOLOGIN;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') THEN
    CREATE ROLE authenticated NOLOGIN;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'service_role') THEN
    CREATE ROLE service_role NOLOGIN;
  END IF;
END
$$;

#!/usr/bin/env node
// Applies the certified SQL migrations in order against DATABASE_URL_MIGRATE
// (the direct/owner Neon connection). The app itself connects as zudue_app and
// never runs DDL. Idempotent via a _migrations ledger table.
import { readdirSync, readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import postgres from 'postgres';

const __dirname = dirname(fileURLToPath(import.meta.url));
const dir = join(__dirname, '..', 'migrations');
const url = process.env.DATABASE_URL_MIGRATE || process.env.DATABASE_URL;
if (!url) { console.error('DATABASE_URL_MIGRATE not set'); process.exit(1); }

// onnotice suppressed: Postgres NOTICEs (e.g. "relation already exists,
// skipping") are printed as raw objects and drown the guard messages below.
const sql = postgres(url, { max: 1, onnotice: () => {} });

const APP_ROLE_PW = process.env.ZUDUE_APP_ROLE_PASSWORD;

async function main() {
  await sql`create table if not exists _migrations (name text primary key, applied_at timestamptz default now())`;

  // Guard: an EMPTY ledger against a schema that already has tables means the
  // ledger was lost, not that this is a fresh database. Replaying from 0001
  // would hit the non-re-runnable migrations (RENAME COLUMN, ADD CONSTRAINT,
  // CREATE UNIQUE INDEX) and abort partway, leaving the schema half-migrated.
  // Refuse instead, and say how to recover.
  const [{ ledger_rows }] = await sql`select count(*)::int as ledger_rows from _migrations`;
  const [{ app_tables }] = await sql`
    select count(*)::int as app_tables from pg_class c join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relkind = 'r' and c.relname <> '_migrations'`;
  if (ledger_rows === 0 && app_tables > 0) {
    console.error(
      `refusing to migrate: _migrations is empty but the schema already has ${app_tables} tables.\n` +
      `Replaying from 0001 would abort on a non-re-runnable migration and leave the schema half-applied.\n` +
      `If this database really is up to date, backfill the ledger first:\n` +
      `  INSERT INTO _migrations (name) SELECT unnest(ARRAY[...filenames...]) ON CONFLICT DO NOTHING;`);
    await sql.end();
    process.exit(1);
  }

  // Guard: FORCE ROW LEVEL SECURITY applies RLS to the table OWNER too — which
  // is this script. Recording an applied migration would then fail silently
  // mid-run. (Nearly shipped exactly this in 0052.)
  const [{ forced }] = await sql`select relforcerowsecurity as forced from pg_class where relname = '_migrations'`;
  if (forced) {
    console.error(
      'refusing to migrate: _migrations has FORCE ROW LEVEL SECURITY, so the owner cannot record applied migrations.\n' +
      '  ALTER TABLE public._migrations NO FORCE ROW LEVEL SECURITY;');
    await sql.end();
    process.exit(1);
  }

  const applied = new Set((await sql`select name from _migrations`).map((r) => r.name));
  const files = readdirSync(dir).filter((f) => f.endsWith('.sql')).sort();
  for (const f of files) {
    if (applied.has(f)) { console.log(`· skip ${f}`); continue; }
    let ddl = readFileSync(join(dir, f), 'utf8');
    if (f.includes('production_hardening') && APP_ROLE_PW) {
      // 0025 reads the app-role password from a GUC set on the session.
      ddl = `set zudue.app_role_password = '${APP_ROLE_PW}';\n` + ddl;
    }
    process.stdout.write(`→ apply ${f} ... `);
    await sql.unsafe(ddl);
    // ON CONFLICT because a migration may legitimately record itself: 0050
    // backfills the whole ledger (including its own name) so already-live
    // databases stop replaying. Without this, a FRESH database dies here on a
    // duplicate key — which is exactly what the CI schema job caught.
    await sql`insert into _migrations (name) values (${f}) on conflict (name) do nothing`;
    console.log('ok');
  }
  console.log('migrations up to date');
  await sql.end();
}
main().catch((e) => { console.error(e); process.exit(1); });

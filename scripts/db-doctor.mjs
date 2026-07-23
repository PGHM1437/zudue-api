#!/usr/bin/env node
/**
 * db-doctor — asserts the database invariants that manual review kept missing.
 *
 * Every check here exists because something actually went wrong, not because it
 * sounded prudent:
 *
 *  · EXT_SCHEMA  A function hard-coded `public.gen_random_bytes(...)`. pgcrypto
 *                lives in `public` locally but in `extensions` on Supabase, and
 *                the function pinned search_path='', so account deletion failed
 *                in production ONLY. Local testing could never have caught it —
 *                local is where it works.
 *  · RLS_ALL     A default ACL grants the app role INSERT/UPDATE/DELETE on every
 *                new table in `public`. RLS is therefore not hygiene, it is the
 *                security boundary; a table without it is open, not closed.
 *  · LEDGER_*    The `_migrations` ledger is what stops a deploy replaying
 *                non-re-runnable migrations (RENAME COLUMN, ADD CONSTRAINT).
 *                It must exist, match the directory, and stay writable by the
 *                owner — FORCE ROW LEVEL SECURITY would silently break that.
 *  · MONEY_*     Double-entry invariants. Cheap to assert, expensive to discover.
 *
 * Usage:
 *   node scripts/db-doctor.mjs                  # uses DATABASE_URL_MIGRATE || DATABASE_URL
 *   node scripts/db-doctor.mjs "postgres://..." # explicit target
 *
 * Exits non-zero if any invariant is violated, so CI and the deploy path fail
 * loudly instead of shipping a latent production-only bug.
 */
import { readdirSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import postgres from 'postgres';

const __dirname = dirname(fileURLToPath(import.meta.url));
const migrationsDir = join(__dirname, '..', 'migrations');

const url = process.argv[2] || process.env.DATABASE_URL_MIGRATE || process.env.DATABASE_URL;
if (!url) {
  console.error('db-doctor: no connection string (arg, DATABASE_URL_MIGRATE or DATABASE_URL)');
  process.exit(2);
}

const sql = postgres(url, { max: 1, prepare: false, onnotice: () => {} });

const failures = [];
const warnings = [];
const fail = (code, msg, rows) => failures.push({ code, msg, rows });
const warn = (code, msg, rows) => warnings.push({ code, msg, rows });

/** Rows -> compact one-line summary for the report. */
const brief = (rows, n = 8) => {
  const vals = rows.map((r) => Object.values(r).join('.'));
  return vals.length > n ? `${vals.slice(0, n).join(', ')} … (+${vals.length - n} more)` : vals.join(', ');
};

async function main() {
  // ── EXT_SCHEMA ────────────────────────────────────────────────────────
  // Generalises the pgcrypto outage: no function may reference an
  // extension-owned function through a hard-coded schema. Extensions live in
  // different schemas per environment, so such a reference is a production
  // landmine that local testing cannot surface.
  const extRefs = await sql`
    with ext_fns as (
      select distinct p.proname
      from pg_depend d
      join pg_extension e on e.oid = d.refobjid and d.refclassid = 'pg_extension'::regclass
      join pg_proc p on p.oid = d.objid and d.classid = 'pg_proc'::regclass
    ),
    app_fns as (
      select p.proname, p.prosrc
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'public'
        and not exists (
          select 1 from pg_depend d
          where d.objid = p.oid and d.classid = 'pg_proc'::regclass
            and d.refclassid = 'pg_extension'::regclass)
    )
    select a.proname as function, e.proname as extension_function
    from app_fns a join ext_fns e
      on a.prosrc like '%public.' || e.proname || '(%'
    order by 1, 2`;
  if (extRefs.length)
    fail('EXT_SCHEMA',
      'function(s) call an extension function through a hard-coded schema — breaks where the extension is installed elsewhere',
      extRefs);

  // ── RLS_ALL ───────────────────────────────────────────────────────────
  const noRls = await sql`
    select c.relname as table_name
    from pg_class c join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relkind = 'r' and not c.relrowsecurity
    order by 1`;
  if (noRls.length) fail('RLS_ALL', 'table(s) without row level security', noRls);

  const rlsNoPolicy = await sql`
    select c.relname as table_name
    from pg_class c join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relkind = 'r' and c.relrowsecurity
      and not exists (select 1 from pg_policy p where p.polrelid = c.oid)
      and c.relname <> '_migrations'   -- intentionally owner-only, see 0052
    order by 1`;
  if (rlsNoPolicy.length)
    fail('RLS_NO_POLICY', 'RLS enabled but no policy — table is silently inaccessible', rlsNoPolicy);

  // ── SECDEF_PATH ───────────────────────────────────────────────────────
  const looseSecdef = await sql`
    select p.proname as function
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.prosecdef
      and not exists (select 1 from unnest(coalesce(p.proconfig, '{}')) c where c like 'search_path=%')
    order by 1`;
  if (looseSecdef.length)
    fail('SECDEF_PATH', 'SECURITY DEFINER function(s) without a pinned search_path (privilege escalation risk)', looseSecdef);

  // ── VIEW_INVOKER ──────────────────────────────────────────────────────
  const definerViews = await sql`
    select c.relname as view_name
    from pg_class c join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relkind = 'v'
      and coalesce((select option_value from pg_options_to_table(c.reloptions)
                    where option_name = 'security_invoker'), 'false') <> 'true'
    order by 1`;
  if (definerViews.length)
    fail('VIEW_INVOKER', 'view(s) run as owner and bypass RLS on their base tables', definerViews);

  // ── RPC_OVERLOAD ──────────────────────────────────────────────────────
  const overloads = await sql`
    select proname as function, count(*)::int as versions
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and proname like 'rpc\\_%'
    group by proname having count(*) > 1
    order by 1`;
  if (overloads.length)
    fail('RPC_OVERLOAD', 'duplicate RPC overloads — an ambiguous money entrypoint', overloads);

  // ── LEDGER_* ──────────────────────────────────────────────────────────
  const [{ present }] = await sql`
    select count(*)::int as present from pg_class c join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relname = '_migrations'`;

  if (!present) {
    fail('LEDGER_MISSING',
      'no _migrations ledger — `pnpm db:migrate` would replay every migration from 0001 and abort on the non-re-runnable ones',
      [{ table: '_migrations' }]);
  } else {
    const [{ forced }] = await sql`
      select relforcerowsecurity as forced from pg_class where relname = '_migrations'`;
    if (forced)
      fail('LEDGER_FORCED',
        'FORCE ROW LEVEL SECURITY on _migrations — subjects the OWNER to RLS, so the migration runner can no longer record applied migrations',
        [{ table: '_migrations' }]);

    const applied = new Set((await sql`select name from _migrations`).map((r) => r.name));
    const onDisk = readdirSync(migrationsDir).filter((f) => f.endsWith('.sql')).sort();
    const missing = onDisk.filter((f) => !applied.has(f));
    const phantom = [...applied].filter((f) => !onDisk.includes(f)).sort();
    if (missing.length)
      fail('LEDGER_BEHIND', 'migration file(s) on disk not recorded as applied — next deploy will run them',
        missing.map((f) => ({ file: f })));
    if (phantom.length)
      warn('LEDGER_PHANTOM', 'ledger names with no matching file (renamed or deleted migration)',
        phantom.map((f) => ({ name: f })));
  }

  // ── MONEY_* ───────────────────────────────────────────────────────────
  const unbalanced = await sql`
    select transaction_id from public.ledger_entries
    group by transaction_id having sum(delta_paise) <> 0 limit 20`;
  if (unbalanced.length) fail('MONEY_LEDGER_UNBALANCED', 'transaction(s) whose ledger legs do not sum to zero', unbalanced);

  const walletDrift = await sql`
    select w.id as wallet_id
    from public.wallets w
    left join (select wallet_id, sum(delta_paise) s from public.ledger_entries
               where wallet_id is not null group by wallet_id) l on l.wallet_id = w.id
    where w.balance_paise <> coalesce(l.s, 0) limit 20`;
  if (walletDrift.length)
    fail('MONEY_WALLET_DRIFT', 'wallet cached balance disagrees with its ledger entries', walletDrift);

  const paidNoUtr = await sql`
    select id as payout_id from public.partner_payouts
    where status = 'PAID' and (utr is null or utr = '') limit 20`;
  if (paidNoUtr.length)
    fail('MONEY_PAYOUT_NO_UTR', 'payout(s) marked PAID with no UTR — no evidence money left the bank', paidNoUtr);

  const badIdentity = await sql`
    select id as booking_id from public.bookings
    where original_price_paise is not null
      and original_price_paise <> price_paise + coalesce(discount_paise, 0) limit 20`;
  if (badIdentity.length)
    fail('MONEY_PRICE_IDENTITY',
      'booking(s) where escrow(original) <> fan paid + platform funded — settlement would overpay the creator', badIdentity);

  // ── report ────────────────────────────────────────────────────────────
  const host = (() => { try { return new URL(url).host; } catch { return 'target'; } })();
  console.log(`db-doctor · ${host}`);
  for (const w of warnings) console.log(`  ⚠ ${w.code}: ${w.msg}\n      ${brief(w.rows)}`);
  if (!failures.length) {
    console.log(`  ✓ all invariants hold${warnings.length ? ` (${warnings.length} warning(s))` : ''}`);
    await sql.end();
    return;
  }
  for (const f of failures) console.error(`  ✗ ${f.code}: ${f.msg}\n      ${brief(f.rows)}`);
  console.error(`\ndb-doctor: ${failures.length} invariant(s) violated`);
  await sql.end();
  process.exit(1);
}

main().catch(async (e) => {
  console.error('db-doctor failed to run:', e.message);
  try { await sql.end(); } catch {}
  process.exit(2);
});

#!/usr/bin/env node
/**
 * make-admin — grant (or revoke) admin access to an existing account.
 *
 * WHY THIS EXISTS
 * Admin access is deliberately a closed loop: rpc_admin_create_admin calls
 * assert_admin_role('SUPER_ADMIN'), so only an admin can mint an admin. That is
 * correct for day-to-day use and useless for the FIRST one — a fresh database
 * has no admin, so the loop can never be entered from inside the app.
 *
 * This script breaks the loop the only legitimate way: by connecting as the
 * database OWNER (DATABASE_URL_MIGRATE), which is the same authority that runs
 * migrations. It is not a backdoor — anyone holding that credential can already
 * do anything. Once one admin exists, use the admin panel (Settings → Admins)
 * for the rest, so every subsequent grant is attributed and audited normally.
 *
 * ADMIN IS TWO THINGS, and both are required:
 *   1. profiles.role = 'ADMIN'   → what is_admin() checks (RLS + view gating)
 *   2. admin_profiles.admin_role → the TIER assert_admin_role() checks
 * Setting only one leaves a half-admin that passes RLS but fails every tiered
 * RPC (or vice versa), which is a confusing state to debug.
 *
 * USAGE
 *   node scripts/make-admin.mjs <email> [tier]     # default tier SUPER_ADMIN
 *   node scripts/make-admin.mjs <email> --revoke   # back to FAN, tier removed
 *   node scripts/make-admin.mjs --list             # show current admins
 *
 * The person must already have signed up in the app — this promotes an existing
 * account, it does not create auth credentials.
 */
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import { readFileSync, existsSync } from 'node:fs';
import postgres from 'postgres';

const __dirname = dirname(fileURLToPath(import.meta.url));

// Load .env if present so the script works without exporting vars by hand.
const envPath = join(__dirname, '..', '.env');
if (existsSync(envPath)) {
  for (const line of readFileSync(envPath, 'utf8').split('\n')) {
    const m = line.match(/^\s*([A-Z0-9_]+)\s*=\s*(.*)\s*$/);
    if (m && !process.env[m[1]]) process.env[m[1]] = m[2].replace(/^["']|["']$/g, '');
  }
}

const TIERS = ['SUPER_ADMIN', 'FINANCE', 'SUPPORT', 'MODERATOR'];

const args = process.argv.slice(2);
const list = args.includes('--list');
const revoke = args.includes('--revoke');
const positional = args.filter((a) => !a.startsWith('--'));
const email = positional[0];
const tier = (positional[1] || 'SUPER_ADMIN').toUpperCase();

// The OWNER connection: migrations use it, and it is the only credential that
// can legitimately mint the first admin. Never the app's least-privilege role.
const url = process.env.DATABASE_URL_MIGRATE || process.env.DATABASE_URL;
if (!url) {
  console.error('make-admin: no DATABASE_URL_MIGRATE (or DATABASE_URL) available');
  process.exit(2);
}
if (!list && !email) {
  console.error('usage: node scripts/make-admin.mjs <email> [tier|--revoke]   |   --list');
  process.exit(2);
}
if (!list && !revoke && !TIERS.includes(tier)) {
  console.error(`make-admin: tier must be one of ${TIERS.join(', ')}`);
  process.exit(2);
}

const sql = postgres(url, { max: 1, prepare: false, onnotice: () => {} });

async function main() {
  if (list) {
    const rows = await sql`
      select p.email, p.full_name, p.role::text as role, a.admin_role::text as tier, a.created_at
      from public.profiles p
      left join public.admin_profiles a on a.profile_id = p.id
      where p.role = 'ADMIN' or a.profile_id is not null
      order by a.created_at nulls last`;
    if (!rows.length) {
      console.log('No admins exist yet. Grant the first with:');
      console.log('  node scripts/make-admin.mjs <email>');
    } else {
      console.log(`${rows.length} admin account(s):`);
      for (const r of rows) {
        const warn = r.role !== 'ADMIN' || !r.tier ? '   <-- INCOMPLETE (needs both role and tier)' : '';
        console.log(`  ${r.email}  role=${r.role}  tier=${r.tier ?? 'none'}${warn}`);
      }
    }
    await sql.end();
    return;
  }

  const [user] = await sql`
    select id, email, full_name, role::text as role
    from public.profiles where lower(email) = lower(${email}) limit 1`;

  if (!user) {
    console.error(`make-admin: no profile with email "${email}".`);
    console.error('They must sign up in the app first — this promotes an existing account.');
    await sql.end();
    process.exit(1);
  }

  if (revoke) {
    // Demote via bootstrap_admin: profiles.role is protected by the
    // guard_protected_columns trigger, which a plain UPDATE cannot satisfy even
    // as the owner (Supabase's `postgres` is not a superuser). The account keeps
    // its wallet, bookings and history.
    const [res] = await sql`select public.bootstrap_admin(${email}, 'SUPER_ADMIN'::public.admin_role, true) as r`;
    if (!res.r?.success) {
      console.error(`make-admin: ${res.r?.error ?? 'failed'}`);
      await sql.end();
      process.exit(1);
    }
    console.log(`Revoked admin from ${user.email} — now a FAN.`);
    await sql.end();
    return;
  }

  // Granting goes through bootstrap_admin (SECURITY DEFINER, owner-only) rather
  // than a direct UPDATE: profiles.role is protected by guard_protected_columns,
  // whose only viable escape hatch here is a SECURITY DEFINER context. It sets
  // BOTH halves — profiles.role and admin_profiles.admin_role — in one call, so
  // there is no window where the account is a half-admin.
  const [res] = await sql`select public.bootstrap_admin(${email}, ${tier}::public.admin_role, false) as r`;
  if (!res.r?.success) {
    console.error(`make-admin: ${res.r?.error ?? 'failed'}`);
    await sql.end();
    process.exit(1);
  }

  console.log(`${user.email} (${user.full_name ?? 'no name'}) is now ADMIN / ${tier}.`);
  console.log('Sign out and back in — the app reads the role from /me at session start.');
  await sql.end();
}

main().catch(async (e) => {
  console.error('make-admin failed:', e.message);
  try { await sql.end(); } catch {}
  process.exit(1);
});

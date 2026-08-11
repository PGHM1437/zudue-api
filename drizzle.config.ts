import type { Config } from 'drizzle-kit';

// Introspection/typegen config. The canonical DDL is the SQL migrations in
// ./migrations (applied via scripts/migrate.mjs); Drizzle is used for
// type-safe queries, not as the DDL source of truth.
const databaseUrl = process.env.DATABASE_URL_MIGRATE || process.env.DATABASE_URL;
if (!databaseUrl) {
  // The '' fallback this replaced let drizzle-kit attempt a connection to an
  // empty URL, which fails with a confusing driver-level parse error instead
  // of naming the actual problem: no DATABASE_URL_MIGRATE/DATABASE_URL set.
  throw new Error('drizzle.config.ts: set DATABASE_URL_MIGRATE or DATABASE_URL before running drizzle-kit');
}

export default {
  schema: './src/db/schema.ts',
  out: './migrations',
  dialect: 'postgresql',
  dbCredentials: { url: databaseUrl },
} satisfies Config;

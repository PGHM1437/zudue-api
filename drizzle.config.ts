import type { Config } from 'drizzle-kit';

// Introspection/typegen config. The canonical DDL is the SQL migrations in
// ./migrations (applied via scripts/migrate.mjs); Drizzle is used for
// type-safe queries, not as the DDL source of truth.
export default {
  schema: './src/db/schema.ts',
  out: './migrations',
  dialect: 'postgresql',
  dbCredentials: { url: process.env.DATABASE_URL_MIGRATE || process.env.DATABASE_URL || '' },
} satisfies Config;

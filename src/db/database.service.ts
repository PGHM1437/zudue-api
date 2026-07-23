import { Injectable, OnModuleDestroy } from '@nestjs/common';
import { drizzle, PostgresJsDatabase } from 'drizzle-orm/postgres-js';
import { sql } from 'drizzle-orm';
import postgres from 'postgres';
import * as schema from './schema';

export type Tx = PostgresJsDatabase<typeof schema>;

/**
 * The RLS linchpin.
 *
 * The API connects as the least-privilege role `zudue_app` (no BYPASSRLS).
 * Every unit of work runs inside a transaction that first does
 * `SELECT set_config('app.user_id', <subject>, true)` — i.e. SET LOCAL — so the
 * DB's `current_user_id()` returns the authenticated subject and every RLS
 * policy + column guard + RPC authorization check evaluates against it.
 *
 * There is no other way to touch the database from the app. A request with no
 * identity uses `runAnon` (GUC empty → RLS shows only public rows). System work
 * (webhooks, jobs) uses `runAsService` (sets app.is_service_role=true, which the
 * DB honours only for the specific service-gated RPCs).
 */
@Injectable()
export class DatabaseService implements OnModuleDestroy {
  private readonly client: postgres.Sql;
  private readonly db: PostgresJsDatabase<typeof schema>;

  constructor(databaseUrl: string) {
    this.client = postgres(databaseUrl, {
      max: 20,
      prepare: false, // pooled (pgbouncer/Neon) — transaction pooling safe
    });
    this.db = drizzle(this.client, { schema });
  }

  /** Run `fn` as the given authenticated user (RLS scoped to them). */
  async runAs<T>(userId: string, fn: (tx: Tx) => Promise<T>): Promise<T> {
    return this.db.transaction(async (tx) => {
      await tx.execute(sql`select set_config('app.user_id', ${userId}, true)`);
      return fn(tx as unknown as Tx);
    });
  }

  /** Run `fn` with no identity — only RLS-public rows are visible. */
  async runAnon<T>(fn: (tx: Tx) => Promise<T>): Promise<T> {
    return this.db.transaction(async (tx) => {
      await tx.execute(sql`select set_config('app.user_id', '', true)`);
      return fn(tx as unknown as Tx);
    });
  }

  /** Trusted system context (webhooks, BullMQ jobs). Never derived from a client. */
  async runAsService<T>(fn: (tx: Tx) => Promise<T>): Promise<T> {
    return this.db.transaction(async (tx) => {
      await tx.execute(sql`select set_config('app.is_service_role', 'true', true)`);
      return fn(tx as unknown as Tx);
    });
  }

  /**
   * Call a DB RPC and return its parsed JSON. Every business RPC returns a
   * jsonb envelope `{ success, ... }`; a `success:false` is surfaced as an error
   * carrying the DB's error code so controllers can map it to an HTTP status.
   */
  async rpc<T = any>(tx: Tx, name: string, args: unknown[]): Promise<T> {
    const argsSql = args.length
      ? sql.join(
          args.map((a) => sql`${a}`),
          sql`, `,
        )
      : sql``;
    const res = (await tx.execute(
      sql`select public.${sql.identifier(name)}(${argsSql}) as result`,
    )) as unknown as Array<{ result: T }>;
    const result = res[0]?.result as any;
    if (result && result.success === false) {
      const err = new Error(result.error ?? 'RPC_FAILED');
      (err as any).rpc = result;
      throw err;
    }
    return result as T;
  }

  async onModuleDestroy() {
    await this.client.end({ timeout: 5 });
  }
}

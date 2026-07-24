import { BadRequestException, Injectable, OnModuleDestroy } from '@nestjs/common';
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

      // Every money column in this schema is `bigint` (paise). postgres.js
      // returns int8 as a STRING by default to avoid precision loss, so
      // balance_paise arrived at the client as "0" rather than 0 and every
      // `as num` cast threw:
      //     TypeError: "0": type 'String' is not a subtype of type 'num'
      // That hit every screen showing money, not just the wallet.
      //
      // Parsing to Number is safe here: JS integers are exact to 2^53, i.e.
      // ~90 trillion rupees in paise — orders of magnitude beyond any real
      // balance. Fixing it at the driver keeps a single source of truth
      // instead of scattering String→num coercions across the clients.
      types: {
        bigint: {
          to: 20,
          from: [20], // int8 OID
          serialize: (x: number | bigint) => x.toString(),
          parse: (x: string) => Number(x),
        },
      },
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
      // A business rejection (PARTNER_NOT_ACTIVE, NO_CAPACITY, ALREADY_VERIFIED…)
      // is the CLIENT's condition to fix, not a server fault — so surface it as
      // a 400 carrying the DB's error code, not a generic 500. Previously this
      // threw a plain Error, which NestJS rendered as "Internal server error",
      // hiding the actual reason from the app.
      throw new BadRequestException({ error: result.error ?? 'RPC_FAILED', ...result });
    }
    return result as T;
  }

  async onModuleDestroy() {
    await this.client.end({ timeout: 5 });
  }
}

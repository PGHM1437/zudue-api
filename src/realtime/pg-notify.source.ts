import { randomUUID } from 'node:crypto';
import postgres from 'postgres';
import {
  CALL_EVENTS_CHANNEL,
  CallChangedEvent,
  EndedByRole,
  LoggerLike,
  RealtimeEventSource,
  SourceHandlers,
} from './realtime.types';

export type ParsedNotification =
  | { kind: 'call'; event: CallChangedEvent }
  | { kind: 'probe'; id: string };

const ROLES = new Set<string>(['FAN', 'PARTNER', 'ADMIN']);
const nonEmpty = (v: unknown): v is string => typeof v === 'string' && v.length > 0;

/**
 * Parses one NOTIFY payload. Pure and total: anything unexpected returns null
 * instead of throwing, because a payload we cannot read must never take the
 * listener down — and this string comes from a database trigger, not a client,
 * so a bad one means a bug on our side worth counting, not attacker input.
 */
export function parseNotification(payload: string): ParsedNotification | null {
  let j: any;
  try {
    j = JSON.parse(payload);
  } catch {
    return null;
  }
  if (!j || typeof j !== 'object') return null;
  if (j.type === 'probe') return nonEmpty(j.id) ? { kind: 'probe', id: j.id } : null;
  if (j.type !== 'call.changed') return null;
  if (!nonEmpty(j.callId) || !nonEmpty(j.bookingId) || !nonEmpty(j.fanId) || !nonEmpty(j.partnerId) || !nonEmpty(j.status)) {
    return null;
  }
  return {
    kind: 'call',
    event: {
      type: 'call.changed',
      callId: j.callId,
      bookingId: j.bookingId,
      fanId: j.fanId,
      partnerId: j.partnerId,
      status: j.status,
      // Only the roles we know; anything else (or null) is "not attributed".
      endedByRole: ROLES.has(j.endedByRole) ? (j.endedByRole as EndedByRole) : null,
    },
  };
}

export interface PgNotifySourceOptions {
  /** How often to prove delivery end-to-end while healthy. */
  probeIntervalMs: number;
  /** How long to wait for our own probe to come back before calling it missed. */
  probeTimeoutMs: number;
  reconnectBaseMs: number;
  reconnectMaxMs: number;
}

const DEFAULTS: PgNotifySourceOptions = {
  probeIntervalMs: 30_000,
  probeTimeoutMs: 5_000,
  reconnectBaseMs: 1_000,
  reconnectMaxMs: 30_000,
};

/**
 * Postgres LISTEN/NOTIFY as a [RealtimeEventSource].
 *
 * The driver's own `listen()` reconnects and re-LISTENs after a dropped
 * connection, but it swallows a failed re-listen and cannot tell a healthy
 * socket from a half-dead one (NAT/pooler idle reaping leaves a connection that
 * looks open and delivers nothing, and TCP keepalive takes many minutes to
 * notice). Neither is acceptable for something clients are told to trust, so
 * this class does not rely on the driver for correctness. It PROVES delivery:
 * every `probeIntervalMs` it sends a NOTIFY through a second connection and
 * waits to receive it on the listening one. Two misses in a row and the whole
 * client is torn down and rebuilt.
 *
 * `healthy` is true only after a probe has actually round-tripped. That is what
 * makes a wrong DATABASE_URL_LISTEN (a transaction-mode pooler, where LISTEN
 * "succeeds" and then never delivers) fail loudly at boot instead of running
 * deaf forever.
 *
 * Delivery is at-most-once. Whenever the listener re-establishes after a gap,
 * `onResync` fires so connected clients re-read state.
 */
export class PgNotifySource implements RealtimeEventSource {
  private readonly opts: PgNotifySourceOptions;
  private handlers?: SourceHandlers;
  private sql?: postgres.Sql;
  /** Bumped on every (re)build so callbacks from a torn-down client are ignored. */
  private generation = 0;
  private stopped = false;
  private everListened = false;
  private _healthy = false;
  private probeFailures = 0;
  private hintLogged = false;
  private reconnectAttempts = 0;
  private probeTimer?: NodeJS.Timeout;
  private reconnectTimer?: NodeJS.Timeout;
  private readonly pendingProbes = new Map<string, () => void>();
  private malformed = 0;
  private lastMalformedLogAt = 0;

  constructor(
    private readonly url: string,
    private readonly log: LoggerLike,
    opts: Partial<PgNotifySourceOptions> = {},
  ) {
    this.opts = { ...DEFAULTS, ...opts };
  }

  get healthy(): boolean {
    return this._healthy;
  }

  start(handlers: SourceHandlers): void {
    this.handlers = handlers;
    this.warnIfPooler();
    void this.connect();
  }

  async stop(): Promise<void> {
    this.stopped = true;
    this.generation++;
    clearTimeout(this.probeTimer);
    clearTimeout(this.reconnectTimer);
    this._healthy = false; // silently — the gateway is already shutting down
    const sql = this.sql;
    this.sql = undefined;
    await sql?.end({ timeout: 5 }).catch(() => undefined);
  }

  private async connect(): Promise<void> {
    if (this.stopped) return;
    const gen = ++this.generation;
    const sql = postgres(this.url, {
      max: 1,
      prepare: false, // safe behind a pooler; the listener never needs prepared statements
      connect_timeout: 10,
      onnotice: () => undefined,
    });
    this.sql = sql;
    try {
      await sql.listen(
        CALL_EVENTS_CHANNEL,
        (payload) => this.onNotify(gen, payload),
        () => this.onListening(gen),
      );
    } catch (err) {
      if (gen !== this.generation || this.stopped) return;
      this.log.warn(`realtime LISTEN failed: ${(err as Error).message}`);
      await this.recycle(gen, 'listen failed');
    }
  }

  /** Runs on the first LISTEN and again each time the driver re-establishes it. */
  private onListening(gen: number): void {
    if (gen !== this.generation || this.stopped) return;
    if (this.everListened) {
      // We were away; NOTIFY is not persisted, so anything in the gap is gone.
      this.safely(() => this.handlers?.onResync());
    }
    this.everListened = true;
    this.scheduleProbe(gen, 0);
  }

  private onNotify(gen: number, payload: string): void {
    if (gen !== this.generation) return;
    const parsed = parseNotification(payload);
    if (!parsed) {
      this.malformed++;
      const now = Date.now();
      if (now - this.lastMalformedLogAt > 60_000) {
        this.lastMalformedLogAt = now;
        this.log.warn(`ignored ${this.malformed} unparseable ${CALL_EVENTS_CHANNEL} payload(s) so far`);
      }
      return;
    }
    if (parsed.kind === 'probe') {
      this.pendingProbes.get(parsed.id)?.();
      return;
    }
    this.safely(() => this.handlers?.onCallChanged(parsed.event));
  }

  private scheduleProbe(gen: number, delayMs: number): void {
    clearTimeout(this.probeTimer);
    this.probeTimer = setTimeout(() => void this.probe(gen), delayMs);
    this.probeTimer.unref();
  }

  private async probe(gen: number): Promise<void> {
    const sql = this.sql;
    if (gen !== this.generation || this.stopped || !sql) return;
    const ok = await this.roundTrip(sql);
    if (gen !== this.generation || this.stopped) return;

    if (ok) {
      if (!this._healthy) this.log.log('realtime listener healthy (NOTIFY round-trip confirmed)');
      this.probeFailures = 0;
      this.hintLogged = false; // a later failure deserves the full explanation again
      this.reconnectAttempts = 0; // only a proven delivery resets the backoff
      this.setHealthy(true);
      this.scheduleProbe(gen, this.opts.probeIntervalMs);
      return;
    }

    this.probeFailures++;
    this.setHealthy(false);
    if (this.probeFailures === 1) {
      // One miss can be a slow moment. Say so, retry once, and only then rebuild.
      this.log.warn('realtime probe missed (own NOTIFY not received); retrying once');
      this.scheduleProbe(gen, this.opts.probeTimeoutMs);
      return;
    }
    if (!this.hintLogged) {
      // Loud once, with the likely cause; then brief, so a misconfigured
      // deployment does not bury the log under the same paragraph every retry.
      this.hintLogged = true;
      this.log.error(
        'realtime listener is not receiving NOTIFY. If DATABASE_URL_LISTEN is unset or points at a ' +
          'transaction-mode pooler (Supabase :6543, PgBouncer transaction mode), LISTEN never delivers — ' +
          'use the direct or session-mode (:5432) URL. Rebuilding the connection.',
      );
    } else {
      this.log.warn(`realtime listener still not receiving NOTIFY (${this.probeFailures} probes missed); rebuilding`);
    }
    await this.recycle(gen, 'probe failed');
  }

  /** Sends a NOTIFY on the second connection and waits to hear it on the listening one. */
  private roundTrip(sql: postgres.Sql): Promise<boolean> {
    const id = randomUUID();
    return new Promise<boolean>((resolve) => {
      let timer: NodeJS.Timeout | undefined;
      const done = (ok: boolean) => {
        clearTimeout(timer);
        this.pendingProbes.delete(id);
        resolve(ok);
      };
      timer = setTimeout(() => done(false), this.opts.probeTimeoutMs);
      this.pendingProbes.set(id, () => done(true));
      sql.notify(CALL_EVENTS_CHANNEL, JSON.stringify({ type: 'probe', id })).catch(() => done(false));
    });
  }

  /** Discards the current client and builds a fresh one after a backoff. */
  private async recycle(gen: number, why: string): Promise<void> {
    if (gen !== this.generation || this.stopped) return;
    this.generation++; // orphan every callback of the client being discarded
    this.setHealthy(false);
    clearTimeout(this.probeTimer);
    const old = this.sql;
    this.sql = undefined;
    await old?.end({ timeout: 2 }).catch(() => undefined);
    if (this.stopped) return;

    const backoff = Math.min(this.opts.reconnectMaxMs, this.opts.reconnectBaseMs * 2 ** this.reconnectAttempts++);
    const delay = Math.round(backoff * (0.75 + Math.random() * 0.5)); // jitter: many instances, one DB
    this.log.warn(`realtime listener rebuilding (${why}) in ${delay}ms`);
    this.reconnectTimer = setTimeout(() => void this.connect(), delay);
    this.reconnectTimer.unref();
  }

  private setHealthy(healthy: boolean): void {
    if (this._healthy === healthy) return;
    this._healthy = healthy;
    this.safely(() => this.handlers?.onHealthChange(healthy));
  }

  /** A handler bug must never be able to break the listener. */
  private safely(fn: () => void): void {
    try {
      fn();
    } catch (err) {
      this.log.error(`realtime handler threw: ${(err as Error).message}`);
    }
  }

  private warnIfPooler(): void {
    try {
      const u = new URL(this.url);
      if (u.port === '6543' || u.searchParams.get('pgbouncer') === 'true') {
        this.log.warn(
          'DATABASE_URL_LISTEN looks like a transaction-mode pooler (port 6543 / pgbouncer=true). ' +
            'LISTEN will not deliver through it; the boot probe will confirm and realtime will stay unavailable.',
        );
      }
    } catch {
      /* an unparseable URL fails loudly at connect time anyway */
    }
  }
}

/**
 * Realtime gateway — wire protocol + the seams the rest of the module is built
 * on. See README.md in this folder for the design and the operational notes.
 *
 * Deliberately tiny: a socket carries HINTS ("this call changed"), never the
 * source of truth. A client that misses one re-reads state over REST, which is
 * what makes at-most-once delivery safe.
 */
import type { VerifiedToken } from '../auth/jwt.guard';

/** Where the socket is mounted. Under /v1 so proxy rules that route the API by prefix cover it. */
export const REALTIME_PATH = '/v1/realtime';

/** The Postgres NOTIFY channel migration 0102's trigger writes to. */
export const CALL_EVENTS_CHANNEL = 'call_events';

/**
 * Close codes. 1xxx are RFC 6455 / IANA; 4xxx are ours (private-use range) and
 * tell the client what to do next — see realtime_service.dart's reconnect logic.
 */
export const CloseCode = {
  /** Server is shutting down (deploy). Reconnect promptly, with jitter. */
  GOING_AWAY: 1001,
  /** Server cannot deliver events right now (its listener is down). Back off. */
  UNAVAILABLE: 1013,
  /** Malformed frame / protocol violation. A client bug; do not hot-loop. */
  PROTOCOL: 4400,
  /** Bad or expired token. Refresh the session, then reconnect. */
  UNAUTHORIZED: 4401,
  /** Never sent `auth` in time. A client bug; do not hot-loop. */
  AUTH_TIMEOUT: 4408,
  /** Evicted: this user opened more sockets than allowed and this was the oldest. */
  EVICTED: 4429,
} as const;

// ── client → server ──────────────────────────────────────────────────────────
// `auth` must be the first frame. The token goes in a message, not the URL, so
// it never lands in proxy/access logs or browser history.
export type ClientMessage = { type: 'auth'; token: string } | { type: 'pong' };

// ── server → client ──────────────────────────────────────────────────────────
export type EndedByRole = 'FAN' | 'PARTNER' | 'ADMIN';

export interface CallChangedMessage {
  type: 'call.changed';
  callId: string;
  bookingId: string;
  /** A call_status value. Unknown values must be tolerated by clients. */
  status: string;
  /** Set only when a live call was ended manually (migration 0101). */
  endedByRole: EndedByRole | null;
}

export type ServerMessage =
  | { type: 'ready'; v: 1; pingMs: number }
  | { type: 'ping' }
  /** Events may have been missed; re-read whatever you are showing. */
  | { type: 'resync' }
  | CallChangedMessage;

// ── event source seam ────────────────────────────────────────────────────────

/** What the database trigger emits: the message plus who to route it to. */
export interface CallChangedEvent extends CallChangedMessage {
  fanId: string;
  partnerId: string;
}

export interface SourceHandlers {
  onCallChanged(event: CallChangedEvent): void;
  /** The source reconnected, so events may have been lost while it was away. */
  onResync(): void;
  /**
   * The source can (true) or cannot (false) currently guarantee delivery. The
   * gateway refuses sockets while it is false, so a connected client is always
   * one that will actually receive events.
   */
  onHealthChange(healthy: boolean): void;
}

/**
 * Where events come from. Postgres LISTEN/NOTIFY today (PgNotifySource);
 * Redis pub/sub or a streaming service on OCI tomorrow, with no change to the
 * gateway or to any client. Implementations own their reconnection.
 */
export interface RealtimeEventSource {
  /** Begin delivering. Must not throw or reject: retry internally. */
  start(handlers: SourceHandlers): void;
  stop(): Promise<void>;
  readonly healthy: boolean;
}

export const REALTIME_SOURCE = Symbol('REALTIME_SOURCE');

/** The slice of JwtGuard the gateway needs, and nothing more. */
export interface TokenVerifier {
  verify(token: string): Promise<VerifiedToken>;
}

export interface RealtimeOptions {
  /** Drop a socket that has not authenticated within this long. */
  authTimeoutMs: number;
  /** App-level ping cadence. Also bounds how stale a token's expiry can go unnoticed. */
  pingIntervalMs: number;
  /** Sockets per user; the oldest is evicted past this. */
  maxPerUser: number;
  /** Concurrent not-yet-authenticated sockets — bounds what an unauthenticated peer can hold open. */
  maxPending: number;
  /** Largest inbound frame. A JWT is ~1–2KB; nothing legitimate is larger. */
  maxPayloadBytes: number;
  /** A client this far behind on reads is dead or hopelessly slow; drop it rather than buffer. */
  maxBufferedBytes: number;
}

export const DEFAULT_REALTIME_OPTIONS: RealtimeOptions = {
  authTimeoutMs: 5_000,
  // Stays well inside the ~60s idle timeout common to load balancers/proxies,
  // so the ping doubles as the keepalive that stops an idle socket being reaped.
  pingIntervalMs: 25_000,
  maxPerUser: 5,
  maxPending: 200,
  maxPayloadBytes: 8 * 1024,
  maxBufferedBytes: 256 * 1024,
};

/** Minimal logger surface — Nest's Logger satisfies it. */
export interface LoggerLike {
  log(msg: string): void;
  warn(msg: string): void;
  error(msg: string): void;
  debug(msg: string): void;
}

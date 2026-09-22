import type { IncomingMessage, Server } from 'node:http';
import type { Duplex } from 'node:stream';
import { RawData, WebSocket, WebSocketServer } from 'ws';
import type { VerifiedToken } from '../auth/jwt.guard';
import {
  CallChangedEvent,
  CallChangedMessage,
  CloseCode,
  DEFAULT_REALTIME_OPTIONS,
  LoggerLike,
  REALTIME_PATH,
  RealtimeEventSource,
  RealtimeOptions,
  ServerMessage,
  TokenVerifier,
} from './realtime.types';

interface Conn {
  ws: WebSocket;
  userId: string | null;
  /** Epoch ms after which the token that authenticated this socket is no longer valid. */
  expiresAtMs: number;
  /** Last time ANY frame arrived — pongs and real traffic both count as proof of life. */
  lastSeenMs: number;
  authTimer?: NodeJS.Timeout;
  verifying: boolean;
  closed: boolean;
}

/** A token with no `exp` claim is capped rather than trusted forever. */
const NO_EXPIRY_CAP_MS = 60 * 60 * 1000;

const RESYNC: ServerMessage = { type: 'resync' };
const PING: ServerMessage = { type: 'ping' };

function rawToString(data: RawData): string {
  if (Array.isArray(data)) return Buffer.concat(data).toString('utf8');
  if (data instanceof ArrayBuffer) return Buffer.from(data).toString('utf8');
  return data.toString('utf8');
}

/**
 * The socket server. Plain TypeScript with no Nest coupling so it can be driven
 * on its own; [RealtimeService] adapts it to the Nest lifecycle.
 *
 * What a connected socket means: it is authenticated as one user, and the
 * event source is healthy — so it WILL be told when one of that user's calls
 * changes. If the source stops being able to promise that, every socket is
 * closed (1013) and new ones are refused (503) until it can again; clients fall
 * back to the push + polling paths that still run underneath. A socket that
 * looks connected but is deaf is worse than no socket, because the client would
 * trust it.
 *
 * Routing is by verified identity only: an event goes to the sockets of the two
 * parties named on the call, so there are no subscribe messages, no topic
 * strings to validate, and no way to ask for someone else's events.
 */
export class RealtimeGateway {
  private readonly opts: RealtimeOptions;
  private readonly wss: WebSocketServer;
  private readonly byUser = new Map<string, Set<Conn>>();
  private readonly pending = new Set<Conn>();
  private server?: Server;
  private heartbeat?: NodeJS.Timeout;
  private healthy = false;
  private readonly counters = { accepted: 0, refused: 0, eventsIn: 0, eventsDelivered: 0 };

  constructor(
    private readonly verifier: TokenVerifier,
    private readonly source: RealtimeEventSource,
    private readonly log: LoggerLike,
    private readonly enabled: boolean,
    opts: Partial<RealtimeOptions> = {},
  ) {
    this.opts = { ...DEFAULT_REALTIME_OPTIONS, ...opts };
    this.wss = new WebSocketServer({
      noServer: true, // we run the handshake ourselves, so we can refuse with a real HTTP status
      maxPayload: this.opts.maxPayloadBytes,
      perMessageDeflate: false, // per-socket zlib state is memory we do not need for ~200-byte frames
    });
  }

  /** Start handling upgrades on [server] and, if enabled, start the event source. */
  attach(server: Server): void {
    this.server = server;
    server.on('upgrade', this.onUpgrade);
    if (!this.enabled) {
      this.log.warn('Realtime disabled (REALTIME_ENABLED=false): every socket will be refused with 503');
      return;
    }
    this.heartbeat = setInterval(() => this.tick(), this.opts.pingIntervalMs);
    this.heartbeat.unref();
    this.source.start({
      onCallChanged: (e) => this.route(e),
      onResync: () => this.broadcast(JSON.stringify(RESYNC)),
      onHealthChange: (h) => this.onHealth(h),
    });
  }

  async destroy(): Promise<void> {
    this.server?.off('upgrade', this.onUpgrade);
    clearInterval(this.heartbeat);
    // 1001 tells clients to reconnect promptly (with jitter) — a deploy, not a fault.
    this.closeAll(CloseCode.GOING_AWAY, 'server_shutdown');
    await this.drain(2_000);
    await this.source.stop();
    this.wss.close();
  }

  stats() {
    let connections = 0;
    for (const set of this.byUser.values()) connections += set.size;
    return {
      enabled: this.enabled,
      healthy: this.healthy,
      connections,
      users: this.byUser.size,
      pending: this.pending.size,
      ...this.counters,
    };
  }

  // ── handshake ──────────────────────────────────────────────────────────────

  private readonly onUpgrade = (req: IncomingMessage, socket: Duplex, head: Buffer): void => {
    const path = (req.url ?? '').split('?')[0];
    if (path !== REALTIME_PATH) {
      // Not ours. Leave it for any other upgrade listener; if we are the only
      // one, nobody will answer, and a hung socket helps no one.
      if (this.server && this.server.listenerCount('upgrade') === 1) socket.destroy();
      return;
    }
    if (!this.enabled || !this.healthy || this.pending.size >= this.opts.maxPending) {
      this.counters.refused++;
      // 503 + Retry-After is something a client can act on; a dropped socket is not.
      socket.end('HTTP/1.1 503 Service Unavailable\r\nRetry-After: 15\r\nConnection: close\r\nContent-Length: 0\r\n\r\n');
      return;
    }
    // Until the handshake completes the raw socket has no error handler; an
    // unhandled 'error' here would crash the process.
    const onSocketError = () => socket.destroy();
    socket.on('error', onSocketError);
    this.wss.handleUpgrade(req, socket, head, (ws) => {
      socket.removeListener('error', onSocketError);
      this.onConnection(ws);
    });
  };

  private onConnection(ws: WebSocket): void {
    const conn: Conn = { ws, userId: null, expiresAtMs: 0, lastSeenMs: Date.now(), verifying: false, closed: false };
    this.pending.add(conn);
    this.counters.accepted++;
    // A peer that opens a socket and says nothing must not hold it open.
    conn.authTimer = setTimeout(() => this.close(conn, CloseCode.AUTH_TIMEOUT, 'auth_timeout'), this.opts.authTimeoutMs);

    ws.on('message', (data, isBinary) => this.onMessage(conn, data, isBinary));
    ws.on('close', () => this.onClose(conn));
    // 'close' always follows; this only stops an unhandled 'error' event throwing.
    ws.on('error', () => undefined);
  }

  private onMessage(conn: Conn, data: RawData, isBinary: boolean): void {
    conn.lastSeenMs = Date.now();
    if (isBinary) return this.close(conn, CloseCode.PROTOCOL, 'binary_not_supported');

    let msg: any;
    try {
      msg = JSON.parse(rawToString(data));
    } catch {
      return this.close(conn, CloseCode.PROTOCOL, 'bad_json');
    }
    if (!msg || typeof msg !== 'object') return this.close(conn, CloseCode.PROTOCOL, 'bad_frame');

    switch (msg.type) {
      case 'auth':
        // A duplicate auth (or one racing the first) is ignored, not an error.
        if (conn.userId || conn.verifying) return;
        void this.authenticate(conn, msg.token);
        return;
      case 'pong':
        return; // lastSeenMs is the whole point
      default:
        // Unknown types are ignored once authenticated (room for the protocol to
        // grow), but nothing at all is allowed before auth.
        if (!conn.userId) this.close(conn, CloseCode.PROTOCOL, 'auth_required');
    }
  }

  private async authenticate(conn: Conn, token: unknown): Promise<void> {
    if (typeof token !== 'string' || token.length === 0) {
      return this.close(conn, CloseCode.UNAUTHORIZED, 'missing_token');
    }
    conn.verifying = true;
    let verified: VerifiedToken;
    try {
      verified = await this.verifier.verify(token);
    } catch (err) {
      conn.verifying = false;
      return this.close(conn, CloseCode.UNAUTHORIZED, (err as Error).message || 'unauthorized');
    }
    conn.verifying = false;

    // The peer can vanish, or the source can fail, while we were verifying.
    if (conn.closed) return;
    if (!this.healthy) return this.close(conn, CloseCode.UNAVAILABLE, 'realtime_unavailable');

    clearTimeout(conn.authTimer);
    this.pending.delete(conn);
    conn.userId = verified.id;
    conn.expiresAtMs = verified.exp ? verified.exp * 1000 : Date.now() + NO_EXPIRY_CAP_MS;

    let set = this.byUser.get(verified.id);
    if (!set) this.byUser.set(verified.id, (set = new Set()));
    // Bound what one account can hold open. Oldest first: it is the one most
    // likely to be a zombie from before a network change.
    while (set.size >= this.opts.maxPerUser) {
      const oldest = set.values().next().value as Conn;
      set.delete(oldest);
      this.close(oldest, CloseCode.EVICTED, 'too_many_connections');
    }
    set.add(conn);

    this.send(conn, JSON.stringify({ type: 'ready', v: 1, pingMs: this.opts.pingIntervalMs } satisfies ServerMessage));
    this.log.debug(`socket ready (${set.size} for user)`);
  }

  // ── delivery ───────────────────────────────────────────────────────────────

  private route(event: CallChangedEvent): void {
    this.counters.eventsIn++;
    // Strip the routing fields: the recipient already knows who they are.
    const msg: CallChangedMessage = {
      type: 'call.changed',
      callId: event.callId,
      bookingId: event.bookingId,
      status: event.status,
      endedByRole: event.endedByRole,
    };
    const frame = JSON.stringify(msg);
    for (const userId of new Set([event.fanId, event.partnerId])) {
      const set = this.byUser.get(userId);
      if (!set) continue;
      for (const conn of set) if (this.send(conn, frame)) this.counters.eventsDelivered++;
    }
  }

  private broadcast(frame: string): void {
    for (const set of this.byUser.values()) for (const conn of set) this.send(conn, frame);
  }

  private send(conn: Conn, frame: string): boolean {
    const { ws } = conn;
    if (ws.readyState !== WebSocket.OPEN) return false;
    if (ws.bufferedAmount > this.opts.maxBufferedBytes) {
      // Not reading its frames: dead, or too slow to be worth buffering for.
      ws.terminate();
      return false;
    }
    ws.send(frame, (err) => {
      if (err) ws.terminate();
    });
    return true;
  }

  // ── liveness ───────────────────────────────────────────────────────────────

  /** Once per ping interval: expire lapsed tokens, cull dead peers, ping the rest. */
  private tick(): void {
    const now = Date.now();
    const deadAfter = this.opts.pingIntervalMs * 2.5;
    const ping = JSON.stringify(PING);
    for (const set of [...this.byUser.values()]) {
      for (const conn of [...set]) {
        if (conn.expiresAtMs <= now) {
          // Close instead of letting the socket outlive its credential. The
          // client refreshes its session and reconnects; the cost is one resync.
          this.close(conn, CloseCode.UNAUTHORIZED, 'token_expired');
        } else if (now - conn.lastSeenMs > deadAfter) {
          // Mobile networks drop silently; only an unanswered ping reveals it.
          conn.ws.terminate();
        } else {
          this.send(conn, ping);
        }
      }
    }
  }

  private onHealth(healthy: boolean): void {
    if (healthy === this.healthy) return;
    this.healthy = healthy;
    if (healthy) {
      this.log.log('Realtime event source healthy: accepting sockets');
    } else {
      this.log.warn('Realtime event source unhealthy: closing sockets and refusing new ones until it recovers');
      this.closeAll(CloseCode.UNAVAILABLE, 'realtime_unavailable');
    }
  }

  // ── teardown ───────────────────────────────────────────────────────────────

  private close(conn: Conn, code: number, reason: string): void {
    if (conn.closed) return;
    // Close-frame reasons are capped at 123 bytes; this text is ours or a jose message.
    try {
      conn.ws.close(code, reason.slice(0, 100));
    } catch {
      conn.ws.terminate();
    }
  }

  private onClose(conn: Conn): void {
    conn.closed = true;
    clearTimeout(conn.authTimer);
    this.pending.delete(conn);
    if (conn.userId) {
      const set = this.byUser.get(conn.userId);
      set?.delete(conn);
      if (set && set.size === 0) this.byUser.delete(conn.userId);
    }
  }

  private closeAll(code: number, reason: string): void {
    for (const conn of this.allConns()) this.close(conn, code, reason);
  }

  private allConns(): Conn[] {
    const all: Conn[] = [...this.pending];
    for (const set of this.byUser.values()) all.push(...set);
    return all;
  }

  /** Waits for sockets to finish closing, then terminates whatever has not. */
  private drain(timeoutMs: number): Promise<void> {
    const sockets = this.allConns().map((c) => c.ws);
    if (sockets.length === 0) return Promise.resolve();
    return new Promise((resolve) => {
      let left = sockets.length;
      const finish = () => {
        clearTimeout(timer);
        resolve();
      };
      const timer = setTimeout(() => {
        sockets.forEach((s) => s.terminate());
        finish();
      }, timeoutMs);
      for (const s of sockets) {
        if (s.readyState === WebSocket.CLOSED) {
          if (--left === 0) finish();
        } else {
          s.once('close', () => {
            if (--left === 0) finish();
          });
        }
      }
    });
  }
}

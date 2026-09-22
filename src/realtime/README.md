# Realtime gateway

Live call-state events over a WebSocket, so a client learns "the fan declined /
the partner ended / the fan joined" in about a second instead of waiting on a push
or a poll.

```
 calls table ──trigger──▶ pg_notify('call_events')        migration 0102
                               │
                     PgNotifySource (LISTEN, own connection, self-probing)
                               │  RealtimeEventSource seam
                        RealtimeGateway ──ws──▶ fan app / partner app
```

It is **additive**. Push notifications, the 60s heartbeat, the 4s ring poll and the
pg_cron sweeps are all untouched and remain the backstop. A socket carries *hints*
("this call changed"); the client re-reads truth over REST. That is what makes
at-most-once delivery safe.

## Protocol v1

`wss://<api>/v1/realtime`. JSON text frames only.

| Direction | Frame | Meaning |
|---|---|---|
| C→S | `{"type":"auth","token":"<jwt>"}` | **Must be the first frame**, within 5s. Same token, same verification, as the REST API. In a frame — never the URL — so it cannot land in proxy logs. |
| S→C | `{"type":"ready","v":1,"pingMs":25000}` | Authenticated and the event source is healthy. From here you WILL be told. |
| S→C | `{"type":"call.changed","callId","bookingId","status","endedByRole"}` | A call you are a party to changed status. `endedByRole` is `FAN`/`PARTNER`/`ADMIN`/`null`. |
| S→C | `{"type":"resync"}` | Events may have been missed (server's listener reconnected). Re-read what you are showing. |
| S→C | `{"type":"ping"}` | Answer with `{"type":"pong"}`. Silence for 2.5 intervals gets you dropped. |

There are **no subscribe messages**. Routing is by verified identity: an event goes
to the sockets of the two parties named on the call. You cannot ask for anyone
else's events, and there are no topic strings to validate.

### Close codes

| Code | Meaning | Client should |
|---|---|---|
| 1001 | Server shutting down (deploy) | reconnect promptly, with jitter |
| 1013 | Event source unhealthy | back off (≥15s) |
| 4400 | Protocol violation | fix the client; do not hot-loop |
| 4401 | Bad/expired token | refresh the session, then reconnect |
| 4408 | Never authenticated | fix the client |
| 4429 | Evicted (over 5 sockets for this user; oldest goes) | reconnect |

Unhealthy or disabled → the upgrade is refused with **HTTP 503** + `Retry-After`.
A socket that is open is therefore always one that will actually receive events.

## Deploying it

Order matters only for turning it *on*; every step is safe on its own.

1. `npm run db:migrate` — applies 0101 (attribution) then **0102** (the trigger).
   0102 works whether or not 0101 is applied.
2. Set **`DATABASE_URL_LISTEN`** on the API service. See the next section — this is
   the one that is easy to get wrong.
3. Deploy the API. Watch the log for `realtime listener healthy (NOTIFY round-trip confirmed)`.
4. Ship the mobile build.

`GET /v1/realtime/health` → `{"enabled":true,"healthy":true}`. It is deliberately
separate from the main health check: a realtime problem must never get a healthy API
instance restarted.

### `DATABASE_URL_LISTEN` — read this

`LISTEN` needs a **session-level** connection. Through a **transaction-mode pooler
it silently never delivers** — the command succeeds and nothing ever arrives.

| URL | Works for LISTEN? |
|---|---|
| Direct connection | yes |
| Supabase pooler, **session mode, port 5432** | yes |
| Supabase pooler, **transaction mode, port 6543** | **no** |
| PgBouncer `pool_mode=transaction` | **no** |

This project's runtime `DATABASE_URL` is the **:6543 transaction pooler** (chosen for
the app's request pool, correctly). So `DATABASE_URL_LISTEN` must be set to the
`:5432` session-mode URL. Unset, it falls back to `DATABASE_URL`, which will not work
here.

You do not have to trust this document. The source **proves** delivery: at boot and
every 30s it sends itself a `NOTIFY` on a second connection and waits to receive it.
Until that round trip succeeds the gateway refuses sockets (503). A wrong URL shows up
as one loud log line explaining exactly this, and realtime staying off — never as a
socket that looks connected and hears nothing.

## Operating it

* **Kill switch:** `REALTIME_ENABLED=false` (exactly `true`/`false`; anything else fails
  boot). Stops the listener and 503s every upgrade. Clients fall back to push + polling.
* **Logs** (`Realtime`, `RealtimeSource`): listener healthy/unhealthy transitions, probe
  misses, rebuilds, and one `stats {…}` line every 5 minutes
  (`connections, users, pending, accepted, refused, eventsIn, eventsDelivered`).
* **Deploys:** SIGTERM closes every socket with 1001 and waits up to 2s; clients
  reconnect to the new instance and resync.
* **Token expiry:** a socket is closed (4401) within one ping interval of its token
  expiring, so a connection never outlives its credential. The client refreshes and
  reconnects; the cost is one resync.
* **Scaling out:** every instance listens to Postgres independently and pushes only to
  its own sockets — no shared state, no broker.

## Failure modes

| What happens | Result |
|---|---|
| Listener connection dropped | driver re-LISTENs; we broadcast `resync` |
| Listener half-dead (open, deaf) | 2 missed probes → rebuilt with backoff; sockets closed 1013 meanwhile |
| Postgres down at boot | API boots normally; realtime stays off, retries with backoff |
| Client silently loses network | server reaps it after 2.5 missed pings; client watchdog reconnects |
| Event lost in a gap | `resync` / reconnect makes the client re-read; heartbeat + sweeps are the backstop |
| A handler throws | caught and logged; the listener survives |

## Swapping the backplane (OCI)

Postgres `LISTEN/NOTIFY` is core Postgres, so it moves with the database. If you later
outgrow it (it serialises commits that NOTIFY and is at-most-once), implement
`RealtimeEventSource` (`realtime.types.ts`) over Redis or a streaming service and change
one provider in `realtime.module.ts`. The gateway, the protocol and every client are
untouched.

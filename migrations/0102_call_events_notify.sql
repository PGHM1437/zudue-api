-- 0102 · Emit a realtime event whenever a call's status changes.
--
-- WHY
-- Every client learns about call state changes (fan declined, partner ended,
-- fan joined, swept as a no-show) by push or by polling on a timer. Push is
-- best-effort and the polls leave gaps, which is what left a partner staring at
-- a ringing screen after the fan had already declined. The API now runs a
-- WebSocket gateway (apps/api/src/realtime) that fans these events out to the
-- two parties of the call the instant they happen.
--
-- FIX
-- A trigger on public.calls calls pg_notify('call_events', <json>) when a call
-- is created and whenever attempt_status changes. It is a TABLE trigger rather
-- than a line inside each RPC on purpose: it fires for EVERY writer —
-- rpc_complete_call, rpc_mark_call_missed, rpc_fan_join_call, the pg_cron
-- cleanup_stalled_calls sweep, admin recovery — so the cron sweep that writes
-- off a fan whose phone is dead reaches the partner's screen exactly like a
-- tap does, and no future writer can forget to notify.
--
-- The payload is IDs and status only (a few hundred bytes; NOTIFY's ceiling is
-- 8000). It carries no names, amounts or other PII. Consumers treat it as a
-- hint and the database stays the source of truth.
--
-- DELIVERY MODEL — read before changing anything here
--  · NOTIFY is delivered at COMMIT: a rolled-back status change emits nothing.
--  · Delivery is at-most-once and NOT persisted: a listener that is offline
--    when the event fires never sees it. The gateway therefore tells its
--    clients to resync (re-read the call) whenever its listener reconnects,
--    and the 60s heartbeat + pg_cron sweeps remain the backstop.
--  · LISTEN needs a SESSION-level connection. It silently never delivers
--    through a transaction-mode pooler (Supabase port 6543, PgBouncer
--    pool_mode=transaction). The API reads DATABASE_URL_LISTEN for that reason
--    and probes end-to-end so a misconfiguration is loud, not silent.
--
-- ended_by_role (migration 0101) is read through to_jsonb(NEW) so this trigger
-- works whether or not 0101 has been applied yet: the key is simply null until
-- the column exists.
--
-- REVERSIBLE:
--   DROP TRIGGER trg_notify_call_created ON public.calls;
--   DROP TRIGGER trg_notify_call_status_change ON public.calls;
--   DROP FUNCTION public.notify_call_event();

BEGIN;

CREATE OR REPLACE FUNCTION public.notify_call_event()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
BEGIN
  PERFORM pg_notify(
    'call_events',
    jsonb_build_object(
      'type',        'call.changed',
      'callId',      NEW.id,
      'bookingId',   NEW.booking_id,
      'fanId',       NEW.fan_id,
      'partnerId',   NEW.partner_id,
      'status',      NEW.attempt_status::text,
      'endedByRole', to_jsonb(NEW) ->> 'ended_by_role'
    )::text
  );
  RETURN NULL;  -- AFTER trigger: the return value is ignored
END $function$;

-- Two triggers, one function: a WHEN clause cannot reference OLD on INSERT, and
-- we want "created" and "status actually changed" but not a no-op UPDATE that
-- merely re-sets the same status.
DROP TRIGGER IF EXISTS trg_notify_call_created ON public.calls;
CREATE TRIGGER trg_notify_call_created
  AFTER INSERT ON public.calls
  FOR EACH ROW EXECUTE FUNCTION public.notify_call_event();

DROP TRIGGER IF EXISTS trg_notify_call_status_change ON public.calls;
CREATE TRIGGER trg_notify_call_status_change
  AFTER UPDATE OF attempt_status ON public.calls
  FOR EACH ROW
  WHEN (OLD.attempt_status IS DISTINCT FROM NEW.attempt_status)
  EXECUTE FUNCTION public.notify_call_event();

INSERT INTO _migrations (name) VALUES ('0102_call_events_notify.sql') ON CONFLICT (name) DO NOTHING;

COMMIT;

-- 0013 · Triggers — the auto-behaviors, reimplemented clean against the new schema.
-- Replaces the live DB's 55 triggers (24 boilerplate + broken/dead ones) with a
-- small, correct set. updated_at via one shared function; the real behaviors:
-- wallet auto-provision, role-extension provision, call→booking status sync.

BEGIN;

-- ── updated_at everywhere (one function, applied to tables that have the col) ──
DO $$
DECLARE t text;
BEGIN
  FOR t IN
    SELECT c.table_name FROM information_schema.columns c
    WHERE c.table_schema='public' AND c.column_name='updated_at'
  LOOP
    EXECUTE format(
      'CREATE TRIGGER trg_%1$s_updated_at BEFORE UPDATE ON public.%1$I
       FOR EACH ROW EXECUTE FUNCTION public.set_updated_at()', t);
  END LOOP;
END $$;

-- ── Auto-provision a wallet when a FAN profile is created ──
CREATE OR REPLACE FUNCTION provision_fan_wallet()
RETURNS trigger LANGUAGE plpgsql SET search_path = '' AS $$
BEGIN
  IF NEW.role = 'FAN' THEN
    INSERT INTO public.wallets (profile_id) VALUES (NEW.id)
      ON CONFLICT (profile_id) DO NOTHING;
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_provision_fan_wallet AFTER INSERT ON profiles
  FOR EACH ROW EXECUTE FUNCTION provision_fan_wallet();
-- also on role change → FAN
CREATE TRIGGER trg_provision_fan_wallet_upd AFTER UPDATE OF role ON profiles
  FOR EACH ROW WHEN (NEW.role = 'FAN' AND OLD.role IS DISTINCT FROM NEW.role)
  EXECUTE FUNCTION provision_fan_wallet();

-- ── Sync call attempt_status → booking status (day-of isolation like live) ──
-- Only COMPLETED_SUCCESSFUL settles the booking mid-day; missed/dropped stay
-- non-final (retryable). End-of-day / 7-day finalize is a job, not a trigger.
CREATE OR REPLACE FUNCTION sync_call_to_booking()
RETURNS trigger LANGUAGE plpgsql SET search_path = '' AS $$
BEGIN
  IF NEW.attempt_status = 'COMPLETED_SUCCESSFUL'
     AND (OLD.attempt_status IS DISTINCT FROM NEW.attempt_status) THEN
    UPDATE public.bookings
       SET status = 'COMPLETED_SUCCESSFUL', updated_at = now()
     WHERE id = NEW.booking_id AND status = 'BOOKED';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_sync_call_to_booking AFTER UPDATE OF attempt_status ON calls
  FOR EACH ROW EXECUTE FUNCTION sync_call_to_booking();

-- ── Reset fan-ready when a call is missed/dropped (fan must re-signal) ──
CREATE OR REPLACE FUNCTION reset_fan_ready_on_miss()
RETURNS trigger LANGUAGE plpgsql SET search_path = '' AS $$
BEGIN
  IF NEW.attempt_status IN ('MISSED_FAN_NO_JOIN','MISSED_FAN_DECLINED','DROPPED_TECHNICAL_ISSUE') THEN
    UPDATE public.bookings SET fan_ready_at = NULL, updated_at = now()
     WHERE id = NEW.booking_id;
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_reset_fan_ready AFTER UPDATE OF attempt_status ON calls
  FOR EACH ROW EXECUTE FUNCTION reset_fan_ready_on_miss();

-- ── Log every call state change to call_events (observability) ──
CREATE OR REPLACE FUNCTION log_call_event()
RETURNS trigger LANGUAGE plpgsql SET search_path = '' AS $$
BEGIN
  IF TG_OP = 'INSERT' OR OLD.attempt_status IS DISTINCT FROM NEW.attempt_status THEN
    INSERT INTO public.call_events (call_id, event_type, actor, detail)
    VALUES (NEW.id, NEW.attempt_status::text, 'SYSTEM',
            jsonb_build_object('heartbeats', NEW.heartbeat_count));
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_log_call_event AFTER INSERT OR UPDATE OF attempt_status ON calls
  FOR EACH ROW EXECUTE FUNCTION log_call_event();

COMMIT;

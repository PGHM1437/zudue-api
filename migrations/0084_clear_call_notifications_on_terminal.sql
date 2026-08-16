-- Call notifications never clear themselves.
--
-- A fan gets "Incoming Video Call — Join the call!" when a partner rings them.
-- The call then ends (completed, missed, declined, dropped) and that
-- notification stays UNREAD forever: a stale "join now" prompt in the inbox
-- and a permanently-lit unread badge that only a manual "Mark read" clears.
-- Same for the partner's "Fan is ready" prompt and the next-in-queue alert,
-- both of which are meaningless once the call they refer to is over.
--
-- Legacy did this automatically. Its handle_call_status_notifications trigger
-- opened with a block that, on ANY transition into a terminal attempt_status,
-- marked the matching VIDEO_CALL_INITIATED_FOR_FAN notification read. That
-- half was never carried over — verified live 2026-08-16: the only triggers on
-- `calls` are trg_calls_updated_at, trg_log_call_event, trg_reset_fan_ready
-- and trg_sync_call_to_booking, and the only code anywhere that sets
-- is_read = true is the user-driven markRead/markAll in notifications.module.ts.
--
-- Deliberately NOT cleared here: VIDEO_CALL_MISSED_ATTEMPT_FAN. That one is
-- created BY the terminal transition and is a record of something the fan
-- missed — it should stay unread until they actually look at it.

create or replace function public.clear_call_notifications_on_terminal()
returns trigger
language plpgsql
security definer
set search_path to ''
as $$
begin
  if new.attempt_status in ('COMPLETED_SUCCESSFUL','MISSED_FAN_NO_JOIN','MISSED_FAN_DECLINED','DROPPED_TECHNICAL_ISSUE')
     and old.attempt_status is distinct from new.attempt_status then

    -- The fan's "incoming call" ring, keyed to this call.
    update public.notifications
       set is_read = true, read_at = now()
     where event_type = 'VIDEO_CALL_INITIATED_FOR_FAN'
       and related_entity_type = 'call'
       and related_entity_id = new.id
       and is_read = false;

    -- The partner's "fan is ready" prompt and the next-fan queue alert, both
    -- keyed to the booking rather than the call.
    update public.notifications
       set is_read = true, read_at = now()
     where event_type in ('VIDEO_CALL_FAN_READY_PARTNER','VIDEO_CALL_QUEUE_NEXT_FAN')
       and related_entity_type = 'booking'
       and related_entity_id = new.booking_id
       and is_read = false;
  end if;
  return new;
end;
$$;

-- SECURITY DEFINER: the actor ending a call is not the recipient of every
-- notification being cleared (a partner completing a call clears the FAN's
-- ring), and notifications' RLS policy is recipient-scoped.

drop trigger if exists trg_clear_call_notifications on public.calls;
create trigger trg_clear_call_notifications
  after update of attempt_status on public.calls
  for each row execute function public.clear_call_notifications_on_terminal();

-- The existing indexes on notifications are recipient_id-first
-- (notification_recipient_idx, notification_unread_idx,
-- notifications_unique_active_event) — none usable for a lookup keyed on
-- related_entity_id without recipient_id, which is what both UPDATEs above
-- do (the trigger has a call/booking id, not the recipient, without an extra
-- join). Without this, each call termination forces a sequential scan of
-- notifications. Free at today's row count; not free once it isn't. Partial
-- + unread-only, matching notification_unread_idx's existing convention.
create index if not exists notification_entity_unread_idx
  on public.notifications (related_entity_type, related_entity_id)
  where not is_read;

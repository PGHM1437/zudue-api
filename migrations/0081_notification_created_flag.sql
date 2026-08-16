-- Adds a `created` flag to rpc_create_notification's return value, so callers
-- can tell an actually-new notification apart from an ON CONFLICT refresh of
-- an existing one.
--
-- Why: the queue-position alert (0080) fires from CallsService.initiate(),
-- which can legitimately run more than once for the same booking — a partner
-- retrying a call after a genuine miss (rpc_partner_initiate_call has only a
-- 60s ALREADY_INITIATED cooldown, not true idempotency; a retry after that
-- window inserts a fresh calls row and returns success again). On a retry,
-- the "next fan" notification hits the same (recipient_id, event_type,
-- related_entity_type, related_entity_id) tuple and correctly refreshes in
-- place rather than duplicating the ROW — but the caller was unconditionally
-- firing a fresh push alongside it every time, with no way to tell "this
-- fan was already told" from "this is the first time." That's the fix here:
-- expose which case happened so the caller can skip the push on a refresh.
--
-- (xmax = 0) is the standard Postgres idiom for "was this row just inserted,
-- not updated by the ON CONFLICT branch" — a freshly inserted row's xmax is 0;
-- a row touched by DO UPDATE gets xmax set to the current transaction.
--
-- Backward compatible: existing callers only reading `success` are unaffected.

create or replace function rpc_create_notification(
  p_recipient_id uuid,
  p_actor_id uuid,
  p_event_type notification_event_type_enum,
  p_title text,
  p_message text,
  p_related_entity_type notification_related_entity_type_enum,
  p_related_entity_id uuid,
  p_metadata jsonb
)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $$
declare
  v_created boolean;
begin
  insert into public.notifications
    (recipient_id, actor_id, event_type, title, message, related_entity_type, related_entity_id, metadata)
  values (p_recipient_id, p_actor_id, p_event_type, p_title, p_message, p_related_entity_type, p_related_entity_id, p_metadata)
  on conflict (recipient_id, event_type, related_entity_type, related_entity_id)
  do update set is_read = false, created_at = now()
  returning (xmax = 0) into v_created;

  return jsonb_build_object('success', true, 'created', v_created);
end;
$$;

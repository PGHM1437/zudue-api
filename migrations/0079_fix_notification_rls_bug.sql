-- Fix critical RLS bug: cross-user notification inserts silently failing.
-- (Referred to as C6 in DATABASE_AUDIT_REPORTS/18_TRUE_AUDIT_DEEP_VERIFICATION.md —
-- an internal audit label, not a tracked issue number.)
--
-- Problem: 4 places in the API layer insert notifications for a *different* user than the
-- caller's session. The RLS policy on notifications requires recipient_id = current_user_id(),
-- so these inserts violate RLS and Postgres raises an error. 3 of them swallow it with
-- .catch(() => undefined), so notifications vanish with no log. 1 (trust.module.ts report)
-- has no catch, so it rolls back the entire transaction, including the report record itself.
--
-- Solution: Create a SECURITY DEFINER RPC that the API layer can call with parameters,
-- bypassing the RLS restriction. Same pattern already used successfully for shoutout
-- notifications in rpc_admin_set_user_role.

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
begin
  insert into public.notifications
    (recipient_id, actor_id, event_type, title, message, related_entity_type, related_entity_id, metadata)
  values (p_recipient_id, p_actor_id, p_event_type, p_title, p_message, p_related_entity_type, p_related_entity_id, p_metadata)
  on conflict (recipient_id, event_type, related_entity_type, related_entity_id)
  do update set is_read = false, created_at = now();

  return jsonb_build_object('success', true);
end;
$$;

-- Verified 08-16 against live: public schema has a default privilege
-- (ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public) that already
-- auto-grants EXECUTE to zudue_app/authenticated/anon/service_role on every new
-- function, so these grants are redundant in practice — kept anyway, explicit
-- and harmless, matching this codebase's existing (inconsistent) convention of
-- granting some RPCs to authenticated and others to zudue_app directly.
grant execute on function rpc_create_notification to zudue_app;
grant execute on function rpc_create_notification to authenticated;

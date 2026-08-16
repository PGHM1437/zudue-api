-- Queue-position alert: when a partner initiates a call, proactively tell the
-- NEXT fan in their queue ("you're next in line") instead of leaving them with
-- zero signal until it's literally their turn. Matches legacy's
-- handle_call_status_notifications trigger in scope (single next-fan lookup,
-- not a full per-position queue) — see DATABASE_AUDIT_REPORTS/18_TRUE_AUDIT_DEEP_VERIFICATION.md.
--
-- The application-side lookup (CallsService.initiate) does the querying and
-- notifying; this migration only adds the notification_event_type_enum value
-- that lookup needs, since notifications.event_type has no live equivalent today.

alter type notification_event_type_enum add value if not exists 'VIDEO_CALL_QUEUE_NEXT_FAN';

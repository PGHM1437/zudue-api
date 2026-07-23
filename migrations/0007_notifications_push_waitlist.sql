-- 0007 · Notifications, FCM push tokens, waitlist (notify-when-available)

BEGIN;

CREATE TYPE notification_delivery_status AS ENUM ('QUEUED', 'SENT', 'DELIVERED', 'FAILED', 'READ');
CREATE TYPE waitlist_status AS ENUM ('WAITING', 'NOTIFIED', 'CONVERTED', 'EXPIRED');

CREATE TABLE notifications (
  id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  recipient_id         uuid NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  actor_id             uuid REFERENCES profiles(id),
  event_type           notification_event_type_enum NOT NULL,
  title                text,
  message              text NOT NULL DEFAULT '',
  related_entity_type  notification_related_entity_type_enum,
  related_entity_id    uuid,
  channels_sent        notification_channel_enum[],
  delivery_status      notification_delivery_status NOT NULL DEFAULT 'QUEUED',
  is_read              boolean NOT NULL DEFAULT false,
  read_at              timestamptz,
  metadata             jsonb,
  created_at           timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX notification_recipient_idx ON notifications (recipient_id, created_at DESC);
CREATE INDEX notification_unread_idx ON notifications (recipient_id) WHERE NOT is_read;

-- FCM-only device tokens (cleaned from the legacy web-push push_subscriptions).
CREATE TABLE push_tokens (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  profile_id  uuid NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  fcm_token   text NOT NULL,
  platform    text,                                          -- android | ios | web
  device_info jsonb NOT NULL DEFAULT '{}',
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT push_token_uq UNIQUE (fcm_token)
);
CREATE INDEX push_tokens_profile_idx ON push_tokens (profile_id);

-- Waitlist: fan asks to be told once when a booked/vacationing partner frees up.
-- Exactly one auto-notification per entry (status WAITING → NOTIFIED).
CREATE TABLE waitlist (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  fan_id      uuid NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  partner_id  uuid NOT NULL REFERENCES partner_profiles(profile_id) ON DELETE CASCADE,
  status      waitlist_status NOT NULL DEFAULT 'WAITING',
  created_at  timestamptz NOT NULL DEFAULT now(),
  notified_at timestamptz,
  CONSTRAINT waitlist_uq UNIQUE (fan_id, partner_id)
);
CREATE INDEX waitlist_partner_idx ON waitlist (partner_id) WHERE status = 'WAITING';

COMMIT;

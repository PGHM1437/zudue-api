-- 0005 · Services: video-call bookings + calls, DM conversations (clean model),
-- shout-outs. Reflects MESSAGING_AND_REALTIME.md + MONEY_MODEL.md:
--   • each service snapshots price_paise + links its escrow txn
--   • NO commission anywhere on services — commission is a partner-level rate
--     (partner_profiles.commission_rate) settled OFFLINE at payout
--   • settle_at drives the day-7 settlement; per-service fulfillment SLA
--   • DMs split into conversations / windows / messages (chat vs money)

BEGIN;

-- new enums for the clean DM model
CREATE TYPE dm_window_kind   AS ENUM ('FREE', 'PAID');
CREATE TYPE dm_window_status AS ENUM ('OPEN', 'ANSWERED', 'EXPIRED', 'REFUNDED');
CREATE TYPE message_sender   AS ENUM ('FAN', 'PARTNER');

-- ── Video-call bookings ─────────────────────────────────────────────────
CREATE TABLE bookings (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  fan_id             uuid NOT NULL REFERENCES profiles(id),
  partner_id         uuid NOT NULL REFERENCES partner_profiles(profile_id),   -- standardized
  scheduled_date     date NOT NULL,
  selected_duration  call_duration_options_enum NOT NULL,
  price_paise        bigint NOT NULL,
  original_price_paise bigint,                              -- pre-promo
  discount_paise     bigint NOT NULL DEFAULT 0,             -- platform-funded
  promo_code_id      uuid,
  status             booking_status NOT NULL DEFAULT 'BOOKED',
  fan_ready_at       timestamptz,
  attempts           integer NOT NULL DEFAULT 0,
  meeting_id         text,
  fan_note           text,
  cancellation_reason text,
  escrow_txn_id      uuid REFERENCES transactions(id),      -- the HELD payment
  settle_at          timestamptz NOT NULL,                  -- booking + 7 days
  created_at         timestamptz NOT NULL DEFAULT now(),
  updated_at         timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT booking_price_positive CHECK (price_paise > 0)
);
CREATE INDEX booking_fan_idx      ON bookings (fan_id, scheduled_date);
CREATE INDEX booking_partner_idx  ON bookings (partner_id, scheduled_date);
CREATE INDEX booking_settle_idx   ON bookings (settle_at) WHERE status = 'BOOKED';

-- ── Calls (retryable attempts; state machine in CallsService) ───────────
-- Strengthened vs live: first-class per-party heartbeats (indexed, not jsonb);
-- a hard deadline_at (started_at + booked minutes) so "remaining" is computed on
-- read, never a mutable stored countdown that can drift.
CREATE TABLE calls (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  booking_id         uuid NOT NULL REFERENCES bookings(id) ON DELETE CASCADE,
  fan_id             uuid REFERENCES profiles(id),
  partner_id         uuid REFERENCES partner_profiles(profile_id),
  attempt_status     call_status NOT NULL DEFAULT 'SCHEDULED',
  meeting_id         text,
  partner_initiated_at timestamptz,
  fan_joined_at      timestamptz,
  started_at         timestamptz,
  deadline_at        timestamptz,                 -- started_at + booked minutes (hard cap)
  ended_at           timestamptz,
  actual_duration_seconds integer,
  -- per-party heartbeats, first-class + indexed for the stalled-call sweep
  fan_last_heartbeat_at     timestamptz,
  partner_last_heartbeat_at timestamptz,
  heartbeat_count    integer NOT NULL DEFAULT 0,
  termination_reason text,
  created_at         timestamptz NOT NULL DEFAULT now(),
  updated_at         timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX call_booking_idx ON calls (booking_id);
CREATE INDEX call_active_idx  ON calls (attempt_status) WHERE attempt_status IN ('PARTNER_INITIATED','IN_PROGRESS');
-- stalled-call sweep: find live calls whose heartbeats went stale, fast
CREATE INDEX call_heartbeat_idx ON calls (attempt_status, fan_last_heartbeat_at, partner_last_heartbeat_at)
  WHERE attempt_status = 'IN_PROGRESS';
CREATE INDEX call_deadline_idx ON calls (deadline_at) WHERE attempt_status = 'IN_PROGRESS';

-- Append-only call event log — every state transition, for observability and
-- debugging dropped calls (why did this call end? who was heartbeating?).
CREATE TABLE call_events (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  call_id     uuid NOT NULL REFERENCES calls(id) ON DELETE CASCADE,
  event_type  text NOT NULL,          -- INITIATED | JOINED | HEARTBEAT | RECONNECT | ENDED | DROPPED | MISSED
  actor       text,                   -- FAN | PARTNER | SYSTEM
  detail      jsonb NOT NULL DEFAULT '{}',
  created_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX call_events_call_idx ON call_events (call_id, created_at);

-- ── DM conversations (one per fan↔partner pair) ─────────────────────────
CREATE TABLE conversations (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  fan_id           uuid NOT NULL REFERENCES profiles(id),
  partner_id       uuid NOT NULL REFERENCES partner_profiles(profile_id),
  last_activity_at timestamptz NOT NULL DEFAULT now(),
  blocked_at       timestamptz,                             -- partner blocked the fan
  blocked_by       uuid,
  created_at       timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT conversation_pair_uq UNIQUE (fan_id, partner_id)
);
CREATE INDEX conversation_partner_idx ON conversations (partner_id);

-- ── DM windows (the monetization unit; ex-"batch") ──────────────────────
CREATE TABLE conversation_windows (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  conversation_id  uuid NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
  kind             dm_window_kind NOT NULL,
  charge_paise     bigint NOT NULL DEFAULT 0,               -- 0 for FREE
  message_cap      integer NOT NULL DEFAULT 5,
  status           dm_window_status NOT NULL DEFAULT 'OPEN',
  response_deadline timestamptz,                            -- 48h for PAID
  escrow_txn_id    uuid REFERENCES transactions(id),
  settle_at        timestamptz,                             -- +7d for settlement
  opened_at        timestamptz NOT NULL DEFAULT now(),
  closed_at        timestamptz,
  CONSTRAINT window_charge_nonneg CHECK (charge_paise >= 0)
);
CREATE INDEX window_conversation_idx ON conversation_windows (conversation_id);
CREATE INDEX window_open_idx ON conversation_windows (status, response_deadline) WHERE status = 'OPEN';

-- ── Messages (the actual chat) ──────────────────────────────────────────
CREATE TABLE messages (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  window_id   uuid NOT NULL REFERENCES conversation_windows(id) ON DELETE CASCADE,
  sender      message_sender NOT NULL,
  body        text NOT NULL,
  created_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX message_window_idx ON messages (window_id, created_at);

-- ── Shout-outs (fan → partner records → admin reviews → delivers) ───────
CREATE TABLE shout_out_requests (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  fan_id              uuid NOT NULL REFERENCES profiles(id),
  partner_id          uuid NOT NULL REFERENCES partner_profiles(profile_id),
  recipient_name      text NOT NULL,
  gifter_name         text,
  occasion            text,
  pronunciation_guide text,
  message_for_partner text NOT NULL,
  price_paise         bigint NOT NULL,
  status              shout_out_status_enum NOT NULL DEFAULT 'AWAITING_PARTNER_VIDEO',
  escrow_txn_id       uuid REFERENCES transactions(id),
  settle_at           timestamptz NOT NULL,                 -- +5 business days SLA
  admin_handler_id    uuid,
  partner_video_storage_path text,
  partner_video_submitted_at timestamptz,
  admin_review_notes  text,
  delivered_video_link text,
  delivered_at        timestamptz,
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT shoutout_price_positive CHECK (price_paise > 0)
);
CREATE INDEX shoutout_fan_idx     ON shout_out_requests (fan_id);
CREATE INDEX shoutout_partner_idx ON shout_out_requests (partner_id);
CREATE INDEX shoutout_status_idx  ON shout_out_requests (status);

COMMIT;

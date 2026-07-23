-- 0009 · Trust & safety, disputes, webhook log, private feedback, audit
-- First-class blocking, unified reporting/moderation, payment disputes, an
-- idempotent inbound-webhook log, private (non-public) service feedback, and a
-- single audit_log (merging the 3 old log tables).

BEGIN;

CREATE TYPE block_scope        AS ENUM ('ALL', 'DM', 'BOOKING');
CREATE TYPE report_target_type AS ENUM ('PROFILE', 'CALL', 'DM', 'MESSAGE', 'SHOUTOUT');
CREATE TYPE report_status      AS ENUM ('PENDING', 'REVIEWING', 'RESOLVED', 'DISMISSED');
CREATE TYPE dispute_status     AS ENUM ('OPEN', 'UNDER_REVIEW', 'WON', 'LOST', 'CLOSED');
CREATE TYPE refund_reason      AS ENUM (
  'FAN_CANCEL', 'PARTNER_NO_SHOW', 'TECHNICAL', 'SLA_MISS',
  'ADMIN_GOODWILL', 'DISPUTE', 'ACCOUNT_CLOSURE');

-- Global, first-class blocking (beyond the per-DM conversations.blocked_at).
CREATE TABLE user_blocks (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  blocker_id  uuid NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  blocked_id  uuid NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  scope       block_scope NOT NULL DEFAULT 'ALL',
  reason      text,
  created_at  timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT user_block_uq UNIQUE (blocker_id, blocked_id, scope)
);
CREATE INDEX user_block_blocker_idx ON user_blocks (blocker_id);

-- Unified reporting + moderation queue.
CREATE TABLE reports (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  reporter_id   uuid NOT NULL REFERENCES profiles(id),
  target_type   report_target_type NOT NULL,
  target_id     uuid NOT NULL,
  reason        text NOT NULL,
  details       text,
  status        report_status NOT NULL DEFAULT 'PENDING',
  resolution    text,
  refund_paise  bigint,
  resolved_by   uuid REFERENCES profiles(id),
  resolved_at   timestamptz,
  created_at    timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX report_status_idx ON reports (status) WHERE status IN ('PENDING','REVIEWING');

-- Razorpay disputes / chargebacks.
CREATE TABLE disputes (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  transaction_id     uuid REFERENCES transactions(id),
  razorpay_dispute_id text UNIQUE,
  amount_paise       bigint NOT NULL,
  reason             text,
  status             dispute_status NOT NULL DEFAULT 'OPEN',
  opened_at          timestamptz NOT NULL DEFAULT now(),
  resolved_at        timestamptz
);

-- Idempotent inbound webhook log (Razorpay etc.) — replay-safe.
CREATE TABLE webhook_events (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  provider     text NOT NULL,
  event_id     text NOT NULL,
  event_type   text,
  payload      jsonb NOT NULL,
  status       text NOT NULL DEFAULT 'RECEIVED',   -- RECEIVED | PROCESSED | FAILED
  processed_at timestamptz,
  created_at   timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT webhook_event_uq UNIQUE (provider, event_id)   -- idempotency
);

-- (No service_feedback table — the product policy is NO reviews/ratings, public
--  or private. Trust signals come from moderation reports + admin curation.)

-- One audit log (merges admin_action_logs + audit_log + withdrawal_audit_log).
CREATE TABLE audit_log (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  actor_id      uuid REFERENCES profiles(id),
  actor_role    user_role,
  action        text NOT NULL,
  target_type   text,
  target_id     uuid,
  old_value     jsonb,
  new_value     jsonb,
  ip_address    text,
  user_agent    text,
  created_at    timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX audit_actor_idx  ON audit_log (actor_id, created_at DESC);
CREATE INDEX audit_target_idx ON audit_log (target_type, target_id);

COMMIT;

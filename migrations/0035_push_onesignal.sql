-- 0035 · Dual-channel push. Add OneSignal alongside FCM on push_tokens so the
-- backend can fan a high-priority "incoming call" to BOTH providers (redundancy
-- for aggressively-restricted Chinese OEMs). Upsert keys so re-registering a
-- device replaces its row instead of duplicating.

BEGIN;

ALTER TABLE push_tokens
  ADD COLUMN IF NOT EXISTS onesignal_player_id text,
  ADD COLUMN IF NOT EXISTS last_seen_at timestamptz DEFAULT now();

CREATE UNIQUE INDEX IF NOT EXISTS push_tokens_profile_fcm_uq
  ON push_tokens (profile_id, fcm_token) WHERE fcm_token IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS push_tokens_profile_onesignal_uq
  ON push_tokens (profile_id, onesignal_player_id) WHERE onesignal_player_id IS NOT NULL;

COMMIT;

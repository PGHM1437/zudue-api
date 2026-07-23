-- 0041 · Drop two prefix-redundant indexes.
--
-- Each of these indexes a single column that is already the LEADING column of
-- a non-partial UNIQUE index on the same table. A btree on (a) can serve no
-- query that a btree on (a, b) cannot: equality and range lookups on `a` use
-- the composite's leading column just as well. They cost writes and storage
-- and buy nothing.
--
--   partner_social_links_partner_idx (partner_id)
--     covered by partner_social_links_unique UNIQUE (partner_id, platform)
--   user_block_blocker_idx (blocker_id)
--     covered by user_block_uq UNIQUE (blocker_id, blocked_id, scope)
--
-- Deliberately NOT dropped, though the same query flagged it:
--   push_tokens_profile_idx (profile_id)
-- Its two apparent "covering" indexes are PARTIAL —
--   push_tokens_profile_fcm_uq (profile_id, fcm_token) WHERE fcm_token IS NOT NULL
--   push_tokens_profile_onesignal_uq (profile_id, onesignal_player_id)
--     WHERE onesignal_player_id IS NOT NULL
-- A plain `WHERE profile_id = $1` lookup does not imply either predicate, so
-- the planner cannot use them for it, and rows with both token columns null
-- would not be indexed at all. Dropping it would silently degrade the push
-- fan-out path to a sequential scan on the hot send path.

BEGIN;

DROP INDEX IF EXISTS public.partner_social_links_partner_idx;
DROP INDEX IF EXISTS public.user_block_blocker_idx;

COMMIT;

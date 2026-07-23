-- 0012 · Global blocking + admin-control fixes (see ADMIN_GAPS_AND_FIXES.md)
-- Closes: DM-only blocking → global; no fan account control; blocking enforcement.
-- (Commission rate, promo governance, referral crediting, unified reports,
--  disputes, admin RBAC roles are already tabled in 0006/0008/0009; the
--  behavior lives in NestJS admin services.)

BEGIN;

-- ── Global user account status (fans AND partners) ──────────────────────
CREATE TYPE user_account_status AS ENUM ('ACTIVE', 'SUSPENDED', 'BANNED');

ALTER TABLE profiles
  ADD COLUMN account_status     user_account_status NOT NULL DEFAULT 'ACTIVE',
  ADD COLUMN status_reason      text,
  ADD COLUMN status_changed_at  timestamptz,
  ADD COLUMN status_changed_by  uuid;      -- admin who suspended/banned
CREATE INDEX profiles_status_idx ON profiles (account_status)
  WHERE account_status <> 'ACTIVE';

-- ── Global blocking: user_blocks becomes the single source ──────────────
-- (table created in 0009). Add who initiated the block: partner or admin.
ALTER TABLE user_blocks
  ADD COLUMN created_by_admin boolean NOT NULL DEFAULT false;

-- Retire the DM-only block on conversations — blocking now reads user_blocks.
ALTER TABLE conversations
  DROP COLUMN blocked_at,
  DROP COLUMN blocked_by;

-- is_blocked(a,b): is there an active block between these two (either direction)
-- with scope ALL, or the given scope? Enforced by every interaction entry point
-- (booking, DM send, shout-out request) in the backend, and usable in RLS.
CREATE OR REPLACE FUNCTION is_blocked(p_a uuid, p_b uuid, p_scope block_scope DEFAULT 'ALL')
RETURNS boolean LANGUAGE sql STABLE SET search_path = '' AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.user_blocks ub
    WHERE ((ub.blocker_id = p_a AND ub.blocked_id = p_b)
        OR (ub.blocker_id = p_b AND ub.blocked_id = p_a))
      AND (ub.scope = 'ALL' OR ub.scope = p_scope)
  )
$$;

-- ── Refund reason on refund transactions (was unstructured) ─────────────
-- refund_reason enum created in 0009; attach it to the money event's meta is
-- possible, but a first-class column makes finance reporting trivial.
ALTER TABLE transactions
  ADD COLUMN refund_reason refund_reason;   -- NULL unless type = 'REFUND'

COMMIT;

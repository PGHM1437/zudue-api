-- 0026 · CRITICAL FIX: views were silently bypassing RLS for every caller.
--
-- Postgres views default to `security_invoker = false`: permission checks
-- against the underlying tables happen as the VIEW OWNER (the migrating
-- role), not the querying role. Since the view owner also owns the
-- underlying tables (and owners bypass RLS by default), RLS was never being
-- evaluated at all when going through a view — regardless of which role
-- queried it, or what current_user_id()/is_admin() would have said.
--
-- Verified exploitable: partner A, querying vw_partner_call_queue through the
-- zudue_app role scoped to their own identity, saw partner B's booking too.
-- The identical direct table query on `bookings` correctly showed only their
-- own row. This affected every view, including future ones — fixed at the
-- view level with `security_invoker = true` (PG15+, available on 17.x here),
-- which makes the view evaluate as the CALLING role, so the exact same RLS
-- policies that already protect direct table access now protect the view too.
-- zudue_app already holds direct SELECT on every table (migration 0025), so
-- no additional grants are needed for this to work correctly.

BEGIN;

ALTER VIEW vw_discover_partners SET (security_invoker = true);
ALTER VIEW vw_partner_call_queue SET (security_invoker = true);

-- Second-order finding, caught by the same test: with RLS actually enforced,
-- vw_partner_call_queue now returns ZERO rows for everyone — not just the
-- fixed leak, an outright regression. Its JOIN to profiles (for the fan's
-- display name) has no RLS path: profiles_public_partner only makes
-- role='PARTNER' rows public, so a partner has no policy allowing them to
-- read a FAN's profile row at all, even one they have an active booking
-- with. The inner join silently drops every row. This is the same class of
-- gap as the RPC authorization bypass from before — a feature that looked
-- correct because it was never actually tested under enforced RLS.
-- Fix: a partner may read a fan's profile row specifically when a booking,
-- conversation, or shout-out already connects them — not arbitrary fan
-- browsing, just "who is this counterparty I'm already transacting with."
CREATE POLICY profiles_counterparty_read ON profiles FOR SELECT USING (
  role = 'FAN' AND (
    EXISTS (SELECT 1 FROM bookings b WHERE b.fan_id = profiles.id AND b.partner_id = current_user_id())
    OR EXISTS (SELECT 1 FROM conversations c WHERE c.fan_id = profiles.id AND c.partner_id = current_user_id())
    OR EXISTS (SELECT 1 FROM shout_out_requests s WHERE s.fan_id = profiles.id AND s.partner_id = current_user_id())
  )
);

COMMIT;

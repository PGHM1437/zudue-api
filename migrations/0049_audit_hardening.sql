-- 0049 · Findings from the security/integrity audit.
--
-- The schema came out clean on the checks that matter most: every table has
-- RLS enabled AND at least one policy, every SECURITY DEFINER function pins
-- search_path, no write policy is USING(true), every table has a primary key,
-- and the money tables carry positivity CHECKs. What follows is the residue.

BEGIN;

-- ── 1 · Views that bypass RLS ───────────────────────────────────────────
-- Without security_invoker a view executes as its OWNER, so RLS on the
-- underlying tables does not apply to the caller. 0029 set this on all ten
-- admin views for exactly that reason; three views missed it — two added by me
-- earlier in this work, one dating to 0019.
--
-- None is presently exploitable: both admin views carry `WHERE is_admin()` in
-- their own body (verified — a non-admin selects zero rows), and
-- vw_discover_partners reads partner_profiles, which is public-read by design
-- (partner_public_read USING (true)), so invoker rights change nothing there.
-- The point is the backstop: if a later edit drops that WHERE clause, RLS
-- should still refuse the rows rather than the view silently going wide open.
ALTER VIEW public.vw_admin_audit_log            SET (security_invoker = true);
ALTER VIEW public.vw_admin_promo_beneficiaries  SET (security_invoker = true);
ALTER VIEW public.vw_discover_partners          SET (security_invoker = true);

-- ── 2 · Missing index on a per-request hot path ─────────────────────────
-- /me derives partner_lifecycle with:
--     SELECT ... FROM partner_applications WHERE profile_id = $1
--     ORDER BY submitted_at DESC LIMIT 1
-- and /me is called on every app launch and every router redirect. EXPLAIN
-- confirmed a Seq Scan + Sort. The composite matches the filter AND the sort,
-- so the plan becomes a single index lookup with no sort at all.
CREATE INDEX IF NOT EXISTS partner_applications_profile_idx
  ON public.partner_applications (profile_id, submitted_at DESC);

-- ── 3 · Missing index on the payout write path ──────────────────────────
-- rpc_process_payout and rpc_create_payout_batch both run
--   UPDATE partner_earnings SET ... WHERE payout_id = $1
-- Unindexed, that is a full scan of the earnings table on every payout —
-- the table that grows fastest of any in the system.
CREATE INDEX IF NOT EXISTS partner_earnings_payout_idx
  ON public.partner_earnings (payout_id) WHERE payout_id IS NOT NULL;

-- favourites.partner_id had no index: the FK is ON DELETE CASCADE, so removing
-- a partner_profiles row would scan the whole table.
CREATE INDEX IF NOT EXISTS favourites_partner_idx ON public.favourites (partner_id);

-- ── 4 · The promo funding identity, enforced ────────────────────────────
-- Since 0042 promos are platform-funded, and the escrow maths depends on
--   original_price_paise (into escrow) = price_paise (fan) + discount_paise
-- If those three ever disagree, settlement pays a creator more than escrow
-- received. rpc_book_video_call computes all three from resolve_price so they
-- agree today; this makes it impossible for any other writer to break.
-- NULL-tolerant for rows predating 0042 (there are none on either database).
ALTER TABLE public.bookings
  ADD CONSTRAINT booking_discount_nonneg CHECK (discount_paise IS NULL OR discount_paise >= 0),
  ADD CONSTRAINT booking_price_identity CHECK (
    original_price_paise IS NULL
    OR original_price_paise = price_paise + COALESCE(discount_paise, 0));

-- ── 5 · Promo value guarded at the table, not only in the RPC ───────────
-- rpc_admin_create_promo rejects p_value <= 0, but nothing stopped a direct
-- INSERT/UPDATE from setting a negative discount, which resolve_price would
-- turn into a NEGATIVE discount — i.e. charging the fan MORE than list while
-- the platform "funds" a negative amount.
ALTER TABLE public.promo_codes
  ADD CONSTRAINT promo_discount_value_positive CHECK (discount_value > 0);

ALTER TABLE public.promo_code_usages
  ADD CONSTRAINT promo_usage_discount_nonneg CHECK (discount_paise >= 0);

COMMIT;

-- 0044 · Drop partner_tags — a second, unbuilt discovery taxonomy.
--
-- partner_tags is NOT the categories system. 0008 created both, side by side,
-- under the comment "Discovery taxonomy (structured categories + free tags)":
--
--   categories(slug, name, sort_order, is_active)
--     + partner_categories(partner_id, category_id)
--       Admin-curated structured taxonomy. Seeded in 0020 (finance, healthcare,
--       wellness, ...). Aggregated into vw_discover_partners.categories and
--       filtered by the live feed: `WHERE $1 = ANY(categories)`. Exposed via
--       GET /discover/categories and used by the mobile home screen.
--       => fully built, wired end to end, KEPT.
--
--   partner_tags(partner_id, tag)
--     Free-text keyword tags. Never seeded, never written, never read. Absent
--     from every view, every RPC, the API layer and both clients. Its only
--     traces are its own CREATE TABLE, one index, and two RLS policies.
--       => a parallel mechanism for a job categories already does, built to
--          zero percent. Over-engineering, not a feature.
--
-- Nothing to consolidate: the table holds 0 rows on both databases, so there
-- is no data to migrate into partner_categories. Should free-text tagging ever
-- be wanted, it is a fresh table plus the discovery/API/UI work that was never
-- done here — not this empty shell.
--
-- Dropping the table also removes its index and its two RLS policies; the
-- cascade is limited to those, since nothing references it.

BEGIN;

DO $$
DECLARE v_rows bigint;
BEGIN
  -- Refuse to drop if this environment somehow has data, rather than
  -- destroying rows that a later environment turned out to be using.
  SELECT count(*) INTO v_rows FROM public.partner_tags;
  IF v_rows > 0 THEN
    RAISE EXCEPTION 'partner_tags holds % row(s) — not dropping. Reassess before removing.', v_rows;
  END IF;
END $$;

DROP TABLE IF EXISTS public.partner_tags;

COMMIT;

-- 0038 · Fix a real duplicate-row bug in partner_services.
--
-- rpc_partner_set_service upserts on (partner_id, service_type, duration).
-- For QUICK_QUESTION and SHOUT_OUT, duration is NULL — and the unique index
-- was plain, so Postgres treated the NULLs as DISTINCT (default semantics,
-- confirmed by reproduction on 17.4). Result: editing a question/shout-out
-- price a SECOND time did not conflict → it INSERTED a duplicate active row.
-- vw_discover_partners then reads the price with a scalar subquery
-- (SELECT price_paise ... WHERE service_type='QUICK_QUESTION') which errors
-- "more than one row returned by a subquery" — silently breaking that
-- partner's discovery card (and the feed query) the moment they re-price.
--
-- Fix: NULLS NOT DISTINCT (PG15+) so (partner, QUICK_QUESTION, NULL) collides
-- with itself and the upsert updates in place. Dedupe any rows that already
-- slipped through before recreating the index.

BEGIN;

-- Keep the most-recently-updated row per (partner, type, duration) group;
-- delete older duplicates so the unique index can be built.
DELETE FROM partner_services a
USING partner_services b
WHERE a.partner_id = b.partner_id
  AND a.service_type = b.service_type
  AND a.duration IS NOT DISTINCT FROM b.duration
  AND a.updated_at < b.updated_at;

-- It's a table CONSTRAINT (not a bare index), so drop/recreate as a constraint.
ALTER TABLE partner_services DROP CONSTRAINT IF EXISTS partner_services_unique;
ALTER TABLE partner_services
  ADD CONSTRAINT partner_services_unique
  UNIQUE NULLS NOT DISTINCT (partner_id, service_type, duration);

COMMIT;

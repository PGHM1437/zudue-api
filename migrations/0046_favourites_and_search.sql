-- 0046 · Favourites + creator search + shareable profile handles.
--
-- FAVOURITES — a fan had no way to save a creator. Deliberately a new table
-- rather than reusing `waitlist`: waitlist is a one-shot "tell me when this
-- creator is bookable again" that self-clears on notify (status WAITING ->
-- NOTIFIED). A favourite is a durable list the fan curates and revisits.
-- Overloading one on the other would mean a fan's saved list silently emptying
-- itself every time a creator came back online.
--
-- SEARCH — discovery could only filter by category. A fan who knew a creator's
-- name could not find them. Adds trigram indexes on display_name and bio so
-- ILIKE '%term%' stays index-backed instead of degrading to a seq scan as the
-- roster grows. pg_trgm is already available (0001 enables extensions).
--
-- HANDLES — creators need a link for their Instagram/YouTube bio that opens
-- their profile directly in the app. A raw uuid is hostile in a bio, so each
-- partner gets a stable, unique, human handle. Backfilled from display_name,
-- de-duplicated with a numeric suffix, and NOT NULL-safe: the resolver falls
-- back to uuid lookup so a missing handle can never 404 a valid profile.

BEGIN;

CREATE EXTENSION IF NOT EXISTS pg_trgm;

-- ── Favourites ──────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS favourites (
  fan_id     uuid NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  partner_id uuid NOT NULL REFERENCES partner_profiles(profile_id) ON DELETE CASCADE,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (fan_id, partner_id)
);
CREATE INDEX IF NOT EXISTS favourites_fan_idx ON favourites (fan_id, created_at DESC);

ALTER TABLE favourites ENABLE ROW LEVEL SECURITY;
-- A fan's saved list is private to them (admins included for support).
CREATE POLICY favourites_owner ON favourites FOR ALL
  USING (fan_id = current_user_id() OR is_admin())
  WITH CHECK (fan_id = current_user_id());

CREATE OR REPLACE FUNCTION rpc_toggle_favourite(p_partner uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_me uuid := public.current_user_id(); v_deleted int;
BEGIN
  IF v_me IS NULL THEN RETURN jsonb_build_object('success',false,'error','NO_IDENTITY'); END IF;
  IF NOT EXISTS (SELECT 1 FROM public.partner_profiles WHERE profile_id = p_partner) THEN
    RETURN jsonb_build_object('success',false,'error','PARTNER_NOT_FOUND'); END IF;

  DELETE FROM public.favourites WHERE fan_id = v_me AND partner_id = p_partner;
  GET DIAGNOSTICS v_deleted = ROW_COUNT;
  IF v_deleted > 0 THEN
    RETURN jsonb_build_object('success',true,'favourited',false);
  END IF;

  INSERT INTO public.favourites (fan_id, partner_id) VALUES (v_me, p_partner)
    ON CONFLICT DO NOTHING;
  RETURN jsonb_build_object('success',true,'favourited',true);
END $$;

REVOKE ALL ON FUNCTION rpc_toggle_favourite(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION rpc_toggle_favourite(uuid) TO zudue_app;

-- ── Shareable handle ────────────────────────────────────────────────────
ALTER TABLE partner_profiles ADD COLUMN IF NOT EXISTS handle text;

-- Backfill: slugify display_name, strip to [a-z0-9_], collapse repeats, and
-- suffix duplicates deterministically by created order.
WITH base AS (
  SELECT profile_id,
         NULLIF(regexp_replace(lower(COALESCE(display_name,'')), '[^a-z0-9]+', '_', 'g'), '') AS raw
    FROM partner_profiles
   WHERE handle IS NULL
), cleaned AS (
  SELECT profile_id,
         COALESCE(NULLIF(btrim(regexp_replace(raw, '_+', '_', 'g'), '_'), ''), 'creator') AS slug
    FROM base
), numbered AS (
  SELECT profile_id, slug,
         row_number() OVER (PARTITION BY slug ORDER BY profile_id) AS rn
    FROM cleaned
)
UPDATE partner_profiles pp
   SET handle = CASE WHEN n.rn = 1 THEN n.slug ELSE n.slug || n.rn::text END
  FROM numbered n
 WHERE pp.profile_id = n.profile_id;

CREATE UNIQUE INDEX IF NOT EXISTS partner_profiles_handle_uq
  ON partner_profiles (lower(handle)) WHERE handle IS NOT NULL;

-- ── Search indexes ──────────────────────────────────────────────────────
CREATE INDEX IF NOT EXISTS partner_profiles_name_trgm
  ON partner_profiles USING gin (display_name gin_trgm_ops);
CREATE INDEX IF NOT EXISTS partner_profiles_bio_trgm
  ON partner_profiles USING gin (bio gin_trgm_ops);

-- ── Discovery view: expose the handle so the client can build share links ──
-- CREATE OR REPLACE VIEW cannot reorder or rename existing columns, so the
-- new one is appended last (learned in 0037).
CREATE OR REPLACE VIEW vw_discover_partners AS
SELECT pp.profile_id, pp.display_name, pp.bio, pp.profile_image_path,
       pp.is_premium, pp.is_featured,
       (SELECT min(s.price_paise) FROM partner_services s
         WHERE s.partner_id=pp.profile_id AND s.service_type='VIDEO_CALL' AND s.is_active) AS min_call_price_paise,
       (SELECT s.price_paise FROM partner_services s
         WHERE s.partner_id=pp.profile_id AND s.service_type='QUICK_QUESTION' AND s.is_active) AS question_price_paise,
       (SELECT s.price_paise FROM partner_services s
         WHERE s.partner_id=pp.profile_id AND s.service_type='SHOUT_OUT' AND s.is_active) AS shoutout_price_paise,
       (SELECT array_agg(c.slug) FROM partner_categories pc
          JOIN categories c ON c.id=pc.category_id WHERE pc.partner_id=pp.profile_id) AS categories,
       CASE WHEN pp.is_featured THEN 0 WHEN pp.is_premium THEN 1 ELSE 2 END AS suggest_rank,
       pp.handle
  FROM partner_profiles pp
 WHERE pp.status='ACTIVE' AND pp.is_active AND NOT pp.vacation_mode
 ORDER BY CASE WHEN pp.is_featured THEN 0 WHEN pp.is_premium THEN 1 ELSE 2 END, pp.display_name;

COMMIT;

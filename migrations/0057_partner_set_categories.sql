-- 0057 · Let a creator choose their own categories.
--
-- `categories` and `partner_categories` have existed since 0008 and drive
-- discovery: vw_discover_partners aggregates the slugs and the feed filters on
-- `WHERE $1 = ANY(categories)`. But nothing could ever WRITE partner_categories
-- — no RPC, no endpoint, no screen. Every creator was therefore uncategorised,
-- which makes the category filter on the fan home screen permanently empty.
--
-- Replace-all semantics: the client sends the full set it wants, which is how
-- a multi-select UI behaves. Sending [] clears them.
--
-- Capped at 3. A creator in eight categories is in none of them as far as a
-- browsing fan is concerned, and the cap belongs next to the data rather than
-- in a form that any other caller could bypass.

BEGIN;

CREATE OR REPLACE FUNCTION rpc_partner_set_categories(p_partner uuid, p_slugs text[])
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_ids uuid[]; v_found int;
BEGIN
  PERFORM public.assert_caller(p_partner);

  IF NOT EXISTS (SELECT 1 FROM public.partner_profiles WHERE profile_id = p_partner) THEN
    RETURN jsonb_build_object('success',false,'error','NOT_A_PARTNER'); END IF;

  IF p_slugs IS NULL THEN p_slugs := ARRAY[]::text[]; END IF;

  IF array_length(p_slugs,1) > 3 THEN
    RETURN jsonb_build_object('success',false,'error','TOO_MANY_CATEGORIES','max',3); END IF;

  -- Resolve slugs to ids, rejecting anything unknown or retired rather than
  -- silently dropping it — a category that vanishes from the profile without
  -- explanation is worse than an error.
  SELECT array_agg(c.id), count(*) INTO v_ids, v_found
    FROM public.categories c
   WHERE c.slug = ANY(p_slugs) AND c.is_active;

  IF coalesce(v_found,0) <> coalesce(array_length(p_slugs,1),0) THEN
    RETURN jsonb_build_object('success',false,'error','UNKNOWN_CATEGORY'); END IF;

  DELETE FROM public.partner_categories WHERE partner_id = p_partner;

  IF v_ids IS NOT NULL THEN
    INSERT INTO public.partner_categories (partner_id, category_id)
      SELECT p_partner, unnest(v_ids)
    ON CONFLICT DO NOTHING;
  END IF;

  RETURN jsonb_build_object('success',true,'count',coalesce(array_length(v_ids,1),0));
END $$;

REVOKE ALL ON FUNCTION rpc_partner_set_categories(uuid, text[]) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION rpc_partner_set_categories(uuid, text[]) TO zudue_app;

INSERT INTO _migrations (name) VALUES ('0057_partner_set_categories.sql')
  ON CONFLICT (name) DO NOTHING;

COMMIT;

-- 0073 · Promo code max-uses CHECK constraints.
--
-- The columns `max_uses_total` and `max_uses_per_user` already exist on
-- promo_codes (nullable integers), and `current_total_uses` tracks usage.
-- But there are no CHECK constraints to prevent invalid values:
--   - max_uses_total could be set to 0 or negative (code would never activate)
--   - max_uses_per_user could be set to 0 or negative (nobody could use it)
--
-- Both columns are nullable (NULL = unlimited), so the CHECK only fires when
-- a value is explicitly set.

BEGIN;

-- Drop old constraints if they exist (idempotent)
ALTER TABLE public.promo_codes
  DROP CONSTRAINT IF EXISTS promo_codes_max_uses_total_check;

ALTER TABLE public.promo_codes
  DROP CONSTRAINT IF EXISTS promo_codes_max_uses_per_user_check;

-- When set, max_uses_total must be positive
ALTER TABLE public.promo_codes
  ADD CONSTRAINT promo_max_total_positive
  CHECK (max_uses_total IS NULL OR max_uses_total > 0);

-- When set, max_uses_per_user must be positive
ALTER TABLE public.promo_codes
  ADD CONSTRAINT promo_max_per_user_positive
  CHECK (max_uses_per_user IS NULL OR max_uses_per_user > 0);

-- current_total_uses must never go negative (defensive — should be enforced
-- by the application logic, but a DB backstop prevents drift)
ALTER TABLE public.promo_codes
  DROP CONSTRAINT IF EXISTS promo_codes_current_total_uses_check;

ALTER TABLE public.promo_codes
  ADD CONSTRAINT promo_current_uses_nonneg
  CHECK (current_total_uses >= 0);

INSERT INTO _migrations (name) VALUES ('0073_promo_max_uses_checks.sql')
  ON CONFLICT (name) DO NOTHING;

COMMIT;

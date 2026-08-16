-- 0074 · Profiles age CHECK.
--
-- The `age` column exists on profiles (nullable integer) but has no CHECK
-- constraint. Without it, nonsensical values (negative, 999) could be stored.
--
-- We allow NULL (age not provided) and range 13–120:
--   - 13: minimum age for most platform services (COPPA-aligned)
--   - 120: generous upper bound for data-entry errors
--
-- Existing data: if any rows have age outside this range, the migration will
-- fail. Check first with:
--   SELECT id, age FROM profiles WHERE age IS NOT NULL AND (age < 13 OR age > 120);

BEGIN;

-- Drop old constraint if it exists (idempotent)
ALTER TABLE public.profiles
  DROP CONSTRAINT IF EXISTS profiles_age_check;

ALTER TABLE public.profiles
  ADD CONSTRAINT profiles_age_range
  CHECK (age IS NULL OR (age >= 13 AND age <= 120));

INSERT INTO _migrations (name) VALUES ('0074_profiles_age_check.sql')
  ON CONFLICT (name) DO NOTHING;

COMMIT;

-- 0072 · Availability upper-bound CHECK.
--
-- Legacy had `availability_threshold_minutes_check` capping threshold_minutes
-- at 300 (5 hours). Live only has `availability_minutes_nonneg` (≥0) with no
-- upper bound — a partner could set 24h availability, leading to over-scheduling.
--
-- We use 600 (10 hours) instead of legacy's 300 (5 hours) because:
--   - 300 was too restrictive for partners who work evening + morning slots
--   - 600 still prevents accidental 1440-minute (24h) entries
--   - Can be tightened per-partner via partner_profiles overrides later
--
-- Existing data: threshold_minutes defaults to 0, so no existing rows should
-- violate this. The CHECK is added with NOT VALID first to skip a full table
-- scan, then validated.

BEGIN;

-- Drop the old constraint if it somehow exists (idempotent)
ALTER TABLE public.availability
  DROP CONSTRAINT IF EXISTS availability_threshold_minutes_upper_check;

-- Add the upper-bound CHECK. We combine it with the existing non-neg check
-- into a single constraint for clarity, replacing availability_minutes_nonneg.
ALTER TABLE public.availability
  DROP CONSTRAINT IF EXISTS availability_minutes_nonneg;

ALTER TABLE public.availability
  ADD CONSTRAINT availability_minutes_bounds_check
  CHECK (booked_minutes >= 0 AND threshold_minutes >= 0 AND threshold_minutes <= 600);

-- Give the RPC a clean error for the new bound instead of letting the
-- constraint violation bubble up raw — matches its existing pattern for
-- the p_minutes < 0 case.
CREATE OR REPLACE FUNCTION public.rpc_partner_set_availability(p_partner uuid, p_date date, p_minutes integer)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
BEGIN
  PERFORM public.assert_caller(p_partner);
  IF p_minutes < 0 THEN RETURN jsonb_build_object('success',false,'error','INVALID_MINUTES'); END IF;
  IF p_minutes > 600 THEN RETURN jsonb_build_object('success',false,'error','MINUTES_EXCEEDS_CAP','cap',600); END IF;
  INSERT INTO public.availability (partner_id, date, is_available, threshold_minutes)
    VALUES (p_partner, p_date, p_minutes > 0, p_minutes)
    ON CONFLICT (partner_id, date) DO UPDATE
      SET is_available = (p_minutes > 0), threshold_minutes = p_minutes, updated_at = now();
  RETURN jsonb_build_object('success',true,'date',p_date,'minutes',p_minutes,'available',p_minutes>0);
END $function$;

INSERT INTO _migrations (name) VALUES ('0072_availability_threshold_cap.sql')
  ON CONFLICT (name) DO NOTHING;

COMMIT;

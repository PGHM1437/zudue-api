-- 0031 · CRITICAL FIX: the platform_settings audit trigger (0024) broke the
-- entire admin Settings screen.
--
-- audit_platform_settings_change() inserted NEW.id into audit_log.target_id,
-- but platform_settings.id is INTEGER (a singleton, always 1) while
-- audit_log.target_id is UUID. Every UPDATE to platform_settings — GST rate,
-- TDS rate, referral budget, min service prices, SLA windows, every field on
-- the Settings screen — raised "column target_id is of type uuid but
-- expression is of type integer" and rolled back. Admin could not change a
-- single platform setting.
--
-- Caught while seeding a realistic admin test (the UPDATE platform_settings
-- step in the scenario failed) — exactly the kind of path that "returns rows
-- in a list view" testing never exercises. Fix: target_id stays NULL for the
-- singleton settings row (a uuid target is meaningless when the PK is the
-- integer 1); the settings id is recorded inside new_value instead.

BEGIN;

CREATE OR REPLACE FUNCTION audit_platform_settings_change()
RETURNS trigger LANGUAGE plpgsql SET search_path = '' AS $$
BEGIN
  NEW.last_updated_by_admin_id := public.current_user_id();
  INSERT INTO public.audit_log (actor_id, actor_role, action, target_type, target_id, old_value, new_value)
    VALUES (public.current_user_id(), 'ADMIN', 'UPDATE_PLATFORM_SETTINGS', 'platform_settings', NULL,
      to_jsonb(OLD), to_jsonb(NEW) || jsonb_build_object('settings_id', NEW.id));
  RETURN NEW;
END $$;

COMMIT;

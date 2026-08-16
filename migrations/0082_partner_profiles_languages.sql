-- Adds the languages column the redesign's partner-profile edit screen has
-- shown since the rebuild, previously local-only (REDESIGN_TODO.md #5 — the
-- chips existed but selection was never persisted, no backend column at all).

alter table public.partner_profiles add column if not exists languages text[];

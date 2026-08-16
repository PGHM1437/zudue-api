-- 0068 · Columns dropped in the legacy→live rewrite with no replacement (M2, M3).
--
-- M2: shout_out_requests.pronunciation_guide — a fan requesting a shout-out
-- can no longer tell the creator how to pronounce the recipient's name. Real
-- product-feature loss for a personalised-video service, not an
-- architectural change.
--
-- M3: partner_payouts.admin_approver_id — legacy recorded which admin
-- approved a payout directly on the row (fk_payouts_admin_approver ->
-- profiles(id) ON DELETE SET NULL). rpc_process_payout already writes an
-- audit_log entry, but the payout row itself has no direct pointer to who
-- approved it.

BEGIN;

ALTER TABLE public.shout_out_requests
  ADD COLUMN pronunciation_guide TEXT;

ALTER TABLE public.partner_payouts
  ADD COLUMN admin_approver_id UUID REFERENCES public.profiles(id) ON DELETE SET NULL;

INSERT INTO _migrations (name) VALUES ('0068_missing_columns.sql')
  ON CONFLICT (name) DO NOTHING;

COMMIT;

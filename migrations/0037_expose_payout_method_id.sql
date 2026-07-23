-- 0037 · Expose payout_method_id on the pending-withdrawals view.
--
-- The admin withdrawals screen needs to verify a partner's payout METHOD before
-- releasing money to it, but vw_admin_pending_withdrawals (0029) surfaced the
-- method's details without its id — so there was no way to call
-- rpc_admin_verify_payout_method from that screen, and gating "Pay" on
-- verification with no verify path would have deadlocked payouts. Add pm.id.
-- CREATE OR REPLACE keeps the same is_admin()+security_invoker properties.

BEGIN;

-- Note: pm.id is appended LAST, not inserted mid-list — CREATE OR REPLACE VIEW
-- cannot reorder/rename existing columns, only append new ones.
CREATE OR REPLACE VIEW vw_admin_pending_withdrawals AS
SELECT po.id AS payout_id, po.partner_id, pp.display_name, po.amount_paise, po.status, po.requested_at,
       pm.method_type, pm.account_holder_name, pm.account_number,
       pm.ifsc_code, pm.bank_name, pm.upi_id, pm.is_verified,
       pm.id AS payout_method_id
FROM partner_payouts po
JOIN partner_profiles pp ON pp.profile_id = po.partner_id
JOIN payout_methods pm ON pm.id = po.payout_method_id
WHERE po.status IN ('REQUESTED', 'APPROVED', 'PROCESSING') AND is_admin();
ALTER VIEW vw_admin_pending_withdrawals SET (security_invoker = true);

COMMIT;

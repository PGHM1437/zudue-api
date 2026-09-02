-- 0093 · Lock the self-elevating system RPCs to the system.
--
-- WHY
-- A set of SECURITY DEFINER functions gate themselves with assert_system()
-- ( = is_admin() OR is_service_role() ) yet are still EXECUTE-granted to
-- PUBLIC, anon, authenticated, service_role and zudue_app -- verified live:
-- has_function_privilege('anon', oid, 'EXECUTE') is true for every one of them.
-- Several move money (rpc_settle_booking, rpc_settle_window, rpc_verify_topup)
-- or destroy data (rpc_purge_profile).
--
-- assert_system() does reject a raw PostgREST call made with the anon/authed
-- key today: it reads the GUCs app.user_id / app.is_service_role, which only
-- this application sets and PostgREST never does. So this is not a live hole --
-- it is a single check standing in front of "pay this creator from escrow",
-- with no second layer. Revoke the grant as well.
--
-- 0090 already revokes process_end_of_day_expired_bookings() and
-- cleanup_stalled_calls(). This migration covers the rest.
--
-- rpc_complete_call is deliberately NOT included: its p_auto=false branch is a
-- legitimate participant action (assert_caller_any(fan_id, partner_id)), so it
-- is not a pure system function. Its p_auto=true branch keeps assert_system().
--
-- NOT AFFECTED
-- The owner (postgres) keeps EXECUTE implicitly and cannot be revoked from.
-- The app connects as postgres; every money RPC runs through db.rpc() on that
-- connection (verified: wallet.service.ts calls rpc_verify_topup / rpc_record_
-- dispute inside runAsService, which only sets a GUC -- the role stays
-- postgres). pg_cron's job_* wrappers are SECURITY DEFINER owned by postgres.
-- Nothing that legitimately calls these loses access.
--
-- REVERSIBLE: GRANT EXECUTE ON FUNCTION public.<name>(<args>) TO authenticated;

BEGIN;

REVOKE ALL ON FUNCTION public.rpc_settle_booking(uuid)          FROM PUBLIC, anon, authenticated, service_role, zudue_app;
REVOKE ALL ON FUNCTION public.rpc_settle_window(uuid)           FROM PUBLIC, anon, authenticated, service_role, zudue_app;
REVOKE ALL ON FUNCTION public.rpc_settle_shoutout(uuid)         FROM PUBLIC, anon, authenticated, service_role, zudue_app;
REVOKE ALL ON FUNCTION public.rpc_auto_confirm_shoutout(uuid)   FROM PUBLIC, anon, authenticated, service_role, zudue_app;
REVOKE ALL ON FUNCTION public.rpc_expire_shoutout(uuid)         FROM PUBLIC, anon, authenticated, service_role, zudue_app;
REVOKE ALL ON FUNCTION public.rpc_cleanup_abandoned_topups()    FROM PUBLIC, anon, authenticated, service_role, zudue_app;
REVOKE ALL ON FUNCTION public.rpc_verify_topup(text, text)      FROM PUBLIC, anon, authenticated, service_role, zudue_app;
REVOKE ALL ON FUNCTION public.rpc_credit_referral(uuid)         FROM PUBLIC, anon, authenticated, service_role, zudue_app;
REVOKE ALL ON FUNCTION public.rpc_record_dispute(text, text, bigint, text, public.dispute_status)
                                                               FROM PUBLIC, anon, authenticated, service_role, zudue_app;
REVOKE ALL ON FUNCTION public.rpc_purge_profile(uuid)           FROM PUBLIC, anon, authenticated, service_role, zudue_app;

INSERT INTO _migrations (name) VALUES ('0093_lock_system_rpcs.sql') ON CONFLICT (name) DO NOTHING;

COMMIT;

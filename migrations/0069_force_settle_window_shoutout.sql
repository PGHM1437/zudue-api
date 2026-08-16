-- 0069 · Force-settle escape hatches for windows and shout-outs (C5).
--
-- ⚠️ NEEDS REVIEW BEFORE APPLYING — this is a money-moving RPC pair, kept in
-- its own migration deliberately (separate from the plain index/constraint
-- fixes) so it gets read on its own rather than skimmed as part of a batch.
--
-- rpc_admin_force_settle_booking already exists (0063) for the case where
-- the settlement sweep misses a booking. Confirmed live this session: one
-- booking needed exactly this manual rescue (audit_log FORCE_SETTLE row,
-- 2026-08-09), and no equivalent exists for conversation_windows or
-- shout_out_requests — one of each is currently stuck with no remedy at all.
--
-- Both new functions mirror rpc_admin_force_settle_booking's own pattern
-- exactly (verified via pg_get_functiondef, not reconstructed from memory):
-- assert_admin_role gate, a settleability pre-check, delegate to the
-- underlying rpc_settle_* function (idempotent — replays return
-- already_settled:true rather than double-crediting), then an audit_log row
-- only on success.
--
-- The two wrappers are NOT identical in one respect, and that's
-- intentional, not an inconsistency:
--   - rpc_settle_window has no internal status gate (only checks
--     kind='PAID' and charge_paise<>0), so this wrapper adds the
--     kind/status pre-check itself — exactly like the booking wrapper does
--     for booking_status, because rpc_settle_booking has no internal gate
--     either.
--   - rpc_settle_shoutout DOES have its own internal gate
--     (status<>'VIDEO_DELIVERED_TO_FAN' OR fan_confirmed_at IS NULL ->
--     NOT_SETTLEABLE), verified via pg_get_functiondef. Duplicating that
--     check here would just be redundant, so the shout-out wrapper trusts
--     the underlying function's own gate.
--
-- Follow-up (not part of this migration, application code):
--   apps/api/src/admin/admin-moderation.module.ts wires
--   rpc_admin_force_settle_booking to an admin endpoint already
--   (forceSettleBooking). These two need the equivalent wiring before an
--   admin can actually call them from the console.

BEGIN;

CREATE OR REPLACE FUNCTION public.rpc_admin_force_settle_window(p_admin uuid, p_window uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_result jsonb;
  v_status public.dm_window_status;
  v_kind public.dm_window_kind;
BEGIN
  -- Only FINANCE or SUPER_ADMIN can force settlement (money operation).
  PERFORM public.assert_admin_role('FINANCE', 'SUPER_ADMIN');

  SELECT status, kind INTO v_status, v_kind
    FROM public.conversation_windows WHERE id = p_window;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'NOT_FOUND');
  END IF;

  IF v_kind <> 'PAID' OR v_status <> 'ANSWERED' THEN
    RETURN jsonb_build_object('success', false, 'error', 'NOT_SETTLEABLE', 'status', v_status, 'kind', v_kind);
  END IF;

  -- Idempotent: a replay of an already-settled window returns
  -- already_settled:true rather than double-crediting.
  v_result := public.rpc_settle_window(p_window);

  IF NOT (v_result->>'success')::boolean THEN
    RETURN v_result;
  END IF;

  INSERT INTO public.audit_log (actor_id, actor_role, action, target_type, target_id, new_value)
  VALUES (p_admin, 'ADMIN', 'FORCE_SETTLE', 'WINDOW', p_window,
          jsonb_build_object('transaction_id', v_result->>'transaction_id'));

  RETURN v_result;
END $function$;

REVOKE ALL ON FUNCTION public.rpc_admin_force_settle_window(uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.rpc_admin_force_settle_window(uuid, uuid) TO authenticated;

CREATE OR REPLACE FUNCTION public.rpc_admin_force_settle_shoutout(p_admin uuid, p_shoutout uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_result jsonb;
BEGIN
  PERFORM public.assert_admin_role('FINANCE', 'SUPER_ADMIN');

  IF NOT EXISTS (SELECT 1 FROM public.shout_out_requests WHERE id = p_shoutout) THEN
    RETURN jsonb_build_object('success', false, 'error', 'NOT_FOUND');
  END IF;

  -- rpc_settle_shoutout already gates on status='VIDEO_DELIVERED_TO_FAN' AND
  -- fan_confirmed_at IS NOT NULL internally — no redundant pre-check here.
  v_result := public.rpc_settle_shoutout(p_shoutout);

  IF NOT (v_result->>'success')::boolean THEN
    RETURN v_result;
  END IF;

  INSERT INTO public.audit_log (actor_id, actor_role, action, target_type, target_id, new_value)
  VALUES (p_admin, 'ADMIN', 'FORCE_SETTLE', 'SHOUTOUT', p_shoutout,
          jsonb_build_object('transaction_id', v_result->>'transaction_id'));

  RETURN v_result;
END $function$;

REVOKE ALL ON FUNCTION public.rpc_admin_force_settle_shoutout(uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.rpc_admin_force_settle_shoutout(uuid, uuid) TO authenticated;

INSERT INTO _migrations (name) VALUES ('0069_force_settle_window_shoutout.sql')
  ON CONFLICT (name) DO NOTHING;

COMMIT;

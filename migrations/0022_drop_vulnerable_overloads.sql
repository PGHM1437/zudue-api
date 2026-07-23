-- 0022 · CRITICAL FIX: CREATE OR REPLACE does not remove a function when the
-- signature (arg list) changes — it creates an OVERLOAD. The old caller-priced,
-- ungated versions of the service RPCs were still live and callable alongside
-- the new server-priced, gated versions. Verified exploitable: a call was
-- booked for 1 paise via the old rpc_book_video_call(...,bigint,text) overload.
-- This migration explicitly drops every obsolete overload by full signature.

BEGIN;

DROP FUNCTION IF EXISTS rpc_book_video_call(uuid,uuid,date,call_duration_options_enum,bigint,text);
DROP FUNCTION IF EXISTS rpc_ask_question(uuid,uuid,text,bigint);
DROP FUNCTION IF EXISTS rpc_request_shoutout(uuid,uuid,text,text,bigint);

-- Guard against this class of bug recurring: fail the migration if any RPC
-- name we expect to be single-signature has more than one overload.
DO $$
DECLARE v_dupes text;
BEGIN
  SELECT string_agg(DISTINCT p.proname, ', ') INTO v_dupes
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname LIKE 'rpc_%'
  GROUP BY p.proname HAVING count(*) > 1;

  IF v_dupes IS NOT NULL THEN
    RAISE EXCEPTION 'Duplicate RPC overloads detected (fix before deploy): %', v_dupes;
  END IF;
END $$;

COMMIT;

-- 0067 · Query-pattern indexes lost in the legacy→live rewrite (H2, M1).
--
-- H2: calls has no index on fan_id or partner_id (legacy had both). Every
-- partner call-history and fan call-history query sequentially scans calls.
--
-- M1: bookings has no index on status alone. booking_fan_idx and
-- booking_partner_idx both lead with fan_id/partner_id respectively, so
-- neither helps a plain status-filtered admin query.

BEGIN;

CREATE INDEX call_fan_idx ON public.calls (fan_id);
CREATE INDEX call_partner_idx ON public.calls (partner_id);
CREATE INDEX booking_status_idx ON public.bookings (status);

INSERT INTO _migrations (name) VALUES ('0067_calls_bookings_perf_indexes.sql')
  ON CONFLICT (name) DO NOTHING;

COMMIT;

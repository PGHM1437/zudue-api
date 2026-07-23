-- 0019 · Read-model views — ONLY the two that encode real, reusable logic.
-- Removed as over-build (cleanup): per-user "dashboard" wrappers (fan bookings,
-- fan wallet, partner earnings, conversation feed) — those are simple single-table
-- reads / joins / aggregations the API does directly; they don't earn a DB object.
-- Kept: discovery (the home page) and the partner queue (intricate tier logic).

BEGIN;

-- HOME PAGE — suggested creator profiles. Featured first, then premium, then the
-- rest; with pricing rollups + primary category for browse/filter. This is what a
-- user lands on (not a "dashboard").
CREATE VIEW vw_discover_partners AS
SELECT pp.profile_id, pp.display_name, pp.bio, pp.profile_image_path,
       pp.is_premium, pp.is_featured,
       (SELECT min(price_paise) FROM partner_services s
          WHERE s.partner_id=pp.profile_id AND s.service_type='VIDEO_CALL' AND s.is_active) AS min_call_price_paise,
       (SELECT price_paise FROM partner_services s
          WHERE s.partner_id=pp.profile_id AND s.service_type='QUICK_QUESTION' AND s.is_active) AS question_price_paise,
       (SELECT price_paise FROM partner_services s
          WHERE s.partner_id=pp.profile_id AND s.service_type='SHOUT_OUT' AND s.is_active) AS shoutout_price_paise,
       (SELECT array_agg(c.slug) FROM partner_categories pc
          JOIN categories c ON c.id=pc.category_id WHERE pc.partner_id=pp.profile_id) AS categories,
       -- suggested-order rank: featured (0) > premium (1) > rest (2)
       (CASE WHEN pp.is_featured THEN 0 WHEN pp.is_premium THEN 1 ELSE 2 END) AS suggest_rank
FROM partner_profiles pp
JOIN profiles p ON p.id=pp.profile_id
WHERE pp.status='ACTIVE' AND pp.is_active AND NOT pp.vacation_mode
  AND p.account_status='ACTIVE'
ORDER BY suggest_rank, pp.display_name;

-- Partner call queue — FAITHFUL tier + internal_priority (advisory ordering).
CREATE VIEW vw_partner_call_queue AS
SELECT b.id AS booking_id, b.partner_id, b.fan_id, p.full_name AS fan_name,
       b.scheduled_date, b.selected_duration, b.fan_ready_at,
       CASE
         WHEN b.fan_ready_at IS NOT NULL THEN 0
         WHEN EXISTS(SELECT 1 FROM calls c WHERE c.booking_id=b.id
              AND c.attempt_status IN ('PARTNER_INITIATED','IN_PROGRESS') AND c.ended_at IS NULL) THEN 1
         WHEN NOT EXISTS(SELECT 1 FROM calls c WHERE c.booking_id=b.id) THEN 2
         WHEN EXISTS(SELECT 1 FROM calls c WHERE c.booking_id=b.id
              AND c.attempt_status IN ('MISSED_FAN_NO_JOIN','MISSED_FAN_DECLINED','DROPPED_TECHNICAL_ISSUE')) THEN 3
         ELSE 4
       END AS queue_priority
FROM bookings b
JOIN profiles p ON p.id=b.fan_id
WHERE b.status IN ('BOOKED','EXPIRED_FAN_NO_JOIN')
  AND b.scheduled_date >= CURRENT_DATE - 7 AND b.scheduled_date <= CURRENT_DATE
  AND NOT EXISTS(SELECT 1 FROM calls c WHERE c.booking_id=b.id AND c.attempt_status='COMPLETED_SUCCESSFUL')
ORDER BY queue_priority,
  CASE WHEN b.fan_ready_at IS NOT NULL THEN extract(epoch FROM now()-b.fan_ready_at)
       ELSE extract(epoch FROM now()-b.created_at) END;

COMMIT;

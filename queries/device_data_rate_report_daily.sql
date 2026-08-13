-- ============================================================================
-- DAY-BY-DAY device data-rate report — one row per (device, day).
-- Reads the public.device_daily_stats rollups (populated by rollup_device_daily.sql,
-- Timescale job 1002 `rollup_device_daily_job`, daily ~02:30 UTC).
-- Unlike device_data_rate_report_fast.sql (which SUMS the range into one row per
-- device), this keeps every day separate so you can see a device's sending rate
-- evolve day by day.
--
-- from_day inclusive, to_day EXCLUSIVE (whole UTC days).
-- "rate" = messages/day + avg seconds between messages, split by motion state.
-- (device_daily_stats has no payload-byte column, so this is message rate, not
--  bytes; a bytes/day rollup would need a new column summing length(attributes).)
-- ============================================================================
\timing on

WITH params AS (
    SELECT DATE '2026-07-27' AS from_day,     -- <-- set your window
           DATE '2026-08-03' AS to_day        --     (to_day exclusive)
)
SELECT
    d.uniqueid                                                              AS imei,
    s.day,
    s.msg_count                                                            AS message_count,
    ROUND((s.msg_count / 24.0)::numeric, 1)                                AS msgs_per_hour,
    ROUND((s.interval_sum           / NULLIF(s.interval_cnt, 0))::numeric, 2)           AS avg_interval_sec,
    s.moving_msgs,
    ROUND((s.moving_interval_sum    / NULLIF(s.moving_interval_cnt, 0))::numeric, 2)    AS moving_avg_interval_sec,
    s.stopped_msgs,
    ROUND((s.stopped_interval_sum   / NULLIF(s.stopped_interval_cnt, 0))::numeric, 2)   AS stopped_avg_interval_sec,
    s.idle_msgs                                                            AS idle_engine_msgs,
    ROUND((s.idle_interval_sum      / NULLIF(s.idle_interval_cnt, 0))::numeric, 2)      AS idle_engine_avg_interval_sec,
    s.undefined_msgs                                                       AS undefined_state_msgs,
    ROUND((s.undefined_interval_sum / NULLIF(s.undefined_interval_cnt, 0))::numeric, 2) AS undefined_state_avg_interval_sec,
    s.first_fixtime,
    s.last_fixtime
FROM device_daily_stats s
JOIN tc_devices d ON d.id = s.deviceid
CROSS JOIN params p
WHERE s.day >= p.from_day
  AND s.day <  p.to_day
  AND d.uniqueid ~ '^(35|86)[0-9]{13}$'   -- real IMEIs only (drop for old-fleet history)
  AND d.lastupdate IS NOT NULL            -- seen live on this platform
  -- AND d.id = ANY (ARRAY[107201,13385,10494])   -- <-- uncomment to target devices
ORDER BY d.uniqueid, s.day;               -- each device's days consecutive; swap to
                                          -- (s.day, message_count DESC) for a per-day leaderboard

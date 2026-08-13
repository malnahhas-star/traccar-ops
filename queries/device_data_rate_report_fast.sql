-- ============================================================================
-- FAST device data-rate report — reads device_daily_stats rollups.
-- Requires rollup_device_daily.sql to be installed and days rolled up.
-- from_day inclusive, to_day exclusive (whole UTC days).
-- For same-day/partial-day analysis use device_data_rate_report.sql (raw scan).
--
-- Since 2026-07-23 the rollups cover BOTH fleets (original + old-system
-- import) continuously from 2026-01-21. ~60K devices/day => multi-month
-- queries run 1-3 s instead of ms. The final filter keeps devices with
-- d.lastupdate IS NOT NULL (= seen live on this platform); DROP that
-- condition for historical/regulatory reports that must include old-fleet
-- vehicles which never reported here live but have imported history.
-- ============================================================================
\timing on

WITH params AS (
    SELECT DATE '2026-07-07' AS from_day,
           DATE '2026-07-16' AS to_day
),
summary AS (
    SELECT
        s.deviceid,
        sum(s.msg_count)                          AS message_count,
        ROUND((sum(s.interval_sum)           / NULLIF(sum(s.interval_cnt), 0))::numeric, 2)           AS avg_interval_sec,
        sum(s.moving_msgs)                        AS moving_msgs,
        ROUND((sum(s.moving_interval_sum)    / NULLIF(sum(s.moving_interval_cnt), 0))::numeric, 2)    AS moving_avg_interval_sec,
        sum(s.stopped_msgs)                       AS stopped_msgs,
        ROUND((sum(s.stopped_interval_sum)   / NULLIF(sum(s.stopped_interval_cnt), 0))::numeric, 2)   AS stopped_avg_interval_sec,
        sum(s.idle_msgs)                          AS idle_engine_msgs,
        ROUND((sum(s.idle_interval_sum)      / NULLIF(sum(s.idle_interval_cnt), 0))::numeric, 2)      AS idle_engine_avg_interval_sec,
        sum(s.undefined_msgs)                     AS undefined_state_msgs,
        ROUND((sum(s.undefined_interval_sum) / NULLIF(sum(s.undefined_interval_cnt), 0))::numeric, 2) AS undefined_state_avg_interval_sec,
        min(s.first_fixtime)                      AS first_message_time,
        max(s.last_fixtime)                       AS last_message_time
    FROM device_daily_stats s
    CROSS JOIN params prm
    WHERE s.day >= prm.from_day
      AND s.day <  prm.to_day
    GROUP BY s.deviceid
)
SELECT
    d.uniqueid AS imei,
    COALESCE(s.message_count, 0)        AS message_count,
    s.avg_interval_sec,
    COALESCE(s.moving_msgs, 0)          AS moving_msgs,
    s.moving_avg_interval_sec,
    COALESCE(s.stopped_msgs, 0)         AS stopped_msgs,
    s.stopped_avg_interval_sec,
    COALESCE(s.idle_engine_msgs, 0)     AS idle_engine_msgs,
    s.idle_engine_avg_interval_sec,
    COALESCE(s.undefined_state_msgs, 0) AS undefined_state_msgs,
    s.undefined_state_avg_interval_sec,
    s.first_message_time,
    s.last_message_time
FROM tc_devices d
LEFT JOIN summary s ON s.deviceid = d.id
WHERE d.uniqueid ~ '^(35|86)[0-9]{13}$' AND d.lastupdate IS NOT NULL
ORDER BY COALESCE(s.message_count, 0) DESC, d.uniqueid;

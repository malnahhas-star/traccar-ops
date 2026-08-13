-- ============================================================================
-- Silent / dying devices report (reads device_daily_stats rollups — instant).
-- A device is listed when it has sent nothing for `silent_after` days
-- (including devices that never sent anything in the period at all).
-- last_seen is the newest fixtime the device ever reported in the rollups.
-- ============================================================================
\timing on

WITH params AS (
    SELECT DATE '2026-07-01'    AS period_from,   -- reporting period (for msg counts)
           DATE '2026-07-17'    AS period_to,
           INTERVAL '3 days'    AS silent_after   -- quiet longer than this => silent
),
per_device AS (
    SELECT
        s.deviceid,
        max(s.last_fixtime)                                          AS last_seen,
        sum(s.msg_count) FILTER (WHERE s.day >= prm.period_from
                             AND s.day <  prm.period_to)             AS period_msgs
    FROM device_daily_stats s
    CROSS JOIN params prm
    GROUP BY s.deviceid
)
SELECT
    d.uniqueid                            AS imei,
    d.name,
    p.last_seen,
    (now()::timestamp - p.last_seen)::interval(0) AS silent_for,
    COALESCE(p.period_msgs, 0)            AS msgs_in_period,
    d.lastupdate                          AS traccar_lastupdate
FROM tc_devices d
CROSS JOIN params prm
LEFT JOIN per_device p ON p.deviceid = d.id
WHERE d.uniqueid ~ '^(35|86)[0-9]{13}$'
  AND d.lastupdate IS NOT NULL
  AND (p.last_seen IS NULL OR p.last_seen < now()::timestamp - prm.silent_after)
ORDER BY p.last_seen ASC NULLS FIRST;

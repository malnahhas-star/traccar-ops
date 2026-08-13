-- ============================================================================
-- Device data-rate report by vehicle state (fixtime-based, hypertable-optimized)
-- Edit from_time / to_time below. All message times are device fix times.
-- States: moving | stopped (engine off) | idle_engine_on | stationary_unknown
-- ============================================================================
\timing on
SET work_mem = '256MB';
-- full-day windows read entire chunks: sequential scan beats time-index random I/O
SET enable_indexscan = off;
SET enable_bitmapscan = off;

WITH params AS (
    SELECT
        TIMESTAMP '2026-07-15 00:00:00' AS from_time,
        TIMESTAMP '2026-07-16 00:00:00' AS to_time,
        0.01::float8 AS speed_threshold_knots,
        3600::float8 AS max_gap_seconds      -- gaps longer than this don't count toward averages
),
decoded AS (
    -- slim rows only: the heavy attributes column is parsed once and discarded here
    SELECT
        p.deviceid,
        p.fixtime,
        CASE
            WHEN COALESCE(
                   CASE WHEN a.motion IN ('true','1','yes','on')  THEN true
                        WHEN a.motion IN ('false','0','no','off') THEN false
                   END,
                   p.speed > prm.speed_threshold_knots) = true
                THEN 'moving'
            WHEN CASE WHEN a.ignition IN ('true','1','yes','on')  THEN true
                      WHEN a.ignition IN ('false','0','no','off') THEN false
                 END = true
                THEN 'idle_engine_on'
            WHEN CASE WHEN a.ignition IN ('true','1','yes','on')  THEN true
                      WHEN a.ignition IN ('false','0','no','off') THEN false
                 END = false
                THEN 'stopped'
            ELSE 'stationary_unknown'
        END AS vehicle_state
    FROM tc_positions p
    CROSS JOIN params prm
    -- json (not jsonb): some devices emit unicode NUL escapes that jsonb
    -- rejects. OFFSET 0 fences the cast so the ~1KB attributes string is
    -- parsed once per row, not once per reference.
    CROSS JOIN LATERAL (
        SELECT lower(j.attrs ->> 'motion')   AS motion,
               lower(j.attrs ->> 'ignition') AS ignition
        FROM (SELECT replace(p.attributes, '\u0000', '')::jsonb AS attrs OFFSET 0) j
    ) a
    WHERE p.fixtime >= prm.from_time
      AND p.fixtime <  prm.to_time
),
with_intervals AS (
    SELECT
        deviceid,
        fixtime,
        vehicle_state,
        EXTRACT(EPOCH FROM (
            fixtime - LAG(fixtime) OVER (PARTITION BY deviceid ORDER BY fixtime)
        ))::float8 AS raw_gap
    FROM decoded
),
normalized AS (
    SELECT
        w.deviceid,
        w.fixtime,
        w.vehicle_state,
        CASE
            WHEN w.raw_gap IS NULL OR w.raw_gap <= 0 OR w.raw_gap > prm.max_gap_seconds
                THEN NULL
            ELSE w.raw_gap
        END AS interval_seconds
    FROM with_intervals w
    CROSS JOIN params prm
),
summary AS (
    SELECT
        deviceid,
        COUNT(*)                                   AS message_count,
        ROUND(AVG(interval_seconds)::numeric, 2)   AS avg_interval_sec,

        COUNT(*) FILTER (WHERE vehicle_state = 'moving')          AS moving_msgs,
        ROUND((AVG(interval_seconds) FILTER (WHERE vehicle_state = 'moving'))::numeric, 2)
                                                                   AS moving_avg_interval_sec,
        COUNT(*) FILTER (WHERE vehicle_state = 'stopped')         AS stopped_msgs,
        ROUND((AVG(interval_seconds) FILTER (WHERE vehicle_state = 'stopped'))::numeric, 2)
                                                                   AS stopped_avg_interval_sec,
        COUNT(*) FILTER (WHERE vehicle_state = 'idle_engine_on')  AS idle_engine_msgs,
        ROUND((AVG(interval_seconds) FILTER (WHERE vehicle_state = 'idle_engine_on'))::numeric, 2)
                                                                   AS idle_engine_avg_interval_sec,
        COUNT(*) FILTER (WHERE vehicle_state = 'stationary_unknown') AS undefined_state_msgs,
        ROUND((AVG(interval_seconds) FILTER (WHERE vehicle_state = 'stationary_unknown'))::numeric, 2)
                                                                   AS undefined_state_avg_interval_sec,
        MIN(fixtime) AS first_message_time,
        MAX(fixtime) AS last_message_time
    FROM normalized
    GROUP BY deviceid
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

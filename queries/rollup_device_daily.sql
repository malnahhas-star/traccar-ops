-- ============================================================================
-- Daily per-device data-rate rollup: table + rollup function + nightly job.
-- Each finished day is scanned ONCE; reports then read tiny aggregated rows.
-- Averages are stored as sum+count so multi-day reports can weight correctly.
-- Days are UTC. Intervals are computed within each day (the single
-- cross-midnight interval per device per day is intentionally not counted).
-- ============================================================================

CREATE TABLE IF NOT EXISTS device_daily_stats (
    day                    date        NOT NULL,
    deviceid               integer     NOT NULL,
    msg_count              integer     NOT NULL,
    interval_sum           float8,
    interval_cnt           integer,
    moving_msgs            integer     NOT NULL,
    moving_interval_sum    float8,
    moving_interval_cnt    integer,
    stopped_msgs           integer     NOT NULL,
    stopped_interval_sum   float8,
    stopped_interval_cnt   integer,
    idle_msgs              integer     NOT NULL,
    idle_interval_sum      float8,
    idle_interval_cnt      integer,
    undefined_msgs         integer     NOT NULL,
    undefined_interval_sum float8,
    undefined_interval_cnt integer,
    first_fixtime          timestamp,
    last_fixtime           timestamp,
    computed_at            timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (day, deviceid)
);
ALTER TABLE device_daily_stats OWNER TO traccar;

CREATE OR REPLACE FUNCTION rollup_device_day(target_day date)
RETURNS integer
LANGUAGE plpgsql
SET work_mem = '256MB'
AS $$
DECLARE
    n integer;
BEGIN
    DELETE FROM device_daily_stats WHERE day = target_day;

    INSERT INTO device_daily_stats (
        day, deviceid, msg_count, interval_sum, interval_cnt,
        moving_msgs, moving_interval_sum, moving_interval_cnt,
        stopped_msgs, stopped_interval_sum, stopped_interval_cnt,
        idle_msgs, idle_interval_sum, idle_interval_cnt,
        undefined_msgs, undefined_interval_sum, undefined_interval_cnt,
        first_fixtime, last_fixtime)
    SELECT
        target_day,
        deviceid,
        count(*),
        sum(interval_seconds), count(interval_seconds),
        count(*) FILTER (WHERE vehicle_state = 'moving'),
        sum(interval_seconds) FILTER (WHERE vehicle_state = 'moving'),
        count(interval_seconds) FILTER (WHERE vehicle_state = 'moving'),
        count(*) FILTER (WHERE vehicle_state = 'stopped'),
        sum(interval_seconds) FILTER (WHERE vehicle_state = 'stopped'),
        count(interval_seconds) FILTER (WHERE vehicle_state = 'stopped'),
        count(*) FILTER (WHERE vehicle_state = 'idle_engine_on'),
        sum(interval_seconds) FILTER (WHERE vehicle_state = 'idle_engine_on'),
        count(interval_seconds) FILTER (WHERE vehicle_state = 'idle_engine_on'),
        count(*) FILTER (WHERE vehicle_state = 'stationary_unknown'),
        sum(interval_seconds) FILTER (WHERE vehicle_state = 'stationary_unknown'),
        count(interval_seconds) FILTER (WHERE vehicle_state = 'stationary_unknown'),
        min(fixtime),
        max(fixtime)
    FROM (
        SELECT
            deviceid, fixtime, vehicle_state,
            CASE
                WHEN gap IS NULL OR gap <= 0 OR gap > 3600 THEN NULL
                ELSE gap
            END AS interval_seconds
        FROM (
            SELECT
                deviceid, fixtime, vehicle_state,
                EXTRACT(EPOCH FROM (
                    fixtime - LAG(fixtime) OVER (PARTITION BY deviceid ORDER BY fixtime)
                ))::float8 AS gap
            FROM (
                SELECT
                    p.deviceid,
                    p.fixtime,
                    CASE
                        WHEN COALESCE(
                               CASE WHEN a.motion IN ('true','1','yes','on')  THEN true
                                    WHEN a.motion IN ('false','0','no','off') THEN false
                               END,
                               p.speed > 0.01) = true
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
                -- json (not jsonb): some devices emit unicode NUL escapes that jsonb
                -- rejects; json tolerates them. OFFSET 0 fences the extraction
                -- so the ~1KB string is parsed once per row.
                CROSS JOIN LATERAL (
                    SELECT lower(j.attrs ->> 'motion')   AS motion,
                           lower(j.attrs ->> 'ignition') AS ignition
                    FROM (SELECT replace(p.attributes, '\u0000', '')::jsonb AS attrs OFFSET 0) j
                ) a
                WHERE p.fixtime >= target_day::timestamp
                  AND p.fixtime <  (target_day + 1)::timestamp
            ) classified
        ) with_gaps
    ) normalized
    GROUP BY deviceid;

    GET DIAGNOSTICS n = ROW_COUNT;
    RETURN n;
END
$$;

-- Nightly job: (re)roll the last 3 days to absorb late-arriving buffered data.
CREATE OR REPLACE PROCEDURE rollup_device_daily_job(job_id int DEFAULT NULL, config jsonb DEFAULT NULL)
LANGUAGE plpgsql
AS $$
DECLARE
    d date;
BEGIN
    FOR d IN SELECT generate_series(current_date - 3, current_date - 1, interval '1 day')::date LOOP
        PERFORM rollup_device_day(d);
        COMMIT;
    END LOOP;
END
$$;

-- Register with the TimescaleDB job scheduler: daily at 02:30 UTC.
SELECT add_job('rollup_device_daily_job', schedule_interval => INTERVAL '1 day',
               initial_start => (current_date + 1)::timestamptz + INTERVAL '2 hours 30 minutes')
WHERE NOT EXISTS (
    SELECT 1 FROM timescaledb_information.jobs
    WHERE proc_name = 'rollup_device_daily_job');

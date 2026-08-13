-- Precomputed per-device current state — powers the Not Active report (and any
-- other live-snapshot consumer) WITHOUT the v_live_vehicles per-vehicle lateral
-- (~66s full scan). Bootstrapped once from v_live_vehicles, then maintained
-- incrementally from recent positions by telematics.refresh_device_state()
-- (Timescale job, every few minutes). A plain indexed table => the report is a
-- fast index range-scan on last_update at any page size.
CREATE TABLE IF NOT EXISTS telematics.device_state (
    tc_device_id       integer PRIMARY KEY,
    last_update        timestamptz,
    lat                double precision,
    lng                double precision,
    speed_kmh          numeric,
    ignition           boolean,
    satellites         integer,
    battery_external_v numeric,
    odometer_km        numeric,
    address            text,
    refreshed_at       timestamptz DEFAULT now()
);
CREATE INDEX IF NOT EXISTS device_state_last_update_idx ON telematics.device_state (last_update);
GRANT SELECT ON telematics.device_state TO telematics;

-- Incremental refresh: upsert the latest position per device seen in the last
-- 10 minutes (overlaps the ~3-min schedule so nothing is missed). Only actively
-- reporting devices are touched; quiet devices keep their last-known row, so
-- their last_update ages and they surface in the Not Active report correctly.
CREATE OR REPLACE FUNCTION telematics.refresh_device_state()
RETURNS integer
LANGUAGE plpgsql
SET search_path TO 'telematics', 'public'
AS $function$
DECLARE n int;
BEGIN
    INSERT INTO telematics.device_state AS ds
        (tc_device_id, last_update, lat, lng, speed_kmh, ignition, satellites,
         battery_external_v, odometer_km, address, refreshed_at)
    SELECT DISTINCT ON (p.deviceid)
           p.deviceid,
           (p.fixtime AT TIME ZONE 'UTC'),
           p.latitude, p.longitude,
           round((p.speed * 1.852)::numeric, 1),
           CASE WHEN lower(a.attrs ->> 'ignition') IN ('true','1','t')  THEN true
                WHEN lower(a.attrs ->> 'ignition') IN ('false','0','f') THEN false
                ELSE NULL END,
           nullif(a.attrs ->> 'sat', '')::int,
           nullif(a.attrs ->> 'power', '')::numeric,
           (nullif(a.attrs ->> 'odometer', '')::numeric) / 1000,
           p.address, now()
    FROM tc_positions p
    CROSS JOIN LATERAL (
        SELECT replace(p.attributes::text, '\u0000', '')::jsonb AS attrs OFFSET 0) a
    WHERE p.fixtime > (now() AT TIME ZONE 'UTC') - interval '10 minutes'
    ORDER BY p.deviceid, p.fixtime DESC
    ON CONFLICT (tc_device_id) DO UPDATE SET
        last_update = EXCLUDED.last_update, lat = EXCLUDED.lat, lng = EXCLUDED.lng,
        speed_kmh = EXCLUDED.speed_kmh, ignition = EXCLUDED.ignition,
        satellites = EXCLUDED.satellites, battery_external_v = EXCLUDED.battery_external_v,
        odometer_km = EXCLUDED.odometer_km, address = EXCLUDED.address, refreshed_at = now()
    WHERE EXCLUDED.last_update >= ds.last_update;
    GET DIAGNOSTICS n = ROW_COUNT;
    RETURN n;
END
$function$;

-- Timescale job wrapper (add_job needs a (job_id, config) proc signature).
CREATE OR REPLACE PROCEDURE telematics.refresh_device_state_job(job_id int, config jsonb)
LANGUAGE plpgsql AS $proc$
BEGIN PERFORM telematics.refresh_device_state(); END $proc$;

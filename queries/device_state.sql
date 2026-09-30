-- ============================================================================
-- telematics.device_state — CANONICAL SINGLE SOURCE OF TRUTH.
-- ============================================================================
-- ⚠️ REGRESSION GUARD (2026-09-30): refresh_device_state() MUST populate ALL of
-- these columns. Dropping any silently freezes it (a past redeploy dropped
-- motion/moved_recently → ~1,700 vehicles stuck 'towing'). If you CREATE OR
-- REPLACE this function, it MUST still set, in BOTH the INSERT column list and the
-- ON CONFLICT DO UPDATE:
--     speed_kmh, ignition, satellites, battery_external_v, battery_internal_v,
--     odometer_km, address, attributes, motion, moved_recently
-- This file is mirrored at TraccarOps/queries/device_state.sql — KEEP THE TWO
-- IDENTICAL. The verification query at the very bottom must return healthy=t.
-- ============================================================================
-- Precomputed per-device current state — powers the Not Active / Object Status
-- reports, Live Weight, and the live map WITHOUT a per-vehicle lateral scan.
-- Maintained incrementally by telematics.refresh_device_state() (Timescale job,
-- every ~3 min).
CREATE TABLE IF NOT EXISTS telematics.device_state (
    tc_device_id       integer PRIMARY KEY,
    last_update        timestamptz,
    lat                double precision,
    lng                double precision,
    speed_kmh          numeric,
    ignition           boolean,
    satellites         integer,
    battery_external_v numeric,
    battery_internal_v numeric,      -- device's own internal battery (attrs 'battery')
    odometer_km        numeric,
    address            text,
    attributes         jsonb,        -- full latest-packet attributes (Live Weight etc.)
    -- motion = device movement flag on the latest packet; moved_recently = coords
    -- displaced >50m in the last 2 min. Together they drive the "towing" variant-B
    -- rule so a momentary 0-speed sample during a tow doesn't flap towing->stop.
    motion             boolean,
    moved_recently     boolean,
    refreshed_at       timestamptz DEFAULT now()
);
-- Idempotent adds so the canonical schema is reached from any older table version.
ALTER TABLE telematics.device_state ADD COLUMN IF NOT EXISTS battery_internal_v numeric;
ALTER TABLE telematics.device_state ADD COLUMN IF NOT EXISTS attributes jsonb;
ALTER TABLE telematics.device_state ADD COLUMN IF NOT EXISTS motion boolean;
ALTER TABLE telematics.device_state ADD COLUMN IF NOT EXISTS moved_recently boolean;
CREATE INDEX IF NOT EXISTS device_state_last_update_idx ON telematics.device_state (last_update);
GRANT SELECT ON telematics.device_state TO telematics;

-- Incremental refresh: upsert the latest position per device seen in the last
-- 10 minutes (overlaps the ~3-min schedule so nothing is missed). Quiet devices
-- keep their last-known row so their last_update ages into the Not Active report.
CREATE OR REPLACE FUNCTION telematics.refresh_device_state()
RETURNS integer
LANGUAGE plpgsql
SET search_path TO 'telematics', 'public'
AS $function$
DECLARE n int;
BEGIN
    INSERT INTO telematics.device_state AS ds
        (tc_device_id, last_update, lat, lng, speed_kmh, ignition, satellites,
         battery_external_v, battery_internal_v, odometer_km, address, attributes,
         motion, moved_recently, refreshed_at)
    WITH latest AS (
        SELECT DISTINCT ON (p.deviceid)
               p.deviceid, p.fixtime, p.latitude, p.longitude, p.speed, p.address,
               replace(p.attributes::text, chr(92) || 'u0000', '')::jsonb AS attrs
        FROM tc_positions p
        WHERE p.fixtime > (now() AT TIME ZONE 'UTC') - interval '10 minutes'
        ORDER BY p.deviceid, p.fixtime DESC
    ),
    moved AS (
        -- earliest fix within the last 2 min per device, to measure displacement vs
        -- the latest fix (variant B: "coordinates actually moved in last 2 min").
        SELECT DISTINCT ON (p.deviceid) p.deviceid, p.latitude AS lat0, p.longitude AS lng0
        FROM tc_positions p
        WHERE p.fixtime > (now() AT TIME ZONE 'UTC') - interval '2 minutes'
        ORDER BY p.deviceid, p.fixtime ASC
    )
    SELECT l.deviceid,
           (l.fixtime AT TIME ZONE 'UTC'),
           l.latitude, l.longitude,
           round((l.speed * 1.852)::numeric, 1),
           CASE WHEN lower(l.attrs ->> 'ignition') IN ('true','1','t')  THEN true
                WHEN lower(l.attrs ->> 'ignition') IN ('false','0','f') THEN false
                ELSE NULL END,
           nullif(l.attrs ->> 'sat', '')::int,
           nullif(l.attrs ->> 'power', '')::numeric,
           nullif(l.attrs ->> 'battery', '')::numeric,
           (nullif(l.attrs ->> 'odometer', '')::numeric) / 1000,
           l.address,
           l.attrs,
           CASE WHEN lower(l.attrs ->> 'motion') IN ('true','1','t')  THEN true
                WHEN lower(l.attrs ->> 'motion') IN ('false','0','f') THEN false
                ELSE NULL END,
           (m.deviceid IS NOT NULL AND
            2*6371000*asin(least(1, sqrt(
                power(sin(radians(l.latitude - m.lat0)/2), 2)
              + cos(radians(m.lat0))*cos(radians(l.latitude))
                * power(sin(radians(l.longitude - m.lng0)/2), 2)))) > 50),
           now()
    FROM latest l
    LEFT JOIN moved m ON m.deviceid = l.deviceid
    ON CONFLICT (tc_device_id) DO UPDATE SET
        last_update = EXCLUDED.last_update, lat = EXCLUDED.lat, lng = EXCLUDED.lng,
        speed_kmh = EXCLUDED.speed_kmh, ignition = EXCLUDED.ignition,
        satellites = EXCLUDED.satellites, battery_external_v = EXCLUDED.battery_external_v,
        battery_internal_v = EXCLUDED.battery_internal_v,
        odometer_km = EXCLUDED.odometer_km, address = EXCLUDED.address,
        attributes = EXCLUDED.attributes,
        motion = EXCLUDED.motion, moved_recently = EXCLUDED.moved_recently, refreshed_at = now()
    WHERE EXCLUDED.last_update >= ds.last_update;
    GET DIAGNOSTICS n = ROW_COUNT;
    RETURN n;
END
$function$;

-- Timescale job wrapper (add_job needs a (job_id, config) proc signature).
CREATE OR REPLACE PROCEDURE telematics.refresh_device_state_job(job_id int, config jsonb)
LANGUAGE plpgsql AS $proc$
BEGIN PERFORM telematics.refresh_device_state(); END $proc$;

-- REGRESSION GUARD (run after any deploy): a fresh refresh must populate motion
-- AND moved_recently AND battery_internal_v for recently-reporting devices. If any
-- is all-NULL among fresh rows, the function dropped that column → healthy=f.
SELECT telematics.refresh_device_state();
SELECT bool_and(cnt > 0) AS healthy
FROM (
  SELECT count(motion) AS cnt FROM telematics.device_state WHERE last_update > now() - interval '15 min'
  UNION ALL SELECT count(moved_recently) FROM telematics.device_state WHERE last_update > now() - interval '15 min'
  UNION ALL SELECT count(battery_internal_v) FROM telematics.device_state WHERE last_update > now() - interval '15 min'
) q;

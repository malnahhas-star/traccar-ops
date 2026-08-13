#!/bin/bash
exec 9>/run/refresh-live-positions.lock
flock -n 9 || exit 0
set -e
CUT=$(date -u -d '90 minutes ago' '+%Y-%m-%d %H:%M:%S')
sudo -u postgres psql -d traccar -q -v ON_ERROR_STOP=1 <<SQL
SET statement_timeout='50s';
-- PASS A (baseline): last-known position of EVERY vehicle from device_state (fast,
-- one indexed row per device). Full 5-status incl. 'inactive' (>24h). No heading.
-- This is why offline/inactive vehicles now appear on the map at their last spot.
INSERT INTO telematics.live_positions (vehicle_id, company_id, lat, lng, status, speed, heading, fixtime, updated_at)
SELECT v.id, v.company_id, ds.lat, ds.lng,
       CASE WHEN ds.last_update < now()::timestamp - interval '24 hours' THEN 'inactive'
            WHEN COALESCE(ds.speed_kmh,0) > 0 AND ds.speed_kmh <= 250 THEN 'moving'
            WHEN ds.ignition='true' THEN 'idle' ELSE 'stop' END,
       CASE WHEN ds.last_update >= now()::timestamp - interval '24 hours' AND COALESCE(ds.speed_kmh,0) > 0 AND ds.speed_kmh <= 250 THEN ds.speed_kmh ELSE 0 END, NULL, ds.last_update, now()
FROM telematics.vehicles v
JOIN telematics.device_state ds ON ds.tc_device_id = v.tc_device_id
WHERE v.deleted_at IS NULL AND ds.lat IS NOT NULL AND ds.lng IS NOT NULL
  AND ds.lat BETWEEN -90 AND 90 AND ds.lng BETWEEN -180 AND 180
ON CONFLICT (vehicle_id) DO UPDATE SET lat=EXCLUDED.lat,lng=EXCLUDED.lng,status=EXCLUDED.status,
  speed=EXCLUDED.speed,heading=EXCLUDED.heading,fixtime=EXCLUDED.fixtime,updated_at=now(),company_id=EXCLUDED.company_id;
-- PASS B (refine): recently-active vehicles (last 90 min) get freshest position +
-- HEADING from tc_positions, overwriting the device_state baseline. moving/idle/stop.
INSERT INTO telematics.live_positions (vehicle_id, company_id, lat, lng, status, speed, heading, fixtime, updated_at)
SELECT v.id, v.company_id, p.latitude, p.longitude,
       CASE WHEN round((p.speed*1.852)::numeric,1) > 0 AND round((p.speed*1.852)::numeric,1) <= 250 THEN 'moving'
            WHEN (p.attrs->>'ignition')='true' THEN 'idle' ELSE 'stop' END,
       CASE WHEN round((p.speed*1.852)::numeric,1) > 0 AND round((p.speed*1.852)::numeric,1) <= 250 THEN round((p.speed*1.852)::numeric,1) ELSE 0 END,
       CASE WHEN p.course >= 0 AND p.course <= 360 THEN round(p.course)::int ELSE NULL END,
       p.fixtime, now()
FROM telematics.vehicles v
JOIN tc_devices d ON d.uniqueid::text=v.imei
JOIN LATERAL (SELECT tp.fixtime,tp.latitude,tp.longitude,tp.speed,tp.course,
              replace(tp.attributes::text, chr(92)||'u0000','')::jsonb AS attrs
              FROM tc_positions tp WHERE tp.deviceid=d.id AND tp.fixtime > TIMESTAMP '$CUT'
              ORDER BY tp.fixtime DESC LIMIT 1) p ON true
WHERE v.deleted_at IS NULL AND p.latitude BETWEEN -90 AND 90 AND p.longitude BETWEEN -180 AND 180
ON CONFLICT (vehicle_id) DO UPDATE SET lat=EXCLUDED.lat,lng=EXCLUDED.lng,status=EXCLUDED.status,
  speed=EXCLUDED.speed,heading=EXCLUDED.heading,fixtime=EXCLUDED.fixtime,updated_at=now(),company_id=EXCLUDED.company_id;
DELETE FROM telematics.live_positions WHERE updated_at < now() - interval '15 minutes';
SQL

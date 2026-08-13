-- ============================================================================
-- Trip builder for schema __SCHEMA__ : segments tc_positions into trips.
-- A trip = a run of "active" positions (motion=true, or speed>3km/h when motion
-- is absent) bounded by rests longer than p_stop_gap seconds (or data gaps).
-- Distance via haversine between consecutive fixes. Idempotent per vehicle+window.
-- ============================================================================

CREATE OR REPLACE FUNCTION __SCHEMA__.build_trips_for_device(
    p_vehicle_id int, p_deviceid int, p_from timestamp, p_to timestamp,
    p_stop_gap int DEFAULT 300, p_min_km numeric DEFAULT 0.3)
RETURNS int
LANGUAGE plpgsql
SET search_path = __SCHEMA__, public
SET work_mem = '128MB'
AS $$
DECLARE n int;
BEGIN
    DELETE FROM trips
     WHERE vehicle_id = p_vehicle_id
       AND start_time >= p_from AND start_time < p_to;

    INSERT INTO trips (vehicle_id, driver_id, start_time, end_time,
        start_lat, start_lng, end_lat, end_lng,
        distance_km, max_speed, average_speed, moving_sec, idle_sec, stop_sec,
        trip_status)
    WITH pts AS (
        SELECT p.fixtime, p.latitude AS lat, p.longitude AS lng,
               p.speed * 1.852 AS kmh,
               CASE WHEN lower(j.attrs ->> 'motion') IN ('true','1')  THEN true
                    WHEN lower(j.attrs ->> 'motion') IN ('false','0') THEN false
                    ELSE p.speed * 1.852 > 3 END AS active
        FROM tc_positions p
        CROSS JOIN LATERAL (
            SELECT replace(p.attributes, E'\\u0000', '')::jsonb AS attrs OFFSET 0) j
        WHERE p.deviceid = p_deviceid
          AND p.fixtime >= p_from AND p.fixtime < p_to
    ),
    act AS (   -- active fixes only, with the previous active fix
        SELECT fixtime, lat, lng, kmh,
               LAG(fixtime) OVER w AS prev_ft,
               LAG(lat)     OVER w AS prev_lat,
               LAG(lng)     OVER w AS prev_lng
        FROM pts WHERE active
        WINDOW w AS (ORDER BY fixtime)
    ),
    seg AS (
        SELECT *,
            CASE WHEN prev_ft IS NULL
                      OR EXTRACT(EPOCH FROM (fixtime - prev_ft)) > p_stop_gap
                 THEN 1 ELSE 0 END AS is_break
        FROM act
    ),
    grp AS (
        SELECT *,
            SUM(is_break) OVER (ORDER BY fixtime) AS trip_no,
            CASE WHEN is_break = 1 THEN 0
                 ELSE 2 * 6371 * asin(least(1, sqrt(
                        power(sin(radians(lat - prev_lat) / 2), 2)
                      + cos(radians(prev_lat)) * cos(radians(lat))
                      * power(sin(radians(lng - prev_lng) / 2), 2)))) END AS seg_km,
            CASE WHEN is_break = 1 THEN 0
                 ELSE EXTRACT(EPOCH FROM (fixtime - prev_ft)) END AS seg_sec
        FROM seg
    )
    SELECT p_vehicle_id,
           (SELECT driver_id FROM vehicles WHERE id = p_vehicle_id),
           min(fixtime), max(fixtime),
           (array_agg(lat ORDER BY fixtime))[1],
           (array_agg(lng ORDER BY fixtime))[1],
           (array_agg(lat ORDER BY fixtime DESC))[1],
           (array_agg(lng ORDER BY fixtime DESC))[1],
           round(sum(seg_km)::numeric, 2),
           round(max(kmh)::numeric, 1),
           round((sum(seg_km) / NULLIF(sum(seg_sec) FILTER (WHERE kmh > 3), 0) * 3600)::numeric, 1),
           COALESCE(sum(seg_sec) FILTER (WHERE kmh > 3), 0)::int,   -- moving_sec
           COALESCE(sum(seg_sec) FILTER (WHERE kmh <= 3), 0)::int,  -- idle_sec (stopped w/ engine, within trip)
           0,                                                        -- stop_sec (parking is between trips; see stop report)
           'Classified'
    FROM grp
    GROUP BY trip_no
    HAVING sum(seg_km) >= p_min_km OR max(kmh) > 5;

    GET DIAGNOSTICS n = ROW_COUNT;
    RETURN n;
END $$;

ALTER FUNCTION __SCHEMA__.build_trips_for_device(int,int,timestamp,timestamp,int,numeric)
    OWNER TO __SCHEMA__;

-- Build trips for every vehicle that has fixes in [p_from, p_to). Returns trips made.
CREATE OR REPLACE FUNCTION __SCHEMA__.build_trips_window(p_from timestamp, p_to timestamp)
RETURNS int
LANGUAGE plpgsql
SET search_path = __SCHEMA__, public
AS $$
DECLARE r record; total int := 0; made int;
BEGIN
    FOR r IN
        SELECT v.id AS vehicle_id, v.tc_device_id
        FROM vehicles v
        WHERE v.tc_device_id IS NOT NULL AND v.deleted_at IS NULL
          AND EXISTS (SELECT 1 FROM tc_positions p
                      WHERE p.deviceid = v.tc_device_id
                        AND p.fixtime >= p_from AND p.fixtime < p_to)
    LOOP
        made := build_trips_for_device(r.vehicle_id, r.tc_device_id, p_from, p_to);
        total := total + made;
    END LOOP;
    RETURN total;
END $$;

ALTER FUNCTION __SCHEMA__.build_trips_window(timestamp,timestamp)
    OWNER TO __SCHEMA__;

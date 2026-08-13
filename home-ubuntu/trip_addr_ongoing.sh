#!/bin/bash
Q(){ sudo -u postgres psql traccar -X -tA -c "SET statement_timeout='120s'; SET synchronous_commit=off; $1"; }
Q "UPDATE telematics.trips t SET start_location=g.address FROM telematics.geocode_cache g WHERE g.lat_cell=round(t.start_lat::numeric,3) AND g.lng_cell=round(t.start_lng::numeric,3) AND t.start_time>=now()-interval '3 days' AND (t.start_location IS NULL OR t.start_location='') AND t.start_lat IS NOT NULL;" >/dev/null 2>&1
Q "UPDATE telematics.trips t SET end_location=g.address FROM telematics.geocode_cache g WHERE g.lat_cell=round(t.end_lat::numeric,3) AND g.lng_cell=round(t.end_lng::numeric,3) AND t.start_time>=now()-interval '3 days' AND (t.end_location IS NULL OR t.end_location='') AND t.end_lat IS NOT NULL;" >/dev/null 2>&1

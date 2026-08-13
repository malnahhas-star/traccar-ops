#!/bin/bash
LOG=/home/ubuntu/trip_addr_fill.log
Q(){ sudo -u postgres psql traccar -X -tA -c "$1"; }
echo "$(date) === trip address backfill start ===" >>"$LOG"
DAYS=$(Q "SELECT distinct start_time::date FROM telematics.trips WHERE (start_location IS NULL OR start_location='') AND start_lat IS NOT NULL ORDER BY 1 DESC;")
for d in $DAYS; do
  Q "SET statement_timeout='300s'; SET synchronous_commit=off; UPDATE telematics.trips t SET start_location=g.address FROM telematics.geocode_cache g WHERE g.lat_cell=round(t.start_lat::numeric,3) AND g.lng_cell=round(t.start_lng::numeric,3) AND t.start_time>='$d' AND t.start_time<('$d'::date+1) AND (t.start_location IS NULL OR t.start_location='') AND t.start_lat IS NOT NULL;" >>"$LOG" 2>&1
  Q "SET statement_timeout='300s'; SET synchronous_commit=off; UPDATE telematics.trips t SET end_location=g.address FROM telematics.geocode_cache g WHERE g.lat_cell=round(t.end_lat::numeric,3) AND g.lng_cell=round(t.end_lng::numeric,3) AND t.start_time>='$d' AND t.start_time<('$d'::date+1) AND (t.end_location IS NULL OR t.end_location='') AND t.end_lat IS NOT NULL;" >>"$LOG" 2>&1
  echo "$(date) done $d" >>"$LOG"
done
echo "$(date) === backfill DONE ===" >>"$LOG"

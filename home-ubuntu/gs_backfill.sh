#!/bin/bash
export TZ=UTC
LOG=/home/ubuntu/gs_backfill.log
Q(){ sudo -u postgres psql traccar -X -tA -F'~' -c "$1"; }
U(){ sudo -u postgres psql traccar -X -tA -c "SET timezone='UTC'; SET statement_timeout='600s'; SET work_mem='1GB'; SET synchronous_commit=off; SET max_parallel_workers_per_gather=4; $1"; }
echo "$(date) === backfill start (hourly-sliced) ===" >>"$LOG"
JOBS=$(Q "SELECT job_id FROM timescaledb_information.jobs WHERE hypertable_name='tc_positions';")
for j in $JOBS; do Q "SELECT alter_job($j, scheduled=>false);" >/dev/null; done
echo "$(date) paused jobs: $JOBS" >>"$LOG"
while true; do
  row=$(Q "SELECT chunk_name, to_char(range_start,'YYYY-MM-DD HH24:MI:SS'), to_char(range_end,'YYYY-MM-DD HH24:MI:SS'), is_compressed FROM telematics.gs_backfill WHERE status='pending' ORDER BY range_start DESC LIMIT 1;")
  [ -z "$row" ] && { echo "$(date) ALL DONE" >>"$LOG"; break; }
  cn=$(echo "$row"|cut -d'~' -f1); cs=$(echo "$row"|cut -d'~' -f2); ce=$(echo "$row"|cut -d'~' -f3); cp=$(echo "$row"|cut -d'~' -f4)
  ep0=$(date -d "$cs UTC" +%s); ep1=$(date -d "$ce UTC" +%s)
  stot=$(( (ep1-ep0+3599)/3600 )); [ $stot -lt 1 ] && stot=1
  Q "UPDATE telematics.gs_backfill SET status='running',started_at=now(),slices_total=$stot,slices_done=0 WHERE chunk_name='$cn';" >/dev/null
  t0=$(date +%s); err=0
  [ "$cp" = "t" ] && { Q "SELECT decompress_chunk('_timescaledb_internal.$cn', if_compressed=>true);" >>"$LOG" 2>&1 || err=1; }
  h=$ep0; sd=0
  while [ $h -lt $ep1 ]; do
    hs=$(date -d "@$h" +'%Y-%m-%d %H:%M:%S'); he=$(date -d "@$((h+3600))" +'%Y-%m-%d %H:%M:%S')
    U "WITH q AS (SELECT p.id,p.fixtime,p.latitude la,p.longitude lo, lag(p.latitude) OVER w pla, lag(p.longitude) OVER w plo, lag(p.fixtime) OVER w pf FROM tc_positions p WHERE p.fixtime>='$hs' AND p.fixtime<'$he' AND p.deviceid IN (SELECT deviceid FROM telematics.uffizio_dev_ids) WINDOW w AS (PARTITION BY p.deviceid ORDER BY p.fixtime)), c AS (SELECT id,fixtime, CASE WHEN pf IS NOT NULL AND EXTRACT(epoch FROM fixtime-pf) BETWEEN 0.5 AND 3600 THEN round(((2*6371000*asin(sqrt(power(sin(radians(la-pla)/2),2)+cos(radians(pla))*cos(radians(la))*power(sin(radians(lo-plo)/2),2)))*3.6/EXTRACT(epoch FROM fixtime-pf))/1.852)::numeric,2) ELSE 0 END gs FROM q) UPDATE tc_positions t SET speed=c.gs FROM c WHERE t.id=c.id AND t.fixtime=c.fixtime AND t.fixtime>='$hs' AND t.fixtime<'$he' AND t.speed IS DISTINCT FROM c.gs;" >>"$LOG" 2>&1 || err=1
    sd=$((sd+1)); Q "UPDATE telematics.gs_backfill SET slices_done=$sd WHERE chunk_name='$cn';" >/dev/null
    h=$((h+3600))
  done
  [ "$cp" = "t" ] && { Q "SELECT compress_chunk('_timescaledb_internal.$cn', if_not_compressed=>true);" >>"$LOG" 2>&1 || err=1; }
  secs=$(( $(date +%s)-t0 )); stt=done; [ $err = 1 ] && stt=error
  Q "UPDATE telematics.gs_backfill SET status='$stt',secs=$secs,done_at=now() WHERE chunk_name='$cn';" >/dev/null
  echo "$(date) $stt $cn ${secs}s comp=$cp slices=$sd" >>"$LOG"
done
for j in $JOBS; do Q "SELECT alter_job($j, scheduled=>true);" >/dev/null; done
echo "$(date) === FINISHED ===" >>"$LOG"

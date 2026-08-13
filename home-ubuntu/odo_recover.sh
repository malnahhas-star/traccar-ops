#!/bin/bash
export TZ=UTC
LOG=/home/ubuntu/odo_recover.log
BANGO=/home/ubuntu/uffizio_bridge/bango_sh.sh
set -a; source /home/ubuntu/uffizio_bridge/uffizio.env; set +a
Q(){ sudo -u postgres psql traccar -X -tA -c "$1"; }
U(){ sudo -u postgres psql traccar -X -tA -c "SET timezone='UTC'; SET statement_timeout='600s'; SET work_mem='1GB'; SET synchronous_commit=off; $1"; }
# day list: "table_suffix iso_date"
DAYS=("05_08_2026 2026-08-05" "04_08_2026 2026-08-04" "03_08_2026 2026-08-03" "02_08_2026 2026-08-02" "01_08_2026 2026-08-01" "31_07_2026 2026-07-31" "30_07_2026 2026-07-30")
echo "$(date) === odo recover start ===" >>"$LOG"
Q "CREATE TABLE IF NOT EXISTS telematics.odo_recover(day text PRIMARY KEY, iso date, status text DEFAULT 'pending', export_rows bigint, slices_done int, secs int, done_at timestamptz);"
for pair in "${DAYS[@]}"; do set -- $pair; Q "INSERT INTO telematics.odo_recover(day,iso) VALUES('$1','$2') ON CONFLICT(day) DO NOTHING;" >/dev/null; done
for pair in "${DAYS[@]}"; do
  set -- $pair; T=$1; ISO=$2
  st=$(Q "SELECT status FROM telematics.odo_recover WHERE day='$T';")
  [ "$st" = "done" ] && continue
  Q "UPDATE telematics.odo_recover SET status='running', slices_done=0 WHERE day='$T';" >/dev/null
  t0=$(date +%s)
  # 1. export on bango (streaming), wait up to 40 min
  SQL="SELECT imei_no,odometer,data_actual_time FROM device_update_$T WHERE odometer>0"
  $BANGO "rm -f /tmp/odo_$T.tsv /tmp/odo_$T.done; nohup bash -c \"mysql --quick --default-character-set=utf8mb4 -h 80.225.74.41 -u com_live -p'${UFFIZIO_MYSQL_PW}' -D gps -N -e \\\"$SQL\\\" > /tmp/odo_$T.tsv 2>/tmp/odo_$T.err; touch /tmp/odo_$T.done\" >/dev/null 2>&1 </dev/null & echo ok" >>"$LOG" 2>&1
  for i in $(seq 1 240); do [ "$($BANGO "test -f /tmp/odo_$T.done && echo y || echo n")" = "y" ] && break; sleep 10; done
  # 2. pull
  scp -i /home/ubuntu/.keys/bango.key -o StrictHostKeyChecking=no -o "ProxyCommand=ssh -i /home/ubuntu/.keys/f01.key -o StrictHostKeyChecking=no -W %h:%p ubuntu@20.0.4.234" ubuntu@158.101.239.53:/tmp/odo_$T.tsv /tmp/odo_$T.tsv >>"$LOG" 2>&1
  rex=$(wc -l < /tmp/odo_$T.tsv 2>/dev/null || echo 0)
  # 3. stage
  Q "DROP TABLE IF EXISTS telematics.odo_stage; CREATE UNLOGGED TABLE telematics.odo_stage(imei text, odometer bigint, ts timestamp);" >/dev/null
  sudo -u postgres psql traccar -X -tA -c "\copy telematics.odo_stage(imei,odometer,ts) FROM '/tmp/odo_$T.tsv'" >>"$LOG" 2>&1
  Q "CREATE INDEX ON telematics.odo_stage(imei,ts); ANALYZE telematics.odo_stage;" >/dev/null
  # 4. hourly-sliced UPDATE via 60s bucket join
  sd=0
  for h in $(seq 0 23); do
    HS=$(date -u -d "$ISO $h:00:00" +'%Y-%m-%d %H:%M:%S'); HE=$(date -u -d "$ISO $h:00:00 +1 hour" +'%Y-%m-%d %H:%M:%S')
    U "UPDATE tc_positions t SET attributes=jsonb_set(jsonb_set(replace(t.attributes::text,chr(92)||'u0000','')::jsonb,'{odometer}',to_jsonb(u.odo)),'{totalDistance}',to_jsonb(u.odo))
       FROM (SELECT d.id deviceid, time_bucket('60 seconds',s.ts) bkt, max(s.odometer) odo FROM telematics.odo_stage s JOIN tc_devices d ON d.uniqueid=s.imei WHERE s.ts>='$HS' AND s.ts<'$HE' GROUP BY 1,2) u
       WHERE t.deviceid=u.deviceid AND time_bucket('60 seconds',t.fixtime)=u.bkt AND t.fixtime>='$HS' AND t.fixtime<'$HE';" >>"$LOG" 2>&1
    sd=$((sd+1)); Q "UPDATE telematics.odo_recover SET slices_done=$sd WHERE day='$T';" >/dev/null
  done
  secs=$(( $(date +%s)-t0 ))
  Q "UPDATE telematics.odo_recover SET status='done', export_rows=$rex, secs=$secs, done_at=now() WHERE day='$T';" >/dev/null
  echo "$(date) done $T rows=$rex ${secs}s" >>"$LOG"
  rm -f /tmp/odo_$T.tsv; $BANGO "rm -f /tmp/odo_$T.tsv /tmp/odo_$T.err /tmp/odo_$T.done" >/dev/null 2>&1
done
Q "DROP TABLE IF EXISTS telematics.odo_stage;" >/dev/null
echo "$(date) === odo recover FINISHED ===" >>"$LOG"

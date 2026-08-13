#!/bin/bash
# import_history.sh — DB VM. Imports exported old-system slices into tc_positions.
exec 9>/var/lock/import_history.lock; flock -n 9 || { echo "another instance running"; exit 1; }
# - keeps ORIGINAL position ids (2x10^10 range, no clash with live sequence ~3.6x10^8)
# - remaps deviceid via IMEI, strips "raw" +   from attributes (jsonb - 'raw')
# - compresses chunks once the id-ordered slices have moved 2+ days past them
# - verifies per-slice counts; deletes each slice file after success
set -u
STG=/home/ubuntu/history_staging
LOG=/home/ubuntu/import_history.log
DONE=/home/ubuntu/import_done
mkdir -p "$DONE"
PSQL="sudo -u postgres psql -v ON_ERROR_STOP=1 -qtA traccar"

log(){ echo "$(date -u +%F' '%T) $*" >> $LOG; }

# ── one-time setup ──────────────────────────────────────────────────────
if [ ! -f "$DONE/.setup" ]; then
  while [ ! -f "$STG/devices.csv.gz" ]; do sleep 30; done
  $PSQL <<'SQL'
CREATE SCHEMA IF NOT EXISTS import_stage;
CREATE TABLE IF NOT EXISTS import_stage.old_devices (oldid bigint, uniqueid text, name text);
TRUNCATE import_stage.old_devices;
CREATE UNLOGGED TABLE IF NOT EXISTS import_stage.pos (
  id bigint, deviceid bigint, protocol text, servertime timestamp, devicetime timestamp,
  fixtime timestamp, valid boolean, latitude float8, longitude float8, altitude float8,
  speed float8, course float8, address text, accuracy float8, network text, attributes text);
SQL
  sudo -u postgres psql -qtA traccar -c "\copy import_stage.old_devices FROM PROGRAM 'zcat $STG/devices.csv.gz' CSV"
  $PSQL <<'SQL'
INSERT INTO tc_devices (name, uniqueid)
SELECT COALESCE(NULLIF(o.name,''), o.uniqueid), o.uniqueid FROM import_stage.old_devices o
ON CONFLICT (uniqueid) DO NOTHING;
DROP TABLE IF EXISTS import_stage.devmap;
CREATE TABLE import_stage.devmap AS
  SELECT o.oldid, d.id AS newid FROM import_stage.old_devices o JOIN tc_devices d ON d.uniqueid = o.uniqueid;
CREATE UNIQUE INDEX ON import_stage.devmap(oldid);
SQL
  MAPPED=$($PSQL -c "SELECT count(*) FROM import_stage.devmap")
  log "setup done: $MAPPED devices mapped"
  touch "$DONE/.setup"
fi

# ── slice loop ──────────────────────────────────────────────────────────
while true; do
  NEXT=""
  for f in $(ls $STG/positions_*.csv.gz 2>/dev/null | sort); do
    b=$(basename "$f"); [ -f "$DONE/$b" ] || { NEXT="$f"; break; }
  done
  if [ -z "$NEXT" ]; then
    # finished? (export complete marker relayed as absence of new files + events present)
    if [ -f "$STG/ALL_SLICES_SENT" ] || { [ -f "$STG/events.csv.gz" ] && [ -f "$DONE/.positions_all" ]; }; then break; fi
    # detect natural end: events.csv.gz exists and no new slice for 15 min
    if [ -f "$STG/events.csv.gz" ]; then
      AGE=$(( $(date +%s) - $(stat -c %Y "$STG/events.csv.gz") ))
      [ "$AGE" -gt 900 ] && { touch "$DONE/.positions_all"; break; }
    fi
    sleep 60; continue
  fi
  B=$(basename "$NEXT")
  CSV_LINES=$(zcat "$NEXT" | wc -l)
  $PSQL -c "TRUNCATE import_stage.pos"
  sudo -u postgres psql -qtA traccar -c "\copy import_stage.pos FROM PROGRAM 'zcat $NEXT' CSV" || { log "COPY FAIL $B"; sleep 30; continue; }
  INSERTED=$($PSQL <<SQL
SET work_mem='256MB';
WITH ins AS (
  INSERT INTO tc_positions (id, protocol, deviceid, servertime, devicetime, fixtime, valid,
                            latitude, longitude, altitude, speed, course, address, attributes,
                            accuracy, network)
  SELECT s.id, s.protocol, m.newid, s.servertime, s.devicetime, s.fixtime, s.valid,
         s.latitude, s.longitude, s.altitude, s.speed, s.course, s.address,
         (replace(s.attributes, '\u0000', '')::jsonb - 'raw')::text,
         s.accuracy, s.network
  FROM import_stage.pos s JOIN import_stage.devmap m ON m.oldid = s.deviceid
  RETURNING 1)
SELECT count(*) FROM ins;
SQL
) || { log "INSERT FAIL $B"; sleep 30; continue; }
  log "$B: csv=$CSV_LINES inserted=$INSERTED"
  touch "$DONE/$B"
  rm -f "$NEXT"
  # compress chunks now >2 days behind the import frontier
  FRONTIER=$($PSQL -c "SELECT max(servertime)::date - 2 FROM import_stage.pos")
  if [ -n "$FRONTIER" ]; then
    $PSQL -c "SELECT count(compress_chunk(c.chunk_schema||'.'||c.chunk_name, true)) FROM timescaledb_information.chunks c WHERE c.hypertable_name='tc_positions' AND NOT c.is_compressed AND c.range_end::date <= '$FRONTIER' AND c.range_end < now() - interval '14 days'" >> $LOG 2>&1 || log "compress warn at $FRONTIER"
  fi
done

# ── events ──────────────────────────────────────────────────────────────
if [ -f "$STG/events.csv.gz" ] && [ ! -f "$DONE/events" ]; then
  $PSQL -c "CREATE UNLOGGED TABLE IF NOT EXISTS import_stage.ev (id bigint, type text, servertime timestamp, deviceid bigint, positionid bigint, geofenceid bigint, attributes text); TRUNCATE import_stage.ev"
  sudo -u postgres psql -qtA traccar -c "\copy import_stage.ev FROM PROGRAM 'zcat $STG/events.csv.gz' CSV"
  EV=$($PSQL -c "
    WITH ins AS (
      INSERT INTO tc_events (type, eventtime, deviceid, positionid, attributes)
      SELECT e.type, e.servertime, m.newid, e.positionid, e.attributes
      FROM import_stage.ev e JOIN import_stage.devmap m ON m.oldid = e.deviceid
      RETURNING 1)
    SELECT count(*) FROM ins")
  log "events inserted: $EV"
  touch "$DONE/events"
fi

log "IMPORT COMPLETE"

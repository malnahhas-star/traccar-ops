#!/usr/bin/env bash
# March uffizio_hist de-duplication. The failed-retry imports left ~297M exact
# duplicate rows (668M total / 371M unique) across March's 31 compressed chunks.
# Duplicates of a (device,fixtime) row live in the SAME chunk, so dedup is per-chunk.
# For each chunk: decompress -> delete byte-identical uffizio_hist copies (keep the
# lowest id) -> recompress. One chunk at a time keeps disk bounded; old-iot rows are
# never touched (excluded by the WHERE filter). Resumable (done markers), disk-guarded,
# graceful STOP file. Compression policy (job 1003) paused for the duration.
set -u
BASE=/home/ubuntu/uffizio_bridge
LOG=$BASE/march_dedup.log
DONE=$BASE/march_dedup_done
STOP=$BASE/march_dedup.STOP
MINFREE_GB=80
mkdir -p "$DONE"
PSQL(){ sudo -u postgres psql -d traccar -v ON_ERROR_STOP=1 -tA -c "$1"; }
log(){ echo "$(date -u +%FT%TZ) $*" >>"$LOG"; }

log "=== March dedup START (pid $$) ==="
PSQL "SELECT alter_job(1003, scheduled=>false);" >>"$LOG" 2>&1 && log "job 1003 (compression) paused"

mapfile -t CHUNKS < <(PSQL "SELECT chunk_schema||'.'||chunk_name FROM timescaledb_information.chunks WHERE hypertable_name='tc_positions' AND range_start >= '2026-03-01' AND range_start < '2026-04-01' ORDER BY range_start;")
log "chunks to process: ${#CHUNKS[@]}"

TOTDEL=0
for ch in "${CHUNKS[@]}"; do
  [ -f "$STOP" ] && { log "STOP file present — halting gracefully"; break; }
  tag=$(echo "$ch" | tr './' '__')
  [ -f "$DONE/$tag" ] && { log "skip $ch (already done)"; continue; }
  FREE=$(df --output=avail -BG / | tail -1 | tr -dc '0-9')
  [ "${FREE:-0}" -lt "$MINFREE_GB" ] && { log "ABORT: low disk ${FREE}G < ${MINFREE_GB}G before $ch"; break; }
  log "--- $ch (free ${FREE}G): decompress"
  PSQL "SELECT decompress_chunk('$ch', if_compressed=>true);" >>"$LOG" 2>&1 || { log "decompress FAILED $ch — stopping"; break; }
  UBEF=$(PSQL "SELECT count(*) FROM $ch WHERE attributes LIKE '%uffizio_hist%';")
  DEL=$(PSQL "WITH dup AS (
                SELECT ctid FROM (
                  SELECT ctid, row_number() OVER (
                    PARTITION BY deviceid, fixtime, latitude, longitude, speed, course, altitude, valid, md5(attributes)
                    ORDER BY id) AS rn
                  FROM $ch WHERE attributes LIKE '%uffizio_hist%'
                ) t WHERE rn > 1
              ), del AS (
                DELETE FROM $ch WHERE ctid IN (SELECT ctid FROM dup) RETURNING 1
              ) SELECT count(*) FROM del;")
  log "$ch uffizio_before=${UBEF} deleted=${DEL}: recompress"
  PSQL "SELECT compress_chunk('$ch', if_not_compressed=>true);" >>"$LOG" 2>&1 || { log "compress FAILED $ch — stopping"; break; }
  touch "$DONE/$tag"
  TOTDEL=$((TOTDEL + ${DEL:-0}))
  log "$ch DONE (running total deleted=${TOTDEL})"
done

PSQL "SELECT alter_job(1003, scheduled=>true);" >>"$LOG" 2>&1 && log "job 1003 (compression) re-enabled"
NDONE=$(ls "$DONE" 2>/dev/null | wc -l)
log "=== March dedup END: chunks_done=${NDONE}/${#CHUNKS[@]} total_deleted=${TOTDEL} ==="

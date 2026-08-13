#!/usr/bin/env bash
# Drives the 6-month Uffizio history import MONTH-by-MONTH, oldest->newest.
# Older source data is in monthly MySQL partitions (PK leads with imei_no), so a
# per-day scan re-reads the whole month; one scan per month is ~30x cheaper.
#
# Resumable/self-healing: a per-month marker in $DONE means skip. A $DONE/<m>.partial
# marker means a prior attempt died mid-month -> delete that month's hist rows, redo.
# After the first pass, retry any months still .partial (up to MAX_ROUNDS) so a
# transient DB/stream drop (which the import now detects and fails loudly on) heals
# without manual intervention.
#
# Compression is left to the TimescaleDB columnstore policy (job 1003, recompresses
# chunks >14d): rows are trimmed/small, so disk stays bounded without per-month work.
set -u
BASE=/home/ubuntu/uffizio_bridge
DONE=$BASE/done
LOG=$BASE/history.log
MAX_ROUNDS=${MAX_ROUNDS:-4}
mkdir -p "$DONE"
set -a; . "$BASE/uffizio.env"; set +a
PSQL() { sudo -u postgres psql -tA traccar -c "$1"; }
TODAY=$(date -u +%Y-%m-%d)

# import one month [start,end); returns 0 on success, 1 on failure (leaves .partial)
do_month() {
  local start="$1" end="$2" m="${1:0:7}"
  [ -f "$DONE/$m" ] && return 0
  if [ -f "$DONE/$m.partial" ]; then
    echo "$(date -u +%FT%TZ) $m partial — deleting its hist rows first" >>"$LOG"
    PSQL "DELETE FROM tc_positions WHERE fixtime >= TIMESTAMP '$start' AND fixtime < TIMESTAMP '$end' AND attributes LIKE '%uffizio_hist%';" >>"$LOG" 2>&1
  fi
  : > "$DONE/$m.partial"
  echo "$(date -u +%FT%TZ) === month $m  [$start .. $end) ===" >>"$LOG"
  local out rc
  out=$(python3 -W ignore "$BASE/uffizio_history_import.py" "$start" "$end" 2>>"$LOG"); rc=$?
  echo "$(date -u +%FT%TZ) $out (rc=$rc)" >>"$LOG"
  if [ $rc -ne 0 ]; then
    echo "$(date -u +%FT%TZ) FAILED $m — leaving .partial for retry" >>"$LOG"
    return 1
  fi
  echo "$out" >"$DONE/$m"; rm -f "$DONE/$m.partial"
  return 0
}

# month window [start,end); end capped at TODAY (live consumer owns today)
month_end() { local e; e=$(date -u -d "$1 +1 month" +%Y-%m-%d); [[ "$e" > "$TODAY" ]] && e="$TODAY"; echo "$e"; }

MONTHS=${MONTHS:-6}
declare -a STARTS
for ((k=MONTHS; k>=0; k--)); do
  STARTS+=( "$(date -u -d "$(date -u +%Y-%m-01) -$k month" +%Y-%m-01)" )
done
echo "$(date -u +%FT%TZ) DRIVER start months: ${STARTS[*]} (end-cap $TODAY)" >>"$LOG"

# pass 1
for start in "${STARTS[@]}"; do
  end=$(month_end "$start")
  [[ "$start" == "$end" ]] && continue
  do_month "$start" "$end"
done

# retry passes for anything still .partial
for ((round=1; round<=MAX_ROUNDS; round++)); do
  shopt -s nullglob
  parts=("$DONE"/*.partial)
  shopt -u nullglob
  [ ${#parts[@]} -eq 0 ] && break
  echo "$(date -u +%FT%TZ) retry round $round: ${#parts[@]} partial month(s)" >>"$LOG"
  for pf in "${parts[@]}"; do
    m=$(basename "$pf" .partial); start="$m-01"; end=$(month_end "$start")
    sleep 10
    do_month "$start" "$end"
  done
done

shopt -s nullglob; left=("$DONE"/*.partial); shopt -u nullglob
if [ ${#left[@]} -gt 0 ]; then
  echo "$(date -u +%FT%TZ) DRIVER done WITH FAILURES still partial: ${left[*]}" >>"$LOG"
else
  echo "$(date -u +%FT%TZ) DRIVER complete — all months imported" >>"$LOG"
fi

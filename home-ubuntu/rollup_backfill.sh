#!/bin/bash
# Re-roll device_daily_stats for the imported window, 4 days in parallel.
set -u
LOG=/home/ubuntu/rollup_backfill.log
DONE=/home/ubuntu/rollup_done
mkdir -p $DONE
roll_day() {
  d=$1
  [ -f "$DONE/$d" ] && return 0
  n=$(sudo -u postgres psql -v ON_ERROR_STOP=1 -qtA traccar -c "SELECT rollup_device_day('$d')" 2>>$LOG) \
    && { echo "$(date -u +%F' '%T) $d devices=$n" >> $LOG; touch "$DONE/$d"; } \
    || echo "$(date -u +%F' '%T) FAILDAY $d" >> $LOG
}
export -f roll_day
export LOG DONE
seq 0 183 | while read i; do date -u -d "2026-01-21 + $i days" +%F; done \
  | xargs -P 4 -I{} bash -c 'roll_day {}'
echo "ROLLUP BACKFILL FINISHED $(date -u)" >> $LOG

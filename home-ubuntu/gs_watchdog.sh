#!/bin/bash
# Restart gs_backfill.sh if it is not running but pending chunks remain.
export TZ=UTC
pgrep -f "bash /home/ubuntu/gs_backfill.sh" >/dev/null && exit 0
PEND=$(sudo -u postgres psql traccar -X -tAc "SELECT count(*) FROM telematics.gs_backfill WHERE status IN ('pending','running');" 2>/dev/null)
[ -z "$PEND" ] && exit 0
if [ "$PEND" -gt 0 ]; then
  # any chunk stuck in running (process died mid-chunk) -> reset to pending
  sudo -u postgres psql traccar -X -tAc "UPDATE telematics.gs_backfill SET status='pending' WHERE status='running';" >/dev/null 2>&1
  cd /home/ubuntu && setsid nohup bash /home/ubuntu/gs_backfill.sh >/dev/null 2>&1 &
  echo "$(date) watchdog: restarted backfill ($PEND remaining)" >> /home/ubuntu/gs_watchdog.log
fi

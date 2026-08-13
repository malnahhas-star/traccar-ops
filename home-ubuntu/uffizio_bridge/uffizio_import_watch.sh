#!/usr/bin/env bash
# Watches the Uffizio history import and notifies TellMe ONCE when it finishes,
# fails, or the driver dies. Runs detached; polls the driver log every 5 min.
set -u
BASE=/home/ubuntu/uffizio_bridge
LOG=$BASE/history.log
set -a; . "$BASE/tellme.env"; set +a    # TELLME_URL, TELLME_TOKEN

notify() {  # $1=status(resolved|firing)  $2=title  $3=body
  TELLME_URL="$TELLME_URL" TELLME_TOKEN="$TELLME_TOKEN" python3 - "$1" "$2" "$3" <<'PY'
import sys, os, json, urllib.request
url, tok = os.environ["TELLME_URL"], os.environ["TELLME_TOKEN"]
s, t, b = sys.argv[1], sys.argv[2], sys.argv[3]
p = {"status": s, "title": t, "commonAnnotations": {"summary": t},
     "alerts": [{"status": s, "labels": {"alertname": "UffizioHistoryImport"},
                 "annotations": {"summary": b}}]}
req = urllib.request.Request(url, data=json.dumps(p).encode(),
        headers={"Authorization": "Bearer " + tok, "Content-Type": "application/json"})
try: print(urllib.request.urlopen(req, timeout=15).read().decode())
except Exception as e: print("notify error:", e)
PY
}

while true; do
  if grep -q "DRIVER complete — all months imported" "$LOG" 2>/dev/null; then
    months=$(ls "$BASE/done/" 2>/dev/null | grep -v partial | tr '\n' ' ')
    counts=$(grep -E "inserted=[0-9]+ \(rc=0\)" "$LOG" | tail -8 | sed -E 's/.*RANGE ([0-9-]+)\.\.[0-9-]+ inserted=([0-9]+).*/\1=\2/' | tr '\n' ' ')
    notify resolved "✅ Uffizio history import COMPLETE" "All months imported: ${months}. Row counts: ${counts}"
    exit 0
  fi
  if grep -q "DRIVER done WITH FAILURES" "$LOG" 2>/dev/null; then
    line=$(grep "WITH FAILURES" "$LOG" | tail -1)
    notify firing "🔥 Uffizio history import FINISHED WITH FAILURES" "$line"
    exit 0
  fi
  if ! pgrep -f uffizio_history_driver.sh >/dev/null 2>&1; then
    notify firing "🔥 Uffizio history import DRIVER DIED" \
      "Driver process gone with no completion line. Last log: $(tail -3 "$LOG" | tr '\n' ' | ')"
    exit 0
  fi
  sleep 300
done

# Traccar / telematics DB-VM ops scripts

Operational scripts that run on the **DB VM** (Postgres/TimescaleDB host, private 20.0.4.101).
Tracked here so changes are versioned; deploy is manual (edit → commit → push → copy to the DB VM).

## refresh-live-positions.sh
Rebuilds `telematics.live_positions` — the snapshot the Fleet monitor map + object list
read from (`/live-clusters`, `/vehicles-skinny`).

- **Deploys to:** `/usr/local/bin/refresh-live-positions.sh` on the DB VM (root-owned).
- **Runs via:** `live-positions.service` (oneshot) on `live-positions.timer` (~every 30s).
- **Lock:** `flock` on `/run/refresh-live-positions.lock` (root tmpfs).
- **Logic:**
  - PASS A — baseline for every vehicle from `telematics.device_state` (last-known).
  - PASS B — overlay freshest position + heading from `tc_positions` (last 90 min).
  - Status: `moving` = speed > 0 km/h AND ≤ 250 (speed-driven — ignition is unreliable /
    often unwired); `idle` = ignition on & not moving; `stop` = otherwise; `inactive` = >24h stale.
  - Speed shown only when moving (else 0), so speed is always consistent with status.

### Deploy
    scp refresh-live-positions.sh <db-vm>:/tmp/  &&  sudo install -m755 /tmp/refresh-live-positions.sh /usr/local/bin/
    # (edit atomically; the 30s timer can catch a mid-write — write a temp file then mv/install)

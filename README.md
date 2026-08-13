# Traccar / telematics DB-VM ops scripts

Operational scripts that run on the **DB VM** (Postgres/TimescaleDB host, private 20.0.4.101,
reached via the T01 jump). Tracked here so changes are versioned; **deploy is manual** (edit →
commit → push → copy the file to the DB VM at its path below).

> Secrets are NOT in this repo. Scripts read them from env files on the DB VM
> (`~/uffizio_bridge/uffizio.env`, `~/uffizio_bridge/tellme.env`) — `.gitignore` excludes `*.env`.

## `/usr/local/bin/` (root)
| script | purpose |
|---|---|
| `refresh-live-positions.sh` | Rebuilds `telematics.live_positions` (the monitor map/list snapshot). Two-pass: `device_state` baseline + `tc_positions` overlay. Status is speed-driven (`moving` = speed 0–250 km/h; ignition unreliable/unwired). Runs via `live-positions.service` + `.timer` (~30s); `flock` on `/run/refresh-live-positions.lock`. |

## `home-ubuntu/` → `~ubuntu/` on the DB VM
| script | purpose |
|---|---|
| `gs_backfill.sh` | Historical GPS ground-speed backfill of `tc_positions.speed` (chunk-by-chunk, progress in `telematics.gs_backfill`). |
| `gs_watchdog.sh` | Restarts `gs_backfill` if it dies while chunks remain (runs from bridge-host cron in practice). |
| `import_history.sh` | Uffizio 6-month history import driver. |
| `odo_recover.sh` | 7-day odometer recovery from Uffizio daily tables → `tc_positions` attrs. |
| `rollup_backfill.sh` | Backfill `device_daily_stats` rollups. |
| `trip_addr_fill.sh` / `trip_addr_ongoing.sh` | Reverse-geocode / fill trip start/end addresses. |
| `uffizio_tunnel.sh` | SSH tunnel helper to the Uffizio side (via F01→bango). |

### `home-ubuntu/uffizio_bridge/`
| script | purpose |
|---|---|
| `uffizio_consumer.py` | Live Kafka `gps` consumer → `tc_positions` (the field-4 speed / field-5 odometer fix lives here). |
| `uffizio_events_consumer.py` | Live Kafka events consumer → telematics events. |
| `uffizio_history_import.py` / `uffizio_history_driver.sh` | Historical Uffizio import (MySQL daily tables → `tc_positions`). |
| `uffizio_io.py` | IO-id → attribute-name mapping. |
| `uffizio_import_watch.sh` | Progress watcher → TellMe. |
| `march_dedup.sh` | One-off March dedup. |
| `bango_sh.sh` / `uffq.sh` | Run a command / MySQL query on the Uffizio side over the F01→bango→MySQL relay. |

## Deploy (manual)
    scp <file> <db-vm-via-jump>:/tmp/  &&  ssh <db-vm> 'sudo install -m755 /tmp/<file> <target-path>'
    # For refresh-live-positions.sh write a temp file then install/mv — the 30s timer can catch a mid-write.

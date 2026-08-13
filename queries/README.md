# DB_Admin queries

SQL for the production Traccar TimescaleDB
(`ssh -i ../private.ppk ubuntu@145.241.153.26`, database `traccar`, PostgreSQL 16 + TimescaleDB 2.28).

Run any file on the server with:

```bash
sudo -u postgres psql -d traccar -f <file>.sql
```

## Files

| File | Purpose |
|---|---|
| `device_data_rate_report.sql` | Per-device message rate report by vehicle state (moving / stopped / idle engine-on / undefined) over a from→to period. Edit `from_time` / `to_time` in the `params` CTE. Heavy: ~2–4 min per day of data. |
| `latest_positions.sql` | Last received messages — the safe patterns for a hypertable. |
| `db_health.sql` | Sizes, compression ratio, policy job status, ingest rate, active sessions. |

## Rules for writing new queries against `tc_positions`

`tc_positions` is a TimescaleDB hypertable partitioned by **`fixtime`** (1-day chunks,
compressed after 14 days, dropped after 12 months, compression segmented by `deviceid`).

1. **Every query must bound `fixtime`** (`WHERE fixtime >= … AND fixtime < …`).
   Without it, Postgres touches all ~1,700 chunks and decompresses history.
2. Per-device lookups: filter `deviceid` + order by `fixtime` — matches the
   `(deviceid, fixtime)` index and the compression layout.
3. There is **no global index on `id` or `servertime`** — never order the whole
   table by them.
4. Analytics that read full days run faster with
   `SET enable_indexscan = off; SET enable_bitmapscan = off;` (sequential chunk
   reads beat time-index random I/O on this disk).
5. New tables must be `OWNER TO traccar` or the application loses access.

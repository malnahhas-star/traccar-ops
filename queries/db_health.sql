-- Quick health check of the Traccar TimescaleDB (run as postgres on the server).
\pset pager off

-- overall sizes
SELECT pg_size_pretty(pg_database_size('traccar')) AS db_size,
       pg_size_pretty(hypertable_size('tc_positions')) AS positions_size;

-- chunk / compression state
SELECT count(*) AS chunks,
       count(*) FILTER (WHERE is_compressed) AS compressed,
       min(range_start) AS oldest,
       max(range_end)   AS newest
FROM timescaledb_information.chunks
WHERE hypertable_name = 'tc_positions';

-- compression ratio
SELECT pg_size_pretty(before_compression_total_bytes) AS before,
       pg_size_pretty(after_compression_total_bytes)  AS after
FROM hypertable_compression_stats('tc_positions');

-- background jobs (compression + retention policies) last run status
SELECT job_id, application_name, last_run_status, last_run_started_at, next_start
FROM timescaledb_information.job_stats js
JOIN timescaledb_information.jobs USING (job_id);

-- live ingest rate (positions in the last minute) — id-delta method
SELECT count(*) AS positions_last_minute
FROM tc_positions WHERE fixtime > now() - interval '1 minute';

-- active / problematic sessions
SELECT pid, usename, state, wait_event_type, now() - query_start AS runtime,
       left(query, 80) AS query
FROM pg_stat_activity
WHERE state <> 'idle' AND pid <> pg_backend_pid()
ORDER BY query_start;

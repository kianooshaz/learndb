-- ============================================================================
-- 12-production/monitoring/monitoring.sql — the production query pack
-- ============================================================================
-- Run:  make sql FILE=12-production/monitoring/monitoring.sql
--       (plus: make pgbouncer / make replica for the last sections)
--
-- The questions this pack answers, in the order an incident asks them:
--   1. What is running RIGHT NOW?           (pg_stat_activity)
--   2. Who is blocking whom?                (blocking tree)
--   3. How long has everything been going?  (tx ages, idle-in-tx)
--   4. What is always slow?                 (pg_stat_statements)
--   5. Is the machine healthy?              (cache hit, dead tuples, bloat)
--   6. Are replicas keeping up?             (pg_stat_replication)
-- ============================================================================

\set ON_ERROR_STOP on

-- ---------------------------------------------------------------------------
-- 1. Right now: states, wait events, ages
-- ---------------------------------------------------------------------------
SELECT pid,
       usename,
       state,
       wait_event_type || '.' || coalesce(wait_event, '') AS waiting_on,
       now() - xact_start   AS tx_age,
       now() - query_start  AS query_age,
       left(query, 60)      AS query
FROM pg_stat_activity
WHERE datname = current_database()
  AND pid <> pg_backend_pid()
ORDER BY xact_start NULLS LAST
LIMIT 10;
-- state: active / idle / idle in transaction (the killer) / idle in tx aborted
-- wait_event_type: Lock (blocked), IO, Client (network/app), CPU empty.

-- ---------------------------------------------------------------------------
-- 2. The blocking tree: who must die so the rest can live
-- ---------------------------------------------------------------------------
-- Recursive walk over pg_blocking_pids (handles multi-hop waits):
WITH RECURSIVE blocked AS (
    SELECT pid AS blocked_pid, pid AS root_pid, 0 AS depth,
           array[pid] AS chain, query
    FROM pg_stat_activity
    WHERE cardinality(pg_blocking_pids(pid)) = 0 AND state = 'active'
      AND pid IN (SELECT unnest(pg_blocking_pids(p2.pid)) FROM pg_stat_activity p2)
UNION ALL
    SELECT a.pid, b.root_pid, b.depth + 1,
           b.chain || a.pid, a.query
    FROM blocked b
    JOIN pg_stat_activity a ON b.blocked_pid = ANY(pg_blocking_pids(a.pid))
    WHERE NOT a.pid = ANY(b.chain)
)
SELECT depth, chain, left(query, 50) AS waiting_query
FROM blocked ORDER BY depth, 1;
-- Simpler one-liner for most incidents:
--   SELECT pid, pg_blocking_pids(pid) AS blocked_by, left(query,60)
--   FROM pg_stat_activity WHERE cardinality(pg_blocking_pids(pid)) > 0;
-- Kill decision: pg_cancel_backend(pid) (query only) vs
-- pg_terminate_backend(pid) (session). Cancel first; terminate second.

-- ---------------------------------------------------------------------------
-- 3. Transaction hygiene: idle-in-transaction is a vacuum blocker
-- ---------------------------------------------------------------------------
SELECT count(*) FILTER (WHERE state = 'idle in transaction') AS idle_in_tx,
       max(now() - xact_start) FILTER (WHERE state = 'idle in transaction') AS oldest
FROM pg_stat_activity;
-- Policy: idle_in_transaction_session_timeout = '10min' fleet-wide.
-- Related reading: 07-performance/bloat.sql (the vacuum horizon).

-- ---------------------------------------------------------------------------
-- 4. Always slow: the top offenders (details: 10-extensions)
-- ---------------------------------------------------------------------------
SELECT round(total_exec_time::numeric) AS total_ms,
       calls,
       round(mean_exec_time::numeric, 1) AS mean_ms,
       shared_blks_hit + shared_blks_read AS buffers,
       left(query, 60) AS query
FROM pg_stat_statements
WHERE query NOT ILIKE '%pg_stat_statements%'
ORDER BY total_exec_time DESC
LIMIT 5;

-- One-off slow queries the stats view averages away: log them at the source
--   log_min_duration_statement = 500     -- ms; and/or auto_explain:
--   shared_preload_libraries += ',auto_explain'
--   auto_explain.log_min_duration = '1s'
--   auto_explain.log_analyze = on        -- logs the ACTUAL plan on slow queries

-- ---------------------------------------------------------------------------
-- 5. Health: cache, dead tuples, wraparound — the daily dashboard
-- ---------------------------------------------------------------------------
SELECT round(100.0 * sum(blks_hit) / nullif(sum(blks_hit) + sum(blks_read), 0), 1)
       AS cache_hit_pct               -- >99% in-memory working set (usually)
FROM pg_stat_database WHERE datname = current_database();

SELECT relname,
       n_live_tup, n_dead_tup,
       round(100.0 * n_dead_tup / nullif(n_live_tup, 0), 1) AS dead_pct,
       last_autovacuum
FROM pg_stat_user_tables
ORDER BY n_dead_tup DESC LIMIT 5;

-- Wraparound horizon (alert well before 2^31):
SELECT datname, age(datfrozenxid) AS xid_age,
       round(100.0 * age(datfrozenxid) / 2000000000, 1) AS pct_to_force
FROM pg_database ORDER BY 2 DESC LIMIT 3;

-- ---------------------------------------------------------------------------
-- 6. Replication (run on the PRIMARY after `make replica`)
-- ---------------------------------------------------------------------------
SELECT application_name, state, sync_state,
       pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn) AS replay_lag_bytes,
       write_lag, replay_lag
FROM pg_stat_replication;
-- Alert on lag bytes AND replay_lag; investigate stalls with
-- pg_stat_wal_receiver ON the replica.

-- TAKEAWAYS
-- * Incident order: activity -> blocking tree -> statements -> health.
-- * idle-in-transaction + missing timeouts cause most "mystery" incidents.
-- * auto_explain turns "it was slow once" into an actual plan.
-- * The Go probe (probe/main.go) loops exactly these queries.

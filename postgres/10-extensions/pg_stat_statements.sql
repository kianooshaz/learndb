-- ============================================================================
-- 10-extensions/pg_stat_statements.sql — the "what is slow?" oracle
-- ============================================================================
-- Run:  make sql FILE=10-extensions/pg_stat_statements.sql
--
-- pg_stat_statements tracks every query shape (normalized: literals
-- replaced by $n) with timings, rows, buffers. It is THE starting point of
-- every performance investigation: you don't guess which query is slow —
-- you ASK the server. Preloaded via shared_preload_libraries in compose.
-- ============================================================================

\set ON_ERROR_STOP on
\timing on

-- Generate a bit of diverse load so there's something to look at:
DROP SCHEMA IF EXISTS m10_pss CASCADE;
CREATE SCHEMA m10_pss;
CREATE TABLE m10_pss.events (id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY, kind text NOT NULL);
INSERT INTO m10_pss.events (kind) SELECT 'k' || g % 50 FROM generate_series(1, 200000) g;
SELECT count(*) FROM m10_pss.events WHERE kind = 'k3';
SELECT count(*) FROM m10_pss.events WHERE kind = 'k7';
SELECT count(*) FROM m10_pss.events WHERE id > 199000;
SELECT pg_sleep(0.05);
UPDATE m10_pss.events SET kind = 'x' WHERE id < 100;

-- ---------------------------------------------------------------------------
-- 1. Top queries by TOTAL time (the server-burners)
-- ---------------------------------------------------------------------------
SELECT round(total_exec_time::numeric, 1) AS total_ms,
       calls,
       round(mean_exec_time::numeric, 2)  AS mean_ms,
       rows,
       round(100 * shared_blks_hit / nullif(shared_blks_hit + shared_blks_read, 0), 1) AS cache_hit_pct,
       left(query, 70) AS query
FROM pg_stat_statements
WHERE query NOT LIKE '%pg_stat_statements%'
ORDER BY total_exec_time DESC
LIMIT 8;

-- ---------------------------------------------------------------------------
-- 2. The other three sorts (each answers a different question)
-- ---------------------------------------------------------------------------
-- Worst AVERAGES (user-perceived slowness):
SELECT round(mean_exec_time::numeric, 2) AS mean_ms, calls, left(query, 60) AS query
FROM pg_stat_statements
WHERE calls > 1 AND query NOT LIKE '%pg_stat_statements%'
ORDER BY mean_exec_time DESC LIMIT 5;

-- Most rows per call (cartesian smells, missing LIMIT):
SELECT round(rows::numeric / calls, 1) AS rows_per_call, calls, left(query, 60) AS query
FROM pg_stat_statements
WHERE calls > 1 AND query NOT LIKE '%pg_stat_statements%'
ORDER BY rows_per_call DESC LIMIT 5;

-- Buffer hogs (I/O-heavy; PG16 separates local vs shared):
SELECT shared_blks_read,
       local_blks_read,
       left(query, 60) AS query
FROM pg_stat_statements
WHERE query NOT LIKE '%pg_stat_statements%'
ORDER BY shared_blks_read DESC LIMIT 5;

-- ---------------------------------------------------------------------------
-- 3. Operations discipline
-- ---------------------------------------------------------------------------
-- pg_stat_statements_reset() clears history (do it before a load test to
-- capture ONLY that workload; otherwise don't — history is the point):
--   SELECT pg_stat_statements_reset();

-- Retention: data lives in shared memory + a file, survives restarts, and
-- grows with distinct query SHAPES. Track with:
SELECT count(*) AS distinct_query_shapes FROM pg_stat_statements;

-- What it does NOT do: per-client attribution (no user column unless you
-- add tracking), slow INDIVIDUAL queries (auto_explain does that — see
-- 12-production/monitoring), or wait-event analysis (pg_stat_activity).

-- Reading together in a real incident:
--   pg_stat_statements: WHICH query shape is slow
--   EXPLAIN (ANALYZE, BUFFERS): WHY that shape is slow
--   auto_explain + log_min_duration_statement: catch one-off offenders
--   pg_stat_activity: what is running RIGHT NOW

-- TAKEAWAYS
-- * Sort by total (server load), mean (UX), rows-per-call (sanity), reads (I/O).
-- * Queries are NORMALIZED: 'k3' and 'k7' above share one shape entry.
-- * Reset only around controlled experiments.
-- * This extension is on by default in this lab (compose preloads it).

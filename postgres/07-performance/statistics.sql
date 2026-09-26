-- ============================================================================
-- 07-performance/statistics.sql — autovacuum, autoanalyze, tuning the daemon
-- ============================================================================
-- Run:  make sql FILE=07-performance/statistics.sql
--
-- The planner is only as good as its statistics (05-query-planning showed
-- what bad estimates DO). This file covers the maintenance side:
--   * autovacuum = VACUUM (dead tuples, visibility map) + ANALYZE (stats)
--   * per-table tuning knobs and how to read them from the catalog
--   * what changes after ANALYZE (n_live_tup is NOT count(*))
--   * wraparound pressure (freezing) at a glance
-- ============================================================================

\set ON_ERROR_STOP on
\timing on
DROP SCHEMA IF EXISTS m07_stats CASCADE;
CREATE SCHEMA m07_stats;
SET search_path TO m07_stats, public;

CREATE TABLE audit_log (id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY, body text NOT NULL);
INSERT INTO audit_log (body) SELECT 'x' || g FROM generate_series(1, 100000) g;

-- ---------------------------------------------------------------------------
-- 1. Before/after: the planner's view vs reality
-- ---------------------------------------------------------------------------
-- n_live_tup/n_dead_tup are ESTIMATES maintained by DML counters + vacuum:
SELECT n_live_tup, n_dead_tup, last_analyze, last_autovacuum
FROM pg_stat_user_tables WHERE relid = 'm07_stats.audit_log'::regclass;

-- Churn without vacuum:
UPDATE audit_log SET body = 'y' WHERE id % 2 = 0;
SELECT n_live_tup, n_dead_tup
FROM pg_stat_user_tables WHERE relid = 'm07_stats.audit_log'::regclass;
-- ~50k dead tuples counted. They're reclaimable space AND invisible to you,
-- but they bloat scans (07-performance/bloat.sql).

-- Manual ANALYZE refreshes PLANNER stats (histograms), not dead tuples:
ANALYZE audit_log;
SELECT n_live_tup, n_dead_tup, last_analyze IS NOT NULL AS analyzed
FROM pg_stat_user_tables WHERE relid = 'm07_stats.audit_log'::regclass;

-- Manual VACUUM reclaims dead-tuple SPACE (for reuse) + updates the
-- visibility map (index-only scans!) + freezes old tuples:
VACUUM audit_log;
SELECT n_live_tup, n_dead_tup, last_vacuum IS NOT NULL AS vacuumed
FROM pg_stat_user_tables WHERE relid = 'm07_stats.audit_log'::regclass;

-- ---------------------------------------------------------------------------
-- 2. autovacuum: the daemon, its triggers, and per-table overrides
-- ---------------------------------------------------------------------------
SHOW autovacuum;                      -- on (default)
SHOW autovacuum_vacuum_threshold;     -- 50: base rows before triggering
SHOW autovacuum_vacuum_scale_factor;  -- 0.2: + 20% of table
-- trigger = threshold + scale_factor * n_live_tup:
--   our 100k-row table: 50 + 0.2*100000 = ~20,050 dead tuples -> vacuum.
SHOW autovacuum_analyze_threshold;    -- 50
SHOW autovacuum_analyze_scale_factor; -- 0.1: +10% inserts/updates -> analyze

-- Why big tables need OVERRIDES: 20% of 100M rows = 20M dead tuples before
-- autovacuum bothers — meanwhile bloat and estimates rot. Per-table:
ALTER TABLE audit_log SET (
    autovacuum_vacuum_scale_factor = 0.02,  -- 2% for big tables
    autovacuum_analyze_scale_factor = 0.01,
    autovacuum_vacuum_insert_scale_factor = 0.05  -- PG13+: vacuums on INSERT load too
);
-- The settings in the catalog:
SELECT reloptions FROM pg_class WHERE oid = 'm07_stats.audit_log'::regclass;
ALTER TABLE audit_log RESET (autovacuum_vacuum_scale_factor, autovacuum_analyze_scale_factor, autovacuum_vacuum_insert_scale_factor);

-- Workers are a global budget: autovacuum_vacuum_cost_limit is shared
-- across autovacuum_vacuum_workers; a giant table can starve the rest.
-- Check what the daemon has been doing:
SELECT relname, autovacuum_count, autoanalyze_count
FROM pg_stat_user_tables WHERE schemaname = 'm07_stats';

-- ---------------------------------------------------------------------------
-- 3. Anti-patterns (each one a real incident class)
-- ---------------------------------------------------------------------------
--  * Disabling autovacuum "for performance": dead tuples accumulate ->
--    every scan reads ghosts; wraparound eventually FORCES aggressive
--    vacuums or halts the cluster (10-minute wraparound explanation:
--    06-transactions/mvcc.sql -> xid freezer).
--  * Long-running transactions: vacuum cannot clean ANY tuple newer than
--    the oldest open transaction's snapshot. One idle-in-transaction
--    session for a day = a day of un-reclaimable churn cluster-wide.
    -- See it: SELECT pid, state, xact_start, now() - xact_start AS age
    --         FROM pg_stat_activity WHERE state <> 'idle' ORDER BY age DESC;
--  * Counting on n_live_tup for exact counts: it's an estimate by design.

-- ---------------------------------------------------------------------------
-- 4. Track counts cost: track_counts=on (default) adds per-DML bookkeeping.
-- Keep it on; the overhead is small and everything above depends on it.
SHOW track_counts;

-- TAKEAWAYS
-- * autovacuum = space + visibility + freezing; autoanalyze = planner stats.
-- * Scale factors are per-table overridable — tune big/hot tables lower.
-- * Long-lived transactions are vacuum's nemesis; monitor and kill them.
-- * Never disable autovacuum; fix what made someone want to.

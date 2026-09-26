-- ============================================================================
-- 07-performance/bloat.sql — measuring and preventing table/index bloat
-- ============================================================================
-- Run:  make sql FILE=07-performance/bloat.sql
--
-- Bloat = dead tuples + free space inside the table/index files. It inflates
-- I/O for EVERY scan and dilutes the page cache. Causes:
--   * churn (updates/deletes) outrunning autovacuum
--   * long-running transactions pinning dead tuples (the #1 killer)
--   * aborted bulk loads / repeated UPDATE-all patterns
-- Measured here with pgstattuple (exact, slow) — plus the fast catalog
-- estimates you can run on production any time.
-- ============================================================================

\set ON_ERROR_STOP on
\timing on
DROP SCHEMA IF EXISTS m07_bloat CASCADE;
CREATE SCHEMA m07_bloat;
SET search_path TO m07_bloat, public;

CREATE TABLE sessions (
    id int PRIMARY KEY,
    token text NOT NULL,
    updated_at timestamptz NOT NULL DEFAULT now()
);
INSERT INTO sessions SELECT g, md5(g::text), now() FROM generate_series(1, 200000) g;
ANALYZE sessions;

-- Baseline: pgstattuple reads the WHOLE table (exact, expensive):
SELECT table_len, tuple_count, tuple_len,
       dead_tuple_count, dead_tuple_len,
       round(100.0 * free_space / table_len, 1) AS free_pct
FROM pgstattuple('m07_bloat.sessions');

-- The catalog way (instant, estimates from pg_stat — what you poll in prod):
SELECT n_live_tup, n_dead_tup,
       round(100.0 * n_dead_tup / nullif(n_live_tup, 0), 1) AS dead_pct
FROM pg_stat_user_tables WHERE relid = 'm07_bloat.sessions'::regclass;

-- ---------------------------------------------------------------------------
-- 1. Simulate the #1 incident: churn + a long-open transaction
-- ---------------------------------------------------------------------------
-- A transaction that stays open (batch job, abandoned psql, connection leak)
-- defines the horizon: vacuum can NEVER clean tuples created after the
-- oldest open transaction's snapshot, even after they're dead everywhere.
BEGIN;                                   -- this tx pins the snapshot horizon
SELECT count(*) FROM sessions;           -- tx now holds a snapshot

UPDATE sessions SET token = md5(token), updated_at = now();   -- 200k dead tuples
UPDATE sessions SET token = md5(token), updated_at = now();   -- 200k MORE (the
                                        -- first 200k can't be cleaned anyway)
ANALYZE sessions;
SELECT n_dead_tup, n_live_tup FROM pg_stat_user_tables
WHERE relid = 'm07_bloat.sessions'::regclass;

COMMIT;                                  -- release the horizon
VACUUM sessions;                         -- NOW cleanup can happen
SELECT n_dead_tup FROM pg_stat_user_tables
WHERE relid = 'm07_bloat.sessions'::regclass;
-- But the FILE is now bloated (free space inside), measured exactly:
SELECT round(100.0 * free_space / table_len, 1) AS free_pct
FROM pgstattuple('m07_bloat.sessions');
-- ~40-50% free. Every seq scan reads ~2x the bytes it needs.

-- ---------------------------------------------------------------------------
-- 2. Index bloat (pgstatindex) — the silent one
-- ---------------------------------------------------------------------------
CREATE INDEX sessions_token_idx ON sessions (token);
UPDATE sessions SET token = md5(token);  -- churn through the index too
SELECT round(avg_leaf_density::numeric, 1) AS avg_leaf_density,
       leaf_fragmentation
FROM pgstatindex('m07_bloat.sessions_token_idx');
-- avg_leaf_density below ~60-70 means the btree is mostly air.

-- Remedies ranked:
--   1. fix the cause: long transactions, autovacuum tuning (statistics.sql)
--   2. REINDEX CONCURRENTLY (index bloat only)
--   3. pg_repack / table swap for table bloat (online)
--   4. VACUUM FULL only in a maintenance window (ACCESS EXCLUSIVE)

-- ---------------------------------------------------------------------------
-- 3. The production monitoring pair (run anywhere, instant, no extension):
-- ---------------------------------------------------------------------------
SELECT relname,
       n_live_tup,
       n_dead_tup,
       round(100.0 * n_dead_tup / nullif(n_live_tup, 0), 1) AS dead_pct,
       last_autovacuum
FROM pg_stat_user_tables
WHERE schemaname = 'm07_bloat'
ORDER BY n_dead_tup DESC;

-- And the long-transaction detector (bloat's accomplice):
SELECT pid, state, now() - xact_start AS tx_age, left(query, 50) AS query
FROM pg_stat_activity
WHERE xact_start IS NOT NULL
ORDER BY xact_start
LIMIT 5;
-- Set idle_in_transaction_session_timeout (e.g. 10 minutes) so abandoned
-- sessions can't pin the horizon for hours. (12-production/monitoring.)

-- TAKEAWAYS
-- * Bloat = dead+free space inside files; every read pays for it.
-- * Long transactions block vacuum: monitor tx age, set timeouts.
-- * pgstattuple/pgstatindex measure exactly; pg_stat_user_tables polls free.
-- * Fix causes first; REINDEX CONCURRENTLY / pg_repack over VACUUM FULL.

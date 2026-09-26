-- ============================================================================
-- 07-performance/vacuum.sql — reaping dead tuples: the MVCC garbage truck
-- ============================================================================
-- Run:  make sql FILE=07-performance/vacuum.sql
--
-- WHY VACUUM EXISTS (the 60-second version of MVCC economics):
--   UPDATE/DELETE never free space — they leave dead tuple versions
--   (06-transactions/mvcc.sql). Nothing may overwrite a tuple that a
--   concurrent REPEATABLE READ transaction can still see. So cleanup is
--   deferred and asynchronous: VACUUM.
--
-- What VACUUM (plain) does:
--   * marks dead tuples' space REUSABLE by future inserts in the same table
--   * truncates trailing empty pages at the end of the table
--   * sets visibility-map bits -> index-only scans get fast
--   * FREEZES old tuple xmin -> transaction-id wraparound protection
-- What it does NOT do: return disk space to the OS (except that tail), and
-- it does NOT defragment/shrink the file.
-- ============================================================================

\set ON_ERROR_STOP on
\timing on
DROP SCHEMA IF EXISTS m07_vac CASCADE;
CREATE SCHEMA m07_vac;
SET search_path TO m07_vac, public;

CREATE TABLE churn (id int PRIMARY KEY, v text NOT NULL DEFAULT repeat('x', 200));
INSERT INTO churn SELECT g, 'v1' FROM generate_series(1, 100000) g;

-- ---------------------------------------------------------------------------
-- 1. Create bloat, then watch VACUUM reclaim (space-for-reuse, not to OS)
-- ---------------------------------------------------------------------------
SELECT pg_size_pretty(pg_table_size('churn')) AS before_size;

UPDATE churn SET v = 'v2';                    -- 100k new versions; 100k dead
SELECT n_dead_tup FROM pg_stat_user_tables
WHERE relid = 'm07_vac.churn'::regclass;

VACUUM churn;
SELECT pg_size_pretty(pg_table_size('churn')) AS after_vacuum_size;   -- same!
SELECT n_dead_tup FROM pg_stat_user_tables
WHERE relid = 'm07_vac.churn'::regclass;                              -- 0

-- The file did NOT shrink, but the interior free space is reusable:
INSERT INTO churn SELECT g + 1000000, 'v3' FROM generate_series(1, 100000) g;
SELECT pg_size_pretty(pg_table_size('churn')) AS after_reuse_size;
-- The re-inserted 100k rows mostly FIT in reclaimed space: growth << 2x.

-- ---------------------------------------------------------------------------
-- 2. VACUUM FULL — the nuclear option (and why you rarely press it)
-- ---------------------------------------------------------------------------
-- VACUUM FULL rewrites the ENTIRE table compactly and returns disk to the
-- OS... under an ACCESS EXCLUSIVE lock: no reads, no writes, for the whole
-- rewrite. On a 200GB table that's a scheduled maintenance window.
-- (Demo on our small table to show the mechanics:)
CREATE TABLE churn_copy (LIKE churn INCLUDING ALL);
INSERT INTO churn_copy SELECT * FROM churn;
UPDATE churn_copy SET v = 'z' WHERE id % 2 = 0;
VACUUM churn_copy;
SELECT pg_size_pretty(pg_table_size('churn_copy')) AS bloated;
VACUUM FULL churn_copy;
SELECT pg_size_pretty(pg_table_size('churn_copy')) AS compacted;
-- The production alternative: pg_repack (extension, rebuilds online) or
-- CREATE TABLE new AS SELECT + swap (careful with locks/FKs/sequences).

-- ---------------------------------------------------------------------------
-- 3. FREEZING and wraparound — the reason vacuum is non-negotiable
-- ---------------------------------------------------------------------------
-- xmin/xmax are 32-bit transaction ids; ~4 billion exist. PostgreSQL
-- compares them MODULO 2^31, so ancient un-frozen tuples would eventually
-- appear to be "in the future" — to prevent that lie, vacuum FREEZES tuples
-- older than vacuum_freeze_min_age, making them visible to everyone forever.
-- If aging gets ahead of freezing, the cluster FORCES aggressive vacuums
-- (autovacuum_freeze_max_age, default 200M tx) and ultimately refuses
-- writes ("database is not accepting commands to avoid wraparound").
--
-- Per-database and per-table age (your daily monitoring query):
SELECT datname, age(datfrozenxid) AS xid_age,
       2000000000 - age(datfrozenxid) AS until_forced_vacuum
FROM pg_database ORDER BY 2 DESC;
SELECT relname, age(relfrozenxid) FROM pg_class
WHERE relkind = 'r' AND relnamespace = 'm07_vac'::regnamespace;

-- Aggressive freeze demo knob (don't run on prod):
--   VACUUM (FREEZE, VERBOSE) churn;

-- ---------------------------------------------------------------------------
-- 4. Watching a vacuum work (progress view, great in production)
-- ---------------------------------------------------------------------------
-- While any vacuum runs (autovacuum included), this shows live progress:
SELECT * FROM pg_stat_progress_vacuum;   -- empty when none running
-- phases: scanning heap -> vacuuming indexes -> cleanup; plus heap_blks_*

-- ANALYZE is a DIFFERENT job (statistics, not space) — analyze.sql next.

-- TAKEAWAYS
-- * VACUUM: reclaims-for-reuse, sets visibility bits, freezes xids.
-- * Disk shrinks only via VACUUM FULL (locks!) / pg_repack / table swap.
-- * Wraparound: monitor age(datfrozenxid); never disable autovacuum.
-- * pg_stat_progress_vacuum shows any vacuum's live progress.

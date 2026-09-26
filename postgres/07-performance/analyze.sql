-- ============================================================================
-- 07-performance/analyze.sql — how the planner learns your data
-- ============================================================================
-- Run:  make sql FILE=07-performance/analyze.sql
--
-- ANALYZE samples each table (300 * default_statistics_target rows by
-- default) and builds the pg_stats picture the planner reasons with:
-- n_distinct, most common values + frequencies, histogram, correlation.
-- It's cheap, takes only a SHARE lock (reads/writes continue), and is
-- absolutely mandatory after bulk loads and big distribution changes.
-- ============================================================================

\set ON_ERROR_STOP on
\timing on
DROP SCHEMA IF EXISTS m07_an CASCADE;
CREATE SCHEMA m07_an;
SET search_path TO m07_an, public;

CREATE TABLE users_t (id int PRIMARY KEY, country text NOT NULL, score int NOT NULL);
-- Start SMALL with a skew the planner hasn't learned yet:
INSERT INTO users_t SELECT g, 'US', g % 100 FROM generate_series(1, 1000) g;
ANALYZE users_t;

-- What statistics look like for country:
SELECT attname, n_distinct,
       most_common_vals AS top_values,
       most_common_freqs AS top_freqs,
       histogram_bounds IS NOT NULL AS has_histogram,
       correlation::numeric(3,2)
FROM pg_stats
WHERE schemaname='m07_an' AND tablename='users_t' AND attname IN ('country','score','id');
-- country: 1 distinct value, MCV 'US' @ 100% — perfect information.

-- ---------------------------------------------------------------------------
-- 1. The bulk-load trap: ANALYZE after loading, always
-- ---------------------------------------------------------------------------
-- Grow the table 1000x with a NEW distribution (now 'DE' dominates):
INSERT INTO users_t
SELECT g, (ARRAY['DE','DE','DE','DE','FR'])[1 + g % 5], g % 100
FROM generate_series(1001, 200000) g;
-- (No ANALYZE yet.) The planner still believes: 1000 rows, all 'US':
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF)
SELECT count(*) FROM users_t WHERE country = 'DE';
-- Estimate: ~all rows (=tiny). Actual: ~160k. Plans built on this fiction
-- (join strategies!) would be wrong all day.

ANALYZE users_t;
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF)
SELECT count(*) FROM users_t WHERE country = 'DE';
-- Estimates now track reality. autovacuum's autoanalyze would catch up at
-- ~10% churn (statistics.sql) — after a bulk load, don't wait: ANALYZE.

-- ---------------------------------------------------------------------------
-- 2. Resolution: statistics_target and histogram buckets
-- ---------------------------------------------------------------------------
-- score has 100 distinct values evenly spread. Estimates on ranges:
EXPLAIN (COSTS OFF) SELECT count(*) FROM users_t WHERE score BETWEEN 40 AND 49;
-- Roughly right: histogram_bounds has ~100 buckets for 100 values.

-- For high-cardinality columns (timestamps, prices), more buckets help:
ALTER TABLE users_t ALTER COLUMN score SET STATISTICS 500;
ANALYZE users_t;
-- default is 100; 1000 max per column; global default_statistics_target.
-- Cost: bigger pg_stats rows, slightly slower planning. Tune per column,
-- not globally, when ONE column misbehaves.

-- ---------------------------------------------------------------------------
-- 3. When n_distinct is wrong: fix it explicitly
-- ---------------------------------------------------------------------------
-- The sample can misjudge heavily-skewed cardinalities. You know the truth?
-- Tell the planner (great for near-constant or bounded-cardinality cols):
ALTER TABLE users_t ALTER COLUMN country SET (n_distinct = 3);
ANALYZE users_t;
-- Common real case: boolean-ish columns (n_distinct=2), tenant ids with a
-- known ceiling, enum-like text columns.

-- ---------------------------------------------------------------------------
-- 4. ANALYZE mechanics worth knowing
-- ---------------------------------------------------------------------------
--  * Sampling is RANDOM (uniform pages); it does NOT read the whole table —
--    that's why it's cheap and why it can still miss rare-value skew.
--  * Takes SHARE UPDATE EXCLUSIVE: no blocking of reads or writes.
--  * Manual ANALYZE can run in a transaction; autoanalyze cannot be forced.
--  * ANALYZE VERBOSE shows sampling decisions (good for debugging stats).

-- TAKEAWAYS
-- * ANALYZE = sample -> pg_stats = the planner's model of your data.
-- * After EVERY bulk load/backfill: ANALYZE (and let autovacuum do the rest).
-- * statistics_target per column for high-cardinality columns.
-- * Know the manual overrides: n_distinct, and extended stats for
-- * correlated columns (05-query-planning/planner_statistics.sql).

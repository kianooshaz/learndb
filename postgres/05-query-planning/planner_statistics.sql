-- ============================================================================
-- 05-query-planning/planner_statistics.sql — why the planner guesses wrong
-- ============================================================================
-- Run:  make sql FILE=05-query-planning/planner_statistics.sql
--
-- Everything the planner decides, it decides from STATISTICS in pg_stats:
--   n_distinct, most_common_vals/freqs (skew), histogram_bounds (ranges),
--   correlation (physical order vs index order).
-- Estimates are histograms built from a SAMPLE (default 100x300 rows) —
-- cheap, approximate, and refreshable with ANALYZE. When the guess is
-- wrong, the plan is wrong; this file breaks estimates on purpose and
-- fixes them with every tool PostgreSQL has.
-- ============================================================================

\set ON_ERROR_STOP on
\timing on
DROP SCHEMA IF EXISTS m05_stats CASCADE;
CREATE SCHEMA m05_stats;
SET search_path TO m05_stats, public;

-- ---------------------------------------------------------------------------
-- The anatomy of a column's statistics
-- ---------------------------------------------------------------------------
CREATE TABLE events (
    id     bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    kind   text NOT NULL,
    tenant int  NOT NULL,
    at     timestamptz NOT NULL DEFAULT now()
);
-- HEAVY skew: 'login' is 96% of rows:
INSERT INTO events (kind, tenant)
SELECT CASE WHEN g % 25 = 0 THEN 'logout' ELSE 'login' END,
       1 + (g % 200)
FROM generate_series(1, 1000000) g;
ANALYZE events;

-- most_common_vals/freqs: the skew table — planner's top values + frequencies
-- (most_common_vals is type anyarray; psql renders it as text — no cast):
SELECT attname,
       most_common_vals AS top_values,
       most_common_freqs::real[] AS top_freqs
FROM pg_stats
WHERE schemaname = 'm05_stats' AND tablename = 'events' AND attname = 'kind';
-- 'login' ~0.96: the planner KNOWS the skew. Watch it use it:

-- Rare value -> index plan:
CREATE INDEX events_kind_idx ON events (kind);
EXPLAIN (COSTS OFF) SELECT count(*) FROM events WHERE kind = 'logout';
-- Common value -> seq scan, same column, same index:
EXPLAIN (COSTS OFF) SELECT count(*) FROM events WHERE kind = 'login';
-- ONE index, TWO plans, BOTH correct — because statistics know the skew.
-- This is the answer to "my index is used for one value but not another".

-- ---------------------------------------------------------------------------
-- Stale statistics: the silent performance regression
-- ---------------------------------------------------------------------------
CREATE TABLE clicks (id bigint GENERATED ALWAYS AS IDENTITY, campaign int);
INSERT INTO clicks (campaign) SELECT 1 FROM generate_series(1, 100) g;  -- tiny
ANALYZE clicks;
-- Planner currently believes campaign=1 -> ~50 rows of a 100-row table:
EXPLAIN (COSTS OFF) SELECT count(*) FROM clicks WHERE campaign = 1;

-- Now bulk-load 2M rows of campaign=2 WITHOUT analyzing:
INSERT INTO clicks (campaign) SELECT 2 FROM generate_series(1, 2000000) g;
-- Stale stats still say "campaign=1 selects half the table" (100 rows truth,
-- 2M-row reality) — and campaign=2 looks rare when it's everything:
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF)
SELECT count(*) FROM clicks WHERE campaign = 2;
-- Seq Scan is right here BY LUCK (it's the whole table). But estimates vs
-- actual show the lie: rows=... vs 2000000.
ANALYZE clicks;
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF)
SELECT count(*) FROM clicks WHERE campaign = 2;
-- Lesson: after EVERY bulk load, run ANALYZE (07-performance/analyze.sql).
-- autovacuum will catch up, but "eventually" is not "before the query".

-- ---------------------------------------------------------------------------
-- default_statistics_target: sample size, histogram resolution
-- ---------------------------------------------------------------------------
SHOW default_statistics_target;   -- 100 -> 100x300x300 rows sampled
-- Per-column override when one column's distribution is complex:
ALTER TABLE events ALTER COLUMN kind SET STATISTICS 500;
ANALYZE events;
-- More MCVs/histogram buckets = better estimates, bigger planning time,
-- bigger stats. 100-500 covers most real cases.

-- n_distinct OVERRIDES (rare but career-saving): planner guessed wildly on
-- your low-cardinality-but-actually-huge column? Correct it explicitly:
--   ALTER TABLE events ALTER COLUMN tenant SET (n_distinct = 200);

-- ---------------------------------------------------------------------------
-- Extended statistics: when COLUMN COMBINATIONS break estimates
-- ---------------------------------------------------------------------------
-- Independent columns multiply; real data correlates. Demo: city+country:
CREATE TABLE places (id int, city text, country text);
INSERT INTO places
SELECT g, 'city' || (g % 100), 'country' || (g % 10)
FROM generate_series(1, 1000000) g;
-- Correlate them: city 'cityN' (N<10 -> country0, N=10..19 -> country1, ...):
UPDATE places SET country = 'country' || (substr(city, 5)::int / 10);
ANALYZE places;

-- Planner assumes independence: city='city5' (1/100) AND country='country0'
-- (1/10) -> estimates 1/1000 of rows = 1000 rows. Truth: city5 IS country0
-- = 10000 rows. 10x off:
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF)
SELECT count(*) FROM places WHERE city = 'city5' AND country = 'country0';

-- CREATE STATISTICS teaches the planner the correlation:
CREATE STATISTICS places_city_country (dependencies, ndistinct, mcv)
    ON city, country FROM places;
ANALYZE places;
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF)
SELECT count(*) FROM places WHERE city = 'city5' AND country = 'country0';
-- Estimate now ~10k: the MCV list covers the combo explicitly.
-- GROUP BY estimation gets smarter too (ndistinct part).

-- TAKEAWAYS
-- * Plans are only as good as pg_stats: n_distinct, MCVs, histogram,
-- * correlation — read them BEFORE blaming an index.
-- * Skew = same index, different plans per value. That's correct behavior.
-- * ANALYZE after bulk loads; raise stats target / set n_distinct for
-- * stubborn columns; CREATE STATISTICS for correlated columns.

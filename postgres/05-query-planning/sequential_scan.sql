-- ============================================================================
-- 05-query-planning/sequential_scan.sql — when scanning everything WINS
-- ============================================================================
-- Run:  make sql FILE=05-query-planning/sequential_scan.sql
--
-- A Seq Scan reads the table front to back: every 8KB page, one row at a
-- time. Modern storage makes this REMARKABLY efficient (sequential reads are
-- the fastest thing a disk does), so the planner picks it far more often
-- than newcomers expect — and is RIGHT to.
--
-- This file builds a table and walks the boundary between "index wins" and
-- "seq scan wins" empirically.
-- ============================================================================

\set ON_ERROR_STOP on
\timing on
DROP SCHEMA IF EXISTS m05_seq CASCADE;
CREATE SCHEMA m05_seq;
SET search_path TO m05_seq, public;

CREATE TABLE readings (
    id     bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    sensor int  NOT NULL,
    value  numeric NOT NULL,
    at     timestamptz NOT NULL
);
INSERT INTO readings (sensor, value, at)
SELECT 1 + (g % 1000),
       (g % 100)::numeric,
       now() - ((500000 - g) || ' seconds')::interval
FROM generate_series(1, 500000) g;
CREATE INDEX readings_sensor_idx ON readings (sensor);
ANALYZE readings;

-- ---------------------------------------------------------------------------
-- EXPERIMENT 1: 1%, 10%, 50%, 99% of the table — watch the flip
-- ---------------------------------------------------------------------------
-- Each query selects a different share of sensors. Predict before running,
-- then check:
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF, TIMING OFF, SUMMARY OFF)
SELECT * FROM readings WHERE sensor = 7;                 -- 0.1% of rows

EXPLAIN (ANALYZE, BUFFERS, COSTS OFF, TIMING OFF, SUMMARY OFF)
SELECT * FROM readings WHERE sensor < 100;               -- 10% of rows

EXPLAIN (ANALYZE, BUFFERS, COSTS OFF, TIMING OFF, SUMMARY OFF)
SELECT * FROM readings WHERE sensor < 500;              -- 50% of rows

EXPLAIN (ANALYZE, BUFFERS, COSTS OFF, TIMING OFF, SUMMARY OFF)
SELECT * FROM readings WHERE sensor > 10;                -- 99% of rows
-- The flip from Index/Bitmap to Seq is the random-page-cost model:
--   random_page_cost=4.0 (default) says one random page fetch = 4 seq ones.
--   On SSDs people set 1.1; on spinning disks keep 4+. After changing it,
--   plans shift: try  SET random_page_cost = 1.1;  and re-run the 50% one.

-- ---------------------------------------------------------------------------
-- EXPERIMENT 2: why "the whole table" is sometimes the honest answer
-- ---------------------------------------------------------------------------
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF, TIMING OFF, SUMMARY OFF)
SELECT count(*), avg(value) FROM readings;
-- No index can answer aggregates over ALL rows faster than one pass over
-- the heap (the sensor index contains neither value nor all rows... the PK
-- index-only scan would still visit every entry).

-- ---------------------------------------------------------------------------
-- EXPERIMENT 3: small tables — the planner ignores your indexes politely
-- ---------------------------------------------------------------------------
CREATE TABLE tiny (id int PRIMARY KEY, t text);
INSERT INTO tiny SELECT g, 'x' FROM generate_series(1, 200) g;
ANALYZE tiny;
EXPLAIN (ANALYZE, COSTS OFF) SELECT * FROM tiny WHERE id = 7;
-- Seq Scan! 200 rows fit in a handful of pages — the index detour costs more
-- than reading everything. This is CORRECT, not a missing-index bug, and
-- it's why micro-benchmarks on tiny tables mislead about production.

-- ---------------------------------------------------------------------------
-- Reading the Filter line: what the scan actually threw away
-- ---------------------------------------------------------------------------
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF)
SELECT count(*) FROM readings WHERE value = 50 AND sensor = 7;
-- Seq Scan shows "Rows Removed by Filter". When removed >> returned on a
-- repeated query, THAT's the smoke test for an index (04-indexes/btree.sql),
-- or a partial index (04-indexes/partial_indexes.sql).

-- The parallel seq scan: above certain sizes PG splits the scan across
-- workers (Gather node). Watch for it on the big aggregate in experiment 2
-- (may or may not kick in at 500k rows — raise sizes to see it):
SET LOCAL max_parallel_workers_per_gather = 4; BEGIN; SET LOCAL max_parallel_workers_per_gather = 4;
EXPLAIN (COSTS OFF) SELECT sum(value) FROM readings;
ROLLBACK;

-- TAKEAWAYS
-- * Seq scan is not a failure state; it's optimal for unselective queries,
--   full-table aggregates, and small tables.
-- * The seq/index boundary follows random_page_cost + selectivity; on SSD
--   fleets, revisit random_page_cost.
-- * Rows Removed by Filter on a hot query = index candidate.

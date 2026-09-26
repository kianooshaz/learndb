-- ============================================================================
-- 04-indexes/covering_indexes.sql — INCLUDE and index-only scans
-- ============================================================================
-- Run:  make sql FILE=04-indexes/covering_indexes.sql
--
-- An index-only scan reads EVERYTHING from the index and skips the heap
-- visit entirely — often the difference between reading 3 pages and 30,000.
-- PostgreSQL can do it when:
--   1. every needed column is IN the index (key or INCLUDE), and
--   2. the heap pages involved are known all-visible (visibility map —
--      VACUUM's other job; see 07-performance/vacuum.sql).
-- INCLUDE columns ride along UNINDEXED (no sort/lookup semantics, smaller
-- cost than full key columns) purely to enable this scan type.
-- ============================================================================

\set ON_ERROR_STOP on
\timing on
DROP SCHEMA IF EXISTS m04_cover CASCADE;
CREATE SCHEMA m04_cover;
SET search_path TO m04_cover, public;

CREATE TABLE orders (
    id         bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    customer_id bigint NOT NULL,
    status     text NOT NULL,
    note       text NOT NULL DEFAULT repeat('y', 60)
);
INSERT INTO orders (customer_id, status)
SELECT 1 + (g % 10000),
       (ARRAY['paid','shipped','delivered'])[1 + g % 3]
FROM generate_series(1, 500000) g;

-- Baseline: plain index on the key we filter by:
CREATE INDEX orders_customer ON orders (customer_id);
ANALYZE orders;

-- Query wants (status) too -> must visit the heap for each match:
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF, TIMING OFF, SUMMARY OFF)
SELECT status, count(*) FROM orders WHERE customer_id = 42 GROUP BY status;
-- "Index Scan ... Heap Fetches: N" — N heap page visits.

-- Covering version — status as an INCLUDE column:
CREATE INDEX orders_customer_covering
    ON orders (customer_id) INCLUDE (status);
ANALYZE orders;
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF, TIMING OFF, SUMMARY OFF)
SELECT status, count(*) FROM orders WHERE customer_id = 42 GROUP BY status;
-- Index Only Scan; "Heap Fetches: 0" (after vacuum below). Buffers collapse.

-- If the heap isn't vacuumed recently, index-only scans degrade —
-- demonstrate by dirtying every page then comparing:
UPDATE orders SET note = note WHERE id % 5000 = 0;   -- creates dead-ish tuples, clears visibility bits
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF, TIMING OFF, SUMMARY OFF)
SELECT status, count(*) FROM orders WHERE customer_id = 42 GROUP BY status;
-- Heap Fetches > 0 again! The visibility map only knows pages are clean
-- after VACUUM/autovacuum runs:
VACUUM orders;
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF, TIMING OFF, SUMMARY OFF)
SELECT status, count(*) FROM orders WHERE customer_id = 42 GROUP BY status;
-- This trio of plans (heap visits -> 0 -> back) is THE mental model for
-- "index-only scan" in Postgres: index + visibility map, not just index.

-- INCLUDE vs adding key columns: when ORDER BY or range predicates need the
-- column, make it a KEY column (btree ordering applies). When the column is
-- only payload, INCLUDE it (cheaper, no ordering implications).

-- Size cost of covering everything:
SELECT relname, pg_size_pretty(pg_relation_size(oid)) AS size
FROM pg_class WHERE relname IN ('orders_customer','orders_customer_covering');

-- Width warning: INCLUDE-ing wide columns (note TEXT(60)...) balloons the
-- index and evicts other things from cache. Cover narrow, hot columns.

-- TAKEAWAYS
-- * Index-only scan = all columns in index + pages all-visible.
-- * Heap Fetches in EXPLAIN ANALYZE measures the visibility-map miss rate.
-- * Key columns for filtering/ordering; INCLUDE for pure payload.
-- * VACUUM isn't only about space — it directly speeds up index-only scans.

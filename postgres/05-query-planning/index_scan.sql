-- ============================================================================
-- 05-query-planning/index_scan.sql — Index Scan, Index Only Scan, ordering
-- ============================================================================
-- Run:  make sql FILE=05-query-planning/index_scan.sql
--
-- Three ways an index serves a query:
--   Index Scan        descend tree -> for each hit, heap-fetch the row
--   Index Only Scan   everything comes from the index; heap only for
--                     visibility checks (near-zero if pages all-visible)
--   Backward scan     btree walked in reverse for ORDER BY x DESC
-- The hidden cost model: index entries are stored in KEY order, but heap
-- rows are scattered — each hit can be a DIFFERENT 8KB page. Correlation
-- decides how painful that is (planner_statistics.sql measures it).
-- ============================================================================

\set ON_ERROR_STOP on
\timing on
DROP SCHEMA IF EXISTS m05_idx CASCADE;
CREATE SCHEMA m05_idx;
SET search_path TO m05_idx, public;

CREATE TABLE shipments (
    id       bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    origin   text NOT NULL,
    status   text NOT NULL,
    at       timestamptz NOT NULL
);
-- Deliberately HIGH correlation: at increases with id — the classic
-- append-only pattern. (For a low-correlation table, re-insert with a
-- shuffled 'at' and re-run: the same scan gets slower — more random pages.)
INSERT INTO shipments (origin, status, at)
SELECT 'hub' || (g % 40), (ARRAY['enroute','enroute','delivered'])[1 + g % 3],
       now() - ((3000000 - g) || ' seconds')::interval
FROM generate_series(1, 3000000) g;
CREATE INDEX shipments_at_idx ON shipments (at);
CREATE INDEX shipments_origin_status_idx ON shipments (origin, status);
ANALYZE shipments;

-- ---------------------------------------------------------------------------
-- Plain Index Scan — point lookup
-- ---------------------------------------------------------------------------
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF, TIMING OFF, SUMMARY OFF)
SELECT * FROM shipments WHERE at = now() - interval '10 seconds';

-- ---------------------------------------------------------------------------
-- Index Only Scan — the heap is (almost) never touched
-- ---------------------------------------------------------------------------
-- Query needs only indexed columns:
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF, TIMING OFF, SUMMARY OFF)
SELECT origin, status FROM shipments WHERE origin = 'hub7';
-- "Heap Fetches: 0" (thanks to recent VACUUM/autovacuum state). Compare
-- Buffers with the same query selecting 'at' (not in the index): heap visit
-- per row. This is why covering_indexes exist (04-indexes/).

-- ---------------------------------------------------------------------------
-- Correlation: the same index scan, 10x more random pages
-- ---------------------------------------------------------------------------
-- pg_stats.correlation: 1.0 = heap order matches index order (cheap scans)
SELECT correlation FROM pg_stats
WHERE schemaname = 'm05_idx' AND tablename = 'shipments' AND attname = 'at';

-- Range over the well-correlated column = near-sequential heap reads:
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF, TIMING OFF, SUMMARY OFF)
SELECT count(*) FROM shipments WHERE at > now() - interval '10 minutes';
-- Buffers ≈ pages/rows — nearly no waste. NOW imagine the same query on a
-- table where 'at' was backfilled randomly: every row = 1 page = random I/O
-- (that's why BRIN vs btree discussions always start with correlation —
-- 04-indexes/brin.sql).

-- ---------------------------------------------------------------------------
-- Index scan as a sorted stream — ORDER BY disappears
-- ---------------------------------------------------------------------------
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF)
SELECT at FROM shipments ORDER BY at DESC LIMIT 5;
-- "Backward Index Scan" — no Sort, LIMIT stops after 5 entries. This exact
-- pattern powers "latest N" API endpoints; without the index it's a full
-- sort of 3M rows (kill it with statement_timeout if you try it).

-- ORDER BY in the "wrong" direction (mixed ASC/DESC) needs a matching index:
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF)
SELECT origin, status, at FROM shipments
WHERE origin = 'hub7' ORDER BY at DESC LIMIT 3;
-- (uses origin_status only for equality, then sorts; a
--  (origin, at DESC) index would remove the Sort — try adding it!)

-- ---------------------------------------------------------------------------
-- When the planner REFUSES the index even though it exists (recap links)
-- ---------------------------------------------------------------------------
-- unselective predicate:
EXPLAIN (COSTS OFF) SELECT count(*) FROM shipments WHERE at > now() - interval '2900000 minutes';
-- function on column:
EXPLAIN (COSTS OFF) SELECT count(*) FROM shipments WHERE extract(hour from at) = 5;

-- TAKEAWAYS
-- * Index Scan = tree descent + per-hit heap fetch; correlation decides cost.
-- * Index Only Scan = "Heap Fetches: 0" only with a fresh visibility map.
-- * Backward scans serve ORDER BY DESC LIMIT without sorting.
-- * Low selectivity / expressions on the column -> planner picks seq scan
--   (04-indexes/btree.sql case studies).

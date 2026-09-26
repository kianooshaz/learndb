-- ============================================================================
-- 05-query-planning/bitmap_scan.sql — the middle path between scan types
-- ============================================================================
-- Run:  make sql FILE=05-query-planning/bitmap_scan.sql
--
-- Plain index scan: heap-fetch per hit (random pages). Seq scan: read
-- everything. Bitmap scan: the index FIRST builds a bitmap of candidate
-- PAGES, then reads those pages sequentially and rechecks the condition.
-- It's the planner saying "many hits, but scattered — let me batch them".
--
-- Two-part anatomy:
--   Bitmap Index Scan   — index -> page bitmap (lossy fallback if huge)
--   Bitmap Heap Scan    — read pages in order, Recheck condition
-- Bonus: Bitmap AND / OR combine MULTIPLE indexes' bitmaps.
-- ============================================================================

\set ON_ERROR_STOP on
\timing on
DROP SCHEMA IF EXISTS m05_bitmap CASCADE;
CREATE SCHEMA m05_bitmap;
SET search_path TO m05_bitmap, public;

CREATE TABLE posts (
    id      bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    author  text NOT NULL,
    topic   text NOT NULL,
    body    text NOT NULL DEFAULT repeat('z', 200)
);
INSERT INTO posts (author, topic)
SELECT 'user' || (g % 5000),                      -- 0.02% of rows per author
       (ARRAY['go','postgres','devops','ai'])[1 + g % 4]
FROM generate_series(1, 1000000) g;

-- Correlation ~0 (authors scattered) — exactly where bitmap scans shine:
CREATE INDEX posts_author_idx ON posts (author);
CREATE INDEX posts_topic_idx  ON posts (topic);
ANALYZE posts;

-- ---------------------------------------------------------------------------
-- 1. The sweet spot: enough rows that per-hit random I/O hurts, few enough
--    that a full scan is waste. ~10% here (50 authors worth):
-- ---------------------------------------------------------------------------
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF, TIMING OFF, SUMMARY OFF)
SELECT count(*) FROM posts WHERE author IN (
    SELECT 'user' || g FROM generate_series(0, 49) g);

-- ---------------------------------------------------------------------------
-- 2. Bitmap AND / OR — multiple indexes in one plan
-- ---------------------------------------------------------------------------
-- Two separate predicates, each with its own index:
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF, TIMING OFF, SUMMARY OFF)
SELECT count(*) FROM posts
WHERE author = 'user42' AND topic = 'go';
-- BitmapAnd: intersect the two bitmaps, THEN heap. This is the machinery
-- behind "I have indexes on each column; can the query use both?" YES.

EXPLAIN (ANALYZE, BUFFERS, COSTS OFF, TIMING OFF, SUMMARY OFF)
SELECT count(*) FROM posts
WHERE topic = 'go' OR author = 'user42';
-- BitmapOr. (A single btree on (author, topic) would be better for the AND
-- case — but the OR case cannot use one composite btree at all!)

-- ---------------------------------------------------------------------------
-- 3. The LIMIT trap: bitmap scans lose ordered output
-- ---------------------------------------------------------------------------
-- Bitmap scan reads pages in PAGE order; results need recheck/sort:
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF)
SELECT * FROM posts WHERE author = 'user42' ORDER BY id DESC LIMIT 5;
-- The planner often prefers a plain Index Scan even for ~200 rows here,
-- because the pkey index provides order. But force the bitmap to see the
-- cost: (then it must SORT before LIMIT).
BEGIN;
SET LOCAL enable_indexscan = off;
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF)
SELECT * FROM posts WHERE author = 'user42' ORDER BY id DESC LIMIT 5;
ROLLBACK;
-- Lesson: bitmap scans can't feed ORDER BY+LIMIT efficiently — they're for
-- counting/aggregating over medium-sized scattered sets.

-- ---------------------------------------------------------------------------
-- 4. Lossy bitmaps — work_mem decides exact vs lossy
-- ---------------------------------------------------------------------------
-- If the bitmap overflows work_mem, PG stores whole-page bits ("lossy") and
-- the Heap Scan RECHECKS every row on those pages. With small work_mem:
BEGIN;
SET LOCAL work_mem = '64kB';
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF, TIMING OFF, SUMMARY OFF)
SELECT count(*) FROM posts WHERE topic = 'go' OR author = 'user42';
ROLLBACK;
-- Look for "Heap Blocks: exact=... lossy=..." — lossy means more CPU.
-- At default 4MB the same query shows exact=... lossy=0. work_mem is a
-- per-sort/per-node budget, per query, per connection (07-performance).

-- ---------------------------------------------------------------------------
-- When each scan type wins (rough selectivity bands, this data shape):
--   ~0-5%   Index Scan           (few hits, order preserved, LIMIT-friendly)
--   ~5-25%  Bitmap Heap Scan     (batched hits, can combine indexes)
--   >25%    Seq Scan             (just read the table)
--   + Index Only Scan when all columns fit the index & pages all-visible.
-- ============================================================================

-- TAKEAWAYS
-- * Bitmap = page-batching between two index entries; Recheck exactness.
-- * BitmapAnd/Or lets MULTIPLE single-column indexes serve one query.
-- * No ordered output: pair with SORT when needed — or don't use it.
-- * Small work_mem -> lossy bitmaps -> hidden CPU on the heap scan.

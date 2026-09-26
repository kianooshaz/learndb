-- ============================================================================
-- 04-indexes/brin.sql — BRIN: gigantic append-only tables' best friend
-- ============================================================================
-- Run:  make sql FILE=04-indexes/brin.sql
--
-- BRIN = Block Range Index. For every contiguous block range of the heap
-- (default 128 pages = 1MB) it stores just (min, max) of the indexed column
-- — kilobytes instead of gigabytes. It can only answer "the value MIGHT be
-- in this block range". It only works when physical row order correlates
-- with the column (append-only time series = correlation 1.0).
--
-- It's the difference between "index tells you the row" and "index tells
-- you which 1MB chunks to read". For a 500GB events table queried by time
-- window, that's exactly what you want.
-- ============================================================================

\set ON_ERROR_STOP on
\timing on
DROP SCHEMA IF EXISTS m04_brin CASCADE;
CREATE SCHEMA m04_brin;
SET search_path TO m04_brin, public;

-- 2M-row append-only event table (think: 500GB in production):
CREATE TABLE events (
    id    bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    at    timestamptz NOT NULL,      -- written in increasing order
    level text NOT NULL,
    body  text NOT NULL DEFAULT repeat('x', 100)
);
INSERT INTO events (at, level)
SELECT now() - ((2000000 - g) || ' seconds')::interval,
       (ARRAY['info','info','info','warn','error'])[1 + g % 5]
FROM generate_series(1, 2000000) g;

-- Physical correlation (1.0 = perfectly aligned with disk order):
SELECT correlation FROM pg_stats
WHERE schemaname = 'm04_brin' AND tablename = 'events' AND attname = 'at';

CREATE INDEX events_at_brin ON events USING brin (at) WITH (pages_per_range = 64);
ANALYZE events;

-- Compare index sizes — this is the whole pitch:
SELECT relname,
       pg_size_pretty(pg_relation_size(oid)) AS size,
       round(100.0 * pg_relation_size(oid) / pg_relation_size('m04_brin.events'), 2) || '%' AS pct_of_table
FROM pg_class
WHERE relname IN ('events_at_brin','events_pkey');

-- Time-window query — BRIN + recheck:
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF, TIMING OFF, SUMMARY OFF)
SELECT count(*) FROM events
WHERE at BETWEEN now() - interval '5 minutes' AND now() - interval '4 minutes';
-- Bitmap Heap Scan with "Rows Removed by Filter: ..." — the recheck. We read
-- a handful of 8KB pages instead of the whole table. Re-run with \timing on
-- to feel it.

-- Now break the correlation and watch BRIN degrade — the CRITICAL lesson:
INSERT INTO events (at, level)
SELECT now() + (random() * interval '10 days'), 'backfill'   -- scattered times
FROM generate_series(1, 20000) g;
ANALYZE events;
SELECT correlation FROM pg_stats
WHERE schemaname = 'm04_brin' AND tablename = 'events' AND attname = 'at';

EXPLAIN (ANALYZE, BUFFERS, COSTS OFF, TIMING OFF, SUMMARY OFF)
SELECT count(*) FROM events
WHERE at BETWEEN now() - interval '5 minutes' AND now() - interval '4 minutes';
-- Some ranges now span "everything" -> min..max covers the whole table ->
-- BRIN degrades toward a seq scan. BRIN has NO magic: it's a bet on layout.

-- pages_per_range tuning: smaller ranges = more precise, bigger index.
-- 32/64 pages are common; you can autosummarize off-heap updates with
-- autosummarize=on. brin_summarize_new_values() manual touch-up exists too.

-- What BRIN is for (and not):
--  YES: append-only time series (logs, metrics, telemetry) filtered by time;
--       tables so large a btree literally doesn't fit your budget/disk.
--  NO:  updatable tables, random insert order, selective point lookups
--       (btree), anything needing ordering guarantees.

-- TAKEAWAYS
-- * BRIN stores (min,max) per block range: tiny, lossy, correlation-bound.
-- * Perfect for append-only + range predicates at terabyte scale.
-- * Correlation is measurable (pg_stats.correlation) — check it BEFORE
-- * betting on BRIN; backfills destroy it.

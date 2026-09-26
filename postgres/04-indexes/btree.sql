-- ============================================================================
-- 04-indexes/btree.sql — the default index, and when the planner refuses it
-- ============================================================================
-- Run:  make demo  &&  make sql FILE=04-indexes/btree.sql
--
-- A B-tree is a balanced sorted tree over your key(s). It answers:
--   = and IN lookups, ranges (<, <=, >, >=, BETWEEN), prefix LIKE 'abc%',
--   ORDER BY matching its sort order, and uniqueness.
-- It does NOT help: leading-wildcard LIKE '%abc%', regex, functions on the
-- column (until you index the expression), or very low selectivity.
--
-- This file is a systematic experiment: watch each query CHOOSE or REFUSE
-- the index, and learn to predict which.
-- ============================================================================

\set ON_ERROR_STOP on
\timing on
SET search_path TO demo, public;

-- A big, correlation-free playground table (200k rows):
DROP TABLE IF EXISTS m04_events CASCADE;
CREATE TABLE m04_events (
    id      bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    payload text NOT NULL,
    kind    text NOT NULL,
    user_id bigint NOT NULL,
    at      timestamptz NOT NULL
);
INSERT INTO m04_events (payload, kind, user_id, at)
SELECT 'p' || g,
       'k' || (g % 100),                      -- 100 kinds = 1% selectivity each
       1 + (g * 7919) % 5000,                 -- pseudo-random spread
       now() - ((g % 200000) || ' seconds')::interval
FROM generate_series(1, 200000) g;
CREATE INDEX m04_events_kind_idx ON m04_events (kind);
ANALYZE m04_events;

-- ---------------------------------------------------------------------------
-- CASE 1: selective predicate -> plain Index Scan
-- ---------------------------------------------------------------------------
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF, TIMING OFF, SUMMARY OFF)
SELECT * FROM m04_events WHERE kind = 'k42';
-- Index Scan using m04_events_kind_idx; ~2k rows out of 200k = 1%: cheap.

-- ---------------------------------------------------------------------------
-- CASE 2: "why is my index NOT used?!" — low selectivity
-- ---------------------------------------------------------------------------
-- A hypothetical query over MANY kinds (say 60 of 100 -> 60% of the table):
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF, TIMING OFF, SUMMARY OFF)
SELECT * FROM m04_events WHERE kind IN (
    SELECT 'k' || g FROM generate_series(0, 59) g);
-- Seq Scan! Reading 60% of rows THROUGH the index = random heap I/O per row;
-- reading the whole heap sequentially is cheaper. THE index is fine — the
-- QUESTION is unselective. This is the #1 misunderstood planner decision.

-- Prove the index CAN serve it (and see what it costs):
SET LOCAL enable_seqscan = off;   -- inside a tx: DEMO ONLY, never in prod
BEGIN;
SET LOCAL enable_seqscan = off;
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF, TIMING OFF, SUMMARY OFF)
SELECT * FROM m04_events WHERE kind IN (
    SELECT 'k' || g FROM generate_series(0, 59) g);
ROLLBACK;
-- Compare "Buffers: shared read" and time between the two plans: forcing the
-- index usually LOSES. The planner isn't confused; it priced both.

-- ---------------------------------------------------------------------------
-- CASE 3: expression on the column kills the index
-- ---------------------------------------------------------------------------
EXPLAIN (ANALYZE, COSTS OFF) SELECT * FROM m04_events WHERE upper(kind) = 'K42';
-- Seq Scan + Filter. The index holds 'k42' (raw values); upper(kind) is a
-- different key. Fix A: don't wrap the column. Fix B: expression index
-- (04-indexes/expression_indexes.sql):
CREATE INDEX m04_events_kind_upper_idx ON m04_events (upper(kind));
ANALYZE m04_events;
EXPLAIN (ANALYZE, COSTS OFF) SELECT * FROM m04_events WHERE upper(kind) = 'K42';

-- Type mismatch cousin: comparing a text column to an int (implicit cast)
-- or a timestamp column to a text literal with odd formatting — the cast can
-- defeat index usage. Match the indexed expression's type exactly.

-- ---------------------------------------------------------------------------
-- CASE 4: LIKE anchoring — prefix works, leading % doesn't
-- ---------------------------------------------------------------------------
CREATE INDEX m04_events_payload_idx ON m04_events (payload);
ANALYZE m04_events;
EXPLAIN (COSTS OFF) SELECT * FROM m04_events WHERE payload LIKE 'p1999%';  -- prefix: OK
EXPLAIN (COSTS OFF) SELECT * FROM m04_events WHERE payload LIKE '%999';   -- suffix: seq scan
-- (locale note: with non-C collations even prefix LIKE may need
-- text_pattern_ops; 10-extensions/pg_trgm.sql indexes ANY substring.)

-- ---------------------------------------------------------------------------
-- CASE 5: NULLs ARE indexed in btree
-- ---------------------------------------------------------------------------
SELECT count(*) FROM m04_events WHERE kind IS NULL;   -- 0 here, but:
-- btree indexes NULLs — IS NULL / IS NOT NULL / ORDER BY x NULLS FIRST all
-- use it. (Some databases skip NULLs; PostgreSQL doesn't.)

-- ---------------------------------------------------------------------------
-- Index size vs table size, and what the tree costs you on writes
-- ---------------------------------------------------------------------------
SELECT relname,
       pg_size_pretty(pg_relation_size(oid))      AS size,
       pg_size_pretty(pg_table_size(oid))         AS total
FROM pg_class
WHERE relname IN ('m04_events','m04_events_kind_idx','m04_events_pkey')
ORDER BY size DESC;
-- Every index is another sorted structure maintained on EVERY insert/update
-- of its columns. 04-indexes/covering_indexes.sql measures that write tax.

-- B-tree entries for long common key prefixes are deduplicated internally
-- since PG11 (deduplication) — repeated prefixes cost far less than the raw
-- bytes suggest. (For UNIQUE enforcement the same machinery still guarantees
-- correctness; our (kind, user_id) data has duplicates, so plain index here:
CREATE INDEX m04_events_kind_user_idx ON m04_events (kind, user_id);

-- TAKEAWAYS — "why didn't my index get used?" in order of likelihood:
--  1. predicate matches too many rows (selectivity) — check pg_stats;
--  2. expression/cast on the indexed column — match or index the expression;
--  3. LIKE '%x' patterns — pg_trgm or redesign;
--  4. composite index column order — leading column not constrained
--     (multicolumn_indexes.sql);
--  5. stale statistics — ANALYZE (planner_statistics.sql);
--  6. it IS the right choice — seq scan on 60% of a table is not a bug.

-- ============================================================================
-- 04-indexes/hash.sql — equality-only indexes, and why you rarely use them
-- ============================================================================
-- Run:  make demo  &&  make sql FILE=04-indexes/hash.sql
--
-- Hash indexes bucket keys by hash: O(1)-ish lookups for = only. No ranges,
-- no ordering, no uniqueness. In exchange: small entries, and for very long
-- keys (URLs, digests) each entry is ~constant-size instead of a full copy.
--
-- History that still shapes advice: before PostgreSQL 10, hash indexes were
-- not WAL-logged (lost on crash) — many old tutorials say "never use them".
-- Since PG10 they're crash-safe and replicated.
-- ============================================================================

\set ON_ERROR_STOP on
\timing on
SET search_path TO demo, public;

-- Long realistic keys: request trace ids (64 hex chars)
DROP TABLE IF EXISTS m04_traces CASCADE;
CREATE TABLE m04_traces (
    id  bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tid text NOT NULL
);
INSERT INTO m04_traces (tid)
SELECT md5(g::text) || md5(g::text || 'x')       -- 64-char pseudo trace ids
FROM generate_series(1, 100000) g;

CREATE INDEX m04_traces_tid_btree ON m04_traces USING btree (tid);
CREATE INDEX m04_traces_tid_hash  ON m04_traces USING hash  (tid);
ANALYZE m04_traces;

-- What the planner does for = :
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF)
SELECT * FROM m04_traces WHERE tid = md5('42') || md5('42x');

-- Show both work, then compare cold hard numbers:
SET LOCAL max_parallel_workers_per_gather = 0;
BEGIN;
SET LOCAL enable_seqscan = off;
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF)
SELECT count(*) FROM m04_traces WHERE tid = md5('42') || md5('42x');
ROLLBACK;

-- Size comparison — hash entries don't store the key, just the hash:
SELECT relname, pg_size_pretty(pg_relation_size(oid)) AS size
FROM pg_class
WHERE relname IN ('m04_traces_tid_btree','m04_traces_tid_hash');

-- What hash CANNOT do (all fall back to seq scan):
EXPLAIN (COSTS OFF) SELECT * FROM m04_traces WHERE tid > 'f000';
EXPLAIN (COSTS OFF) SELECT * FROM m04_traces ORDER BY tid LIMIT 3;
--   ERROR if you ask for a unique HASH index: not supported.

-- Multi-column hash indexes are allowed (whole-row hash of the tuple), but a
-- composite btree is almost always more useful (leading-column queries!).

-- Verdict for real systems:
--  * default to btree — it covers = AND ranges AND ORDER BY AND uniqueness;
--  * consider hash only for: pure equality on very long keys at large scale,
--    where the size win matters (memcached-style lookup tables);
--  * measure on YOUR data — pg_relation_size above is the honest argument.

-- TAKEAWAYS
-- * Hash = equality only, crash-safe since PG10, compact entries.
-- * No ranges/order/unique/multi-column-prefix queries.
-- * Reaching for hash is an optimization AFTER btree proved insufficient.

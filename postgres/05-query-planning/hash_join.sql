-- ============================================================================
-- 05-query-planning/hash_join.sql — the workhorse of unsorted big joins
-- ============================================================================
-- Run:  make sql FILE=05-query-planning/hash_join.sql
--
-- Hash Join:
--   BUILD: hash every row of the (estimated) smaller side into an in-memory
--          table keyed on the join column (work_mem budget!)
--   PROBE: stream the bigger side; each row looks up its hash bucket.
-- O(build + probe) — one pass each side, order-independent. It only works
-- for EQUALITY join conditions (hash can't express ranges).
--
-- The node you'll see most in analytics; the spilling you'll see most in
-- incidents ("Batches: >1" means it didn't fit work_mem).
-- ============================================================================

\set ON_ERROR_STOP on
\timing on
DROP SCHEMA IF EXISTS m05_hash CASCADE;
CREATE SCHEMA m05_hash;
SET search_path TO m05_hash, public;

CREATE TABLE sessions (
    id       bigint PRIMARY KEY,
    user_id  bigint NOT NULL,
    device   text NOT NULL
);
INSERT INTO sessions
SELECT g, 1 + (g::bigint * 7919) % 50000, (ARRAY['ios','android','web'])[1 + g % 3]
FROM generate_series(1, 600000) g;

CREATE TABLE users_t (
    id      bigint PRIMARY KEY,
    email   text NOT NULL,
    country text NOT NULL
);
INSERT INTO users_t
SELECT g, 'u' || g || '@x.com', (ARRAY['US','DE','FR'])[1 + g % 3]
FROM generate_series(1, 100000) g;
ANALYZE sessions;
ANALYZE users_t;

-- ---------------------------------------------------------------------------
-- 1. The standard shape — equality, no useful indexes, medium sizes
-- ---------------------------------------------------------------------------
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF, TIMING OFF, SUMMARY OFF)
SELECT count(*)
FROM sessions s
JOIN users_t u ON u.id = s.user_id
WHERE s.device = 'ios';
-- Hash Join: build hash on users_t (smaller), probe with sessions rows.
-- "Memory Usage: NkB  Batches: 1" = fit in work_mem.

-- ---------------------------------------------------------------------------
-- 2. Spilling: work_mem too small -> Batches > 1 -> temp files
-- ---------------------------------------------------------------------------
BEGIN;
SET LOCAL work_mem = '64kB';       -- starve it (real apps forget this GUC exists)
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF, TIMING OFF, SUMMARY OFF)
SELECT count(*)
FROM sessions s
JOIN users_t u ON u.id = s.user_id;
ROLLBACK;
-- Batches: 40+ (each batch = extra pass + temp read), plus a "Temp Read/Write"
-- under buffers. THIS is what a "why did my report get 20x slower on the big
-- table" incident looks like. Same query at default work_mem: Batches: 1.

-- Bump it and watch batches collapse:
BEGIN;
SET LOCAL work_mem = '256MB';
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF, TIMING OFF, SUMMARY OFF)
SELECT count(*)
FROM sessions s
JOIN users_t u ON u.id = s.user_id;
ROLLBACK;
-- CAUTION: work_mem is PER SORT/HASH NODE, PER QUERY, PER CONNECTION.
-- 256MB x 12 nodes x 200 connections =OOM math. Tune with pg_stat views on
-- real traffic (07-performance/query_optimization.sql), not in a vacuum.

-- ---------------------------------------------------------------------------
-- 3. Hash requires equality. Range joins fall back to NL/Merge:
-- ---------------------------------------------------------------------------
CREATE TABLE events_v2 (id bigint PRIMARY KEY, user_id bigint, at timestamptz);
INSERT INTO events_v2 SELECT g, 1 + (g::bigint * 7919) % 50000, now() - (g || ' seconds')::interval
FROM generate_series(1, 400000) g;
ANALYZE events_v2;

EXPLAIN (COSTS OFF)
SELECT count(*)
FROM events_v2 e
JOIN sessions s ON s.user_id = e.user_id AND s.id > e.id;   -- inequality
-- -> Nested Loop (or Merge Join if sorted). No hash possible.

-- ---------------------------------------------------------------------------
-- 4. Hash aggregate — same engine, different job
-- ---------------------------------------------------------------------------
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF)
SELECT device, count(*) FROM sessions GROUP BY device;
-- HashAggregate = build hash on group keys, accumulate counts. Same work_mem
-- spilling rules ("Batches", "Memory Usage"), same tuning story.

-- Skew warning: one hash key with a huge share of rows (that viral user)
-- makes ONE overloaded bucket. PG has no automatic skew handling like some
-- warehouses — rewrite around the whale row if you find one.

-- ---------------------------------------------------------------------------
-- Hash join vs nested loop in one sentence each:
--   NL  : (few outer rows) x (indexed inner lookup)  — OLTP
--   Hash: one full pass per side, equality only      — analytics/bulk
-- ============================================================================

-- TAKEAWAYS
-- * Hash Join = build(probe), equality-only, order-independent.
-- * Batches>1 / temp writes = work_mem spill — the #1 silent report killer.
-- * work_mem is per-node per-query per-connection: budget before raising.
-- * HashAggregate is the same machinery powering GROUP BY.

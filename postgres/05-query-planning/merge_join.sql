-- ============================================================================
-- 05-query-planning/merge_join.sql — join for already-sorted inputs
-- ============================================================================
-- Run:  make sql FILE=05-query-planning/merge_join.sql
--
-- Merge Join: both inputs sorted by the join key; walk them in lockstep
-- (two pointers, like merging two sorted lists). O(rows) after sorting —
-- but sorting is O(n log n), so the planner only picks Merge when inputs
-- come pre-sorted (indexes!) or when it needs sorted output anyway (ORDER BY
-- + LIMIT at the end makes an upfront sort acceptable).
--
-- Also unique among join types: handles RANGE conditions natively.
-- ============================================================================

\set ON_ERROR_STOP on
\timing on
DROP SCHEMA IF EXISTS m05_merge CASCADE;
CREATE SCHEMA m05_merge;
SET search_path TO m05_merge, public;

CREATE TABLE invoices (
    id      bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    user_id bigint NOT NULL,
    amount  numeric NOT NULL
);
CREATE TABLE users_t (
    id      bigint PRIMARY KEY,
    email   text NOT NULL
);
INSERT INTO users_t SELECT g, 'u' || g || '@x.com' FROM generate_series(1, 100000) g;
-- invoices ordered by user_id via identity (correlated insert order):
INSERT INTO invoices (user_id, amount)
SELECT g, (g % 300)::numeric FROM generate_series(1, 100000) g
UNION ALL
SELECT g, (g % 300)::numeric FROM generate_series(1, 100000) g;
CREATE INDEX invoices_user_idx ON invoices (user_id);   -- pre-sorted input
ANALYZE users_t;
ANALYZE invoices;

-- ---------------------------------------------------------------------------
-- 1. Both sides sortable via index -> Merge Join wins on equality too
-- ---------------------------------------------------------------------------
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF, TIMING OFF, SUMMARY OFF)
SELECT count(*)
FROM users_t u
JOIN invoices i ON i.user_id = u.id
WHERE u.id <= 50000;
-- Merge Join using pkey scan on users_t and index scan on invoices.
-- Compare: force hash to see the alternative the planner considered:
BEGIN;
SET LOCAL enable_mergejoin = off;
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF)
SELECT count(*)
FROM users_t u
JOIN invoices i ON i.user_id = u.id
WHERE u.id <= 50000;
ROLLBACK;
-- Close call — that's normal: hash and merge trade blows by data size and
-- memory. The planner picks by measured cost model, and it's usually right.

-- ---------------------------------------------------------------------------
-- 2. Merge shines when output must be sorted ANYWAY
-- ---------------------------------------------------------------------------
-- "Top 10 invoices by user id" — final ORDER BY makes the sort a sunk cost:
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF)
SELECT u.id, i.id AS invoice_id
FROM users_t u
JOIN invoices i ON i.user_id = u.id
ORDER BY u.id, i.id
LIMIT 10;
-- Merge join delivers pre-sorted rows; hash join would need an extra Sort
-- node of the WHOLE result before LIMIT 10 can fire.

-- ---------------------------------------------------------------------------
-- 3. Range joins — the thing ONLY merge can do efficiently
-- ---------------------------------------------------------------------------
-- "Pair each invoice with invoices of the SAME user that came LATER (id)"
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF)
SELECT count(*)
FROM invoices a
JOIN invoices b ON b.user_id = a.user_id AND b.id > a.id
WHERE a.user_id <= 1000;
-- Merge Join on (user_id, id) index order — the sorted inputs make the
-- inequality walkable. (Hash impossible: not equality. Nested Loop would
-- probe per row — fine too if the index exists; planner compares.)

-- ---------------------------------------------------------------------------
-- 4. The sort that precedes the merge — when inputs are NOT indexed
-- ---------------------------------------------------------------------------
BEGIN;
SET LOCAL enable_hashjoin = off;
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF, TIMING OFF, SUMMARY OFF)
SELECT count(*) FROM users_t u JOIN invoices i ON i.user_id = u.id;
ROLLBACK;
-- Two Sort nodes feed the Merge Join. Sorts can spill to temp (work_mem,
-- hash_join.sql section 2). If the planner wanted merge but your query has
-- no ORDER BY and data is unindexed, hash usually wins — that's healthy.

-- ---------------------------------------------------------------------------
-- Choosing between the three joins (the planner's actual decision):
--   Nested Loop : small outer + indexed inner + selective       -> OLTP
--   Hash Join   : big unsorted sides, equality, enough work_mem -> analytics
--   Merge Join  : inputs pre-sorted (indexes) or output must be
--                 sorted, or range join conditions
-- All three stay available; never disable two to "check" in production.
-- ============================================================================

-- TAKEAWAYS
-- * Merge = two sorted streams, lockstep pointers; O(n) after the sort.
-- * Pre-sorted inputs (indexes) make it the cheapest equality join.
-- * It's the only join with native range-condition support.
-- * If you see Sort -> Merge Join, ask whether an index could delete the Sort.

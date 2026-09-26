-- ============================================================================
-- 05-query-planning/nested_loop.sql — the join for (few x indexed) rows
-- ============================================================================
-- Run:  make sql FILE=05-query-planning/nested_loop.sql
--
-- Nested Loop Join:
--   for each row R in OUTER:
--       run INNER scan parameterized by R (index lookups!)
-- Complexity = outer_rows x inner_lookup_cost. It WINS when the outer side
-- is small AND the inner side has an index on the join/filter column — the
-- classic OLTP point-join (user -> their 5 orders).
--
-- Two support nodes you'll meet here:
--   Materialize  — buffers the inner side in memory when re-scanned
--   Memoize      — (PG14+) caches inner results by parameter value
-- ============================================================================

\set ON_ERROR_STOP on
\timing on
DROP SCHEMA IF EXISTS m05_nl CASCADE;
CREATE SCHEMA m05_nl;
SET search_path TO m05_nl, public;

CREATE TABLE users_t (
    id    bigint PRIMARY KEY,
    email text NOT NULL,
    country text NOT NULL
);
INSERT INTO users_t
SELECT g, 'u' || g || '@x.com', (ARRAY['US','DE','FR'])[1 + g % 3]
FROM generate_series(1, 100000) g;

CREATE TABLE orders (
    id          bigint PRIMARY KEY,
    user_id     bigint NOT NULL,
    total       numeric NOT NULL
);
INSERT INTO orders
SELECT g, 1 + (g::bigint * 7919) % 100000, (g % 500)::numeric
FROM generate_series(1, 400000) g;
CREATE INDEX orders_user_idx ON orders (user_id);   -- the join enabler
ANALYZE users_t;
ANALYZE orders;

-- ---------------------------------------------------------------------------
-- 1. The textbook shape: small outer, indexed inner
-- ---------------------------------------------------------------------------
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF, TIMING OFF, SUMMARY OFF)
SELECT u.id, u.email, o.total
FROM users_t u
JOIN orders o ON o.user_id = u.id
WHERE u.id <= 5;
-- -> Nested Loop; inner = Index Scan using orders_user_idx with loops=5.
-- "actual ... rows=4 loops=5" means each of 5 outer rows found ~4 matches.
-- Estimated inner rows come from pg_stats (avg rows per user_id).

-- Which side is outer matters: planner picks the SMALLER estimated side.
-- It even reorders your written join! Swap the FROM order — same plan.

-- ---------------------------------------------------------------------------
-- 2. loops=N — reading inner stats correctly
-- ---------------------------------------------------------------------------
-- Multiply: total inner time = actual time x loops; total rows = rows x loops.

-- ---------------------------------------------------------------------------
-- 3. Memoize — PG14+'s join-level cache, visible in the plan
-- ---------------------------------------------------------------------------
-- Skewed inner lookups (some users have many orders, queries repeat) can
-- reuse parameter results. Force visibility with a duplicated join key:
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF)
SELECT count(*) FROM users_t u
JOIN orders o ON o.user_id = u.id
WHERE u.id IN (1, 2, 1, 2, 1);
-- Watch for "Memoize (chunks=...)" — hits= vs misses=. When the same
-- parameter repeats across outer rows (correlated data), this is a big win.

-- ---------------------------------------------------------------------------
-- 4. When Nested Loop LOSES: unselective outer, unindexed inner
-- ---------------------------------------------------------------------------
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF)
SELECT count(*)
FROM users_t u
JOIN orders o ON o.user_id = u.id
WHERE u.country = 'US';                    -- ~33k outer rows!
-- Planner switches to Hash Join (next file). Force NL to see the disaster:
BEGIN;
SET LOCAL enable_hashjoin = off;
SET LOCAL enable_mergejoin = off;
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF)
SELECT count(*)
FROM users_t u
JOIN orders o ON o.user_id = u.id
WHERE u.country = 'US';
ROLLBACK;
-- 33k loops x index probes... compare Execution Time to the hash join. THIS
-- experiment is why "always use indexes" is naive: the JOIN ALGORITHM is a
-- decision the planner owns, and it needs BOTH algorithms available.

-- Missing inner index version — the real production killer:
DROP INDEX orders_user_idx;
ANALYZE orders;
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF)
SELECT u.id, o.total FROM users_t u
JOIN orders o ON o.user_id = u.id
WHERE u.id <= 5;
-- Nested Loop with a SEQ SCAN inner (loops=5): five full table scans of
-- orders! (Planner may still choose hash here; force with enable_hashjoin=
-- off to see the NL+seqscan pathology.) Restore the index and re-run:
CREATE INDEX orders_user_idx ON orders (user_id);
ANALYZE orders;

-- TAKEAWAYS
-- * NL = per-outer-row inner lookup; needs small outer + indexed inner.
-- * Read loops=N and multiply before judging an inner node.
-- * Materialize/Memoize buffer/cache the inner for rescans.
-- * The join order and algorithm are the planner's choice; your job is the
-- * indexes and the statistics it decides with.

-- ============================================================================
-- 05-query-planning/explain_analyze.sql — measured truth (+ BUFFERS)
-- ============================================================================
-- Run:  make demo  &&  make sql FILE=05-query-planning/explain_analyze.sql
--
-- EXPLAIN ANALYZE EXECUTES the query and replaces estimates with actuals:
--   actual time=0.05..12.30 rows=833 loops=1
--   rows=... (vs estimated rows) is the #1 clue for "planner guessed wrong".
--
-- WARNING: it really runs the statement — INSERT/UPDATE/DELETE inside it
-- are NOT undone. The standard trick: wrap DML in a rolled-back transaction.
--
-- BUFFERS shows cache/IO truth:
--   shared hit   = pages served from PostgreSQL's shared_buffers
--   shared read  = pages fetched from OS/page cache or disk
--   dirtied      = pages modified (writes)
--   temp         = work spilled to disk (sorts/hashes beyond work_mem)
-- ============================================================================

\set ON_ERROR_STOP on
\timing on
SET search_path TO demo, public;

-- ---------------------------------------------------------------------------
-- Estimate vs actual — the single most useful diagnostic comparison
-- ---------------------------------------------------------------------------
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF)
SELECT c.email, o.status
FROM customers c
JOIN orders o ON o.customer_id = c.id
WHERE c.country = 'DE'
ORDER BY o.placed_at
LIMIT 20;
-- Read: Hash Join rows=4166 (estimated vs actual — close here). When they
-- diverge 10x+, the plan's cost model is working on fiction:
-- planner_statistics.sql makes the planner honest with better statistics.

-- Buffers line on the seq scan: shared hit + read = pages actually touched.
--   hit=read=0 would be a query touching nothing; a query with 10,000
--   shared read and 0 hit just met cold cache — rerun and watch reads
--   turn into hits (page cache effects, not planner magic).

-- ---------------------------------------------------------------------------
-- DML under the microscope — safely, with ROLLBACK
-- ---------------------------------------------------------------------------
BEGIN;
EXPLAIN (ANALYZE, WAL, BUFFERS, COSTS OFF, TIMING OFF)
UPDATE orders SET status = 'paid' WHERE status = 'placed';
ROLLBACK;
-- Note: Rows Removed by Filter (rows scanned but not updated), WAL bytes
-- generated, Buffers dirtied. Rows Removed by Filter >> Rows Updated is a
-- hint that an index might help the write, too.

-- ---------------------------------------------------------------------------
-- TIMING OFF for expensive queries — measurement overhead is real
-- ---------------------------------------------------------------------------
-- Per-row timing calls distort queries touching millions of rows. Modern
-- practice (and what postgres auto_explain uses): TIMING OFF for totals:
EXPLAIN (ANALYZE, TIMING OFF, SUMMARY ON)
SELECT count(*) FROM order_items oi JOIN orders o ON o.id = oi.order_id;

-- ---------------------------------------------------------------------------
-- loops=N — the multiplier everyone misreads
-- ---------------------------------------------------------------------------
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF)
SELECT (SELECT count(*) FROM orders o WHERE o.customer_id = c.id) AS n
FROM customers c
WHERE c.id <= 3;
-- The subplan line shows "loops=3": actual rows is PER LOOP. Total rows
-- emitted = rows x loops. When someone says "actual rows=1 but the query
-- was slow", check loops.

-- ---------------------------------------------------------------------------
-- JIT — the involuntary "why is my plan huge" node
-- ---------------------------------------------------------------------------
-- For expensive queries (cost above jit_above_cost, default 100000) PG
-- JIT-compiles expressions. You'll see "JIT:" sections. It helps CPU-bound
-- analytical queries; it HURTS small OLTP queries (compile time). Test:
EXPLAIN (ANALYZE, TIMING OFF)
SELECT count(*), avg(price), max(price * 2), min(length(name))
FROM products p JOIN order_items oi ON oi.product_id = p.id
JOIN orders o ON o.id = oi.order_id
GROUP BY p.category;
SET LOCAL jit = off;   -- inside a tx
BEGIN; SET LOCAL jit = off;
EXPLAIN (ANALYZE, TIMING OFF)
SELECT count(*), avg(price), max(price * 2), min(length(name))
FROM products p JOIN order_items oi ON oi.product_id = p.id
JOIN orders o ON o.id = oi.order_id
GROUP BY p.category;
ROLLBACK;
-- Compare Execution Time. On small lab data JIT may not trigger; lowering
-- jit_above_cost=0 shows the difference dramatically.

-- ---------------------------------------------------------------------------
-- Plan formats — for tooling, not reading
-- ---------------------------------------------------------------------------
EXPLAIN (FORMAT JSON) SELECT 1;               -- machine-readable plan
-- pganalyze / explain.depesz.com / explain.dalibo.com consume these.

-- TAKEAWAYS
-- * ANALYZE executes — wrap DML in BEGIN/ROLLBACK.
-- * Buffers > timing for understanding; TIMING OFF for expensive queries.
-- * loops x rows: multiply before you judge a node.
-- * Estimate vs actual divergence = statistics problem = next file.

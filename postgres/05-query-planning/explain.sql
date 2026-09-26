-- ============================================================================
-- 05-query-planning/explain.sql — learning to read the plan tree
-- ============================================================================
-- Run:  make demo  &&  make sql FILE=05-query-planning/explain.sql
--
-- EXPLAIN shows the plan the planner WOULD run (no execution). The output is
-- a TREE: each node takes its children's output and produces rows. Read it
-- BOTTOM-UP (innermost node first = the first thing executed) and with the
-- mental model "rows flow up".
--
-- Node anatomy:
--   cost=0.00..35.50   (startup cost .. total cost)
--     * cost units are arbitrary "page fetches" — seq page read = 1.0
--     * startup: work before the FIRST row can be emitted (sorts: high)
--     * total:   cost of emitting EVERY row
--   rows=1000          the planner's ESTIMATE (see planner_statistics.sql)
--   width=64           estimated average bytes per output row
-- ============================================================================

\set ON_ERROR_STOP on
SET search_path TO demo, public;

-- A plan for a simple query, annotated below:
EXPLAIN
SELECT c.email, o.status
FROM customers c
JOIN orders o ON o.customer_id = c.id
WHERE c.country = 'DE'
ORDER BY o.placed_at
LIMIT 20;

-- Reading THAT output, bottom to top:
--  1. Seq Scan on customers  — filter country='DE' (~833 of 10,000 rows)
--  2. Hash Join              — probes customers-hash for each order row
--  3. Sort                   — materializes ALL matching rows (startup cost!)
--  4. Limit                  — trivial: stop after 20
-- Note how the Sort's high startup cost means nothing reaches Limit until
-- EVERYTHING is sorted. That's why ORDER BY+LIMIT loves indexes (no Sort).

-- ---------------------------------------------------------------------------
-- Node cheat sheet (each gets its own file in this module)
-- ---------------------------------------------------------------------------
-- Scan nodes:
--   Seq Scan on t             read every page of t, apply Filter
--   Index Scan using i on t   descend btree, then heap-fetch each hit
--   Index Only Scan           all columns from the index (needs visibility map)
--   Bitmap Heap/Index Scan    index builds a page bitmap, then heap-reads it
--   Values Scan / Function Scan / CTE Scan  — pseudo-tables
-- Join nodes:
--   Nested Loop   for each outer row: look up matches in inner (needs index)
--   Hash Join     build hash on smaller side, probe with the other
--   Merge Join    both inputs sorted; walk them in lockstep
-- Other:
--   Sort, Aggregate, GroupAggregate/HashAggregate, Unique, Limit, Gather
--   (parallelism), Materialize, Memoize

-- ---------------------------------------------------------------------------
-- Startup vs total cost, felt: WHERE does time go before row #1?
-- ---------------------------------------------------------------------------
EXPLAIN SELECT * FROM orders ORDER BY placed_at;          -- huge startup (Sort)
EXPLAIN SELECT * FROM orders WHERE id = 42;               -- tiny startup
-- For an API that streams "first 20 fast", startup cost is what you optimize.
-- For batch/ETL, total cost is what you optimize. They often conflict!

-- ---------------------------------------------------------------------------
-- Tree shape tells you the row flow; indentation = feeding relationship
-- ---------------------------------------------------------------------------
EXPLAIN
SELECT c.country, count(*), sum(oi.qty * oi.unit_price)
FROM customers c
JOIN orders o      ON o.customer_id = c.id
JOIN order_items oi ON oi.order_id = o.id
GROUP BY c.country
HAVING count(*) > 100;

-- ---------------------------------------------------------------------------
-- EXPLAIN options you'll actually use
-- ---------------------------------------------------------------------------
EXPLAIN (VERBOSE)     SELECT 1;                    -- full detail: target lists, schema-qualified
EXPLAIN (COSTS OFF)   SELECT 1;                    -- declutter when teaching
EXPLAIN (SETTINGS)   SELECT 1 FROM orders WHERE id = 1;
   -- shows non-default GUCs that affected the plan (work_mem etc.)!
-- WAL requires ANALYZE (it must EXECUTE the write to count bytes, so wrap
-- it in a transaction if you don't want it applied):
BEGIN;
EXPLAIN (ANALYZE, WAL, COSTS OFF, TIMING OFF)
INSERT INTO orders (customer_id, status, placed_at) VALUES (1, 'placed', now());
ROLLBACK;

-- Costs are COMPARATIVE, not milliseconds. Never say "cost 35 = 35ms". The
-- only truth is EXPLAIN ANALYZE (next file), and even that runs your query.

-- TAKEAWAYS
-- * Read plans bottom-up; rows flow from leaves to root.
-- * startup..total cost: streaming vs batch performance.
-- * rows= is the planner's GUESS — estimates are where bad plans are born.
-- * (SETTINGS) reveals hidden knobs that shaped a plan — remember it for
--   bug reports.

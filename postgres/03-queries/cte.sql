-- ============================================================================
-- 03-queries/cte.sql — WITH: readable pipelines, and the materialize gotcha
-- ============================================================================
-- Run:  make sql FILE=03-queries/cte.sql
--
-- CTEs name your query stages. The critical PostgreSQL-specific behavior
-- (since PG12): a CTE referenced once is INLINED into the outer query (like
-- a macro) unless you write WITH ... AS MATERIALIZED. Before PG12 all CTEs
-- were optimization fences — old advice still circulates.
-- ============================================================================

\set ON_ERROR_STOP on
\timing on
SET search_path TO demo, public;

-- ---------------------------------------------------------------------------
-- Step-by-step pipeline: top countries by revenue of DELIVERED orders
-- ---------------------------------------------------------------------------
WITH delivered AS (                       -- stage 1: filter early
    SELECT o.id, o.customer_id
    FROM orders o
    WHERE o.status = 'delivered'
),
revenue AS (                              -- stage 2: aggregate facts
    SELECT d.customer_id, sum(oi.qty * oi.unit_price) AS total
    FROM delivered d
    JOIN order_items oi ON oi.order_id = d.id
    GROUP BY d.customer_id
),
by_country AS (                           -- stage 3: join dimension LAST
    SELECT c.country, round(sum(r.total), 2) AS revenue,
           count(*) AS customers
    FROM revenue r
    JOIN customers c ON c.id = r.customer_id
    GROUP BY c.country
)
SELECT * FROM by_country ORDER BY revenue DESC LIMIT 5;

-- ---------------------------------------------------------------------------
-- INLINED vs MATERIALIZED — the knob you didn't know existed
-- ---------------------------------------------------------------------------
-- Default (PG12+): inline. The planner pushes the outer WHERE into the CTE
-- and can use indexes — usually what you want:
EXPLAIN (COSTS OFF)
WITH recent AS (SELECT * FROM orders WHERE placed_at > now() - interval '30 days')
SELECT count(*) FROM recent WHERE status = 'paid';

-- MATERIALIZED: compute once, store in a private buffer (temp structure),
-- reuse for each reference. Two reasons to force it:
--   1. the CTE is expensive AND referenced multiple times
--   2. you WANT fence semantics (e.g. prevent predicate pushdown, or snapshot
--      consistent behavior for volatile functions)
EXPLAIN (COSTS OFF)
WITH recent AS MATERIALIZED (SELECT * FROM orders WHERE placed_at > now() - interval '30 days')
SELECT count(*) FROM recent WHERE status = 'paid';
-- Notice the plan shape change: an actual CTE Scan node over computed data.

-- Multiple references force materialization automatically (still true in
-- modern versions): un-comment and read the plan:
-- EXPLAIN (COSTS OFF)
-- WITH recent AS (SELECT * FROM orders WHERE placed_at > now() - interval '30 days')
-- SELECT (SELECT count(*) FROM recent) AS n,
--        (SELECT count(*) FROM recent WHERE status = 'cancelled') AS n_cancelled;

-- ---------------------------------------------------------------------------
-- Data-modifying CTEs: atomic read-your-writes pipelines
-- ---------------------------------------------------------------------------
-- Archive cancelled orders older than 700 days, returning what moved —
-- INSERT, DELETE and the audit row all in ONE statement/transaction:
CREATE TABLE IF NOT EXISTS cancelled_archive (
    order_id bigint, customer_id bigint, archived_at timestamptz DEFAULT now()
);

WITH moved AS (
    DELETE FROM orders o
    WHERE o.status = 'cancelled' AND o.placed_at < now() - interval '700 days'
    RETURNING o.id, o.customer_id
)
INSERT INTO cancelled_archive (order_id, customer_id)
SELECT id, customer_id FROM moved
RETURNING order_id;

-- (The demo data has few such orders; the pattern is the point.)
SELECT count(*) AS archived_total FROM cancelled_archive;

-- ALL sub-statements of one data-modifying CTE see the SAME snapshot: you
-- cannot read another CTE's writes in weird orders — they apply atomically.

-- ---------------------------------------------------------------------------
-- Recursive CTEs: preview (recursive_cte.sql does them properly)
-- ---------------------------------------------------------------------------
WITH RECURSIVE numbers AS (
    SELECT 1 AS n
    UNION ALL
    SELECT n + 1 FROM numbers WHERE n < 5
)
SELECT array_agg(n ORDER BY n) AS first_five FROM numbers;

-- TAKEAWAYS
-- * CTEs = named stages; filter early, aggregate, join dimensions last.
-- * PG12+: single-referenced CTEs inline; MATERIALIZED restores the fence.
-- * Multiple references auto-materialize — expensive CTE + many references
--   is where the fence HELPS you.
-- * Data-modifying CTEs make ETL steps atomic with read-your-writes.

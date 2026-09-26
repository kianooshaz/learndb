-- ============================================================================
-- 03-queries/lateral.sql — LATERAL: a correlated join, on demand
-- ============================================================================
-- Run:  make demo  &&  make sql FILE=03-queries/lateral.sql
--
-- LATERAL lets a subquery in FROM reference columns from tables to its LEFT.
-- Think "for each outer row, run this inner query". It is PostgreSQL's
-- answer to CROSS APPLY, and it powers three everyday patterns:
--   1. top-N per group (indexed, no sorting everything)
--   2. per-row set-returning function calls
--   3. time-series expansion / gap analysis
-- ============================================================================

\set ON_ERROR_STOP on
\timing on
SET search_path TO demo, public;

-- First: the indexes we need for the honest comparison (04 explains them):
CREATE INDEX IF NOT EXISTS orders_customer_placed_idx
    ON demo.orders (customer_id, placed_at DESC);
CREATE INDEX IF NOT EXISTS products_category_price_idx
    ON demo.products (category, price DESC);

-- ---------------------------------------------------------------------------
-- Pattern 1: top-N per group, two ways
-- ---------------------------------------------------------------------------
-- Window approach: rank EVERY product, then filter:
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF)
WITH ranked AS (
    SELECT id, category, price,
           row_number() OVER (PARTITION BY category ORDER BY price DESC) AS rn
    FROM products
)
SELECT category, id, price FROM ranked WHERE rn <= 2 ORDER BY category;

-- LATERAL approach: for each category, walk the index and take 2:
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF)
SELECT c.category, top.id, top.price
FROM (SELECT DISTINCT category FROM products) c
CROSS JOIN LATERAL (
    SELECT id, price FROM products p
    WHERE p.category = c.category
    ORDER BY price DESC
    LIMIT 2
) top;
-- With an index on (category, price DESC) the LATERAL inner is an index scan
-- that stops after 2 rows. At 1,000 products both are fast; at 10M rows the
-- window version sorts millions of rows while LATERAL does k lookups per
-- group. Rule: small N per group + index + many groups -> LATERAL.

-- Same result, sanity check:
SELECT category, id, price FROM (
    SELECT id, category, price,
           row_number() OVER (PARTITION BY category ORDER BY price DESC) AS rn
    FROM products) r
WHERE rn <= 2 ORDER BY category, price DESC;

SELECT c.category, top.id, top.price
FROM (SELECT DISTINCT category FROM products) c
CROSS JOIN LATERAL (
    SELECT id, price FROM products p
    WHERE p.category = c.category
    ORDER BY price DESC LIMIT 2) top
ORDER BY 1, 3 DESC;

-- ---------------------------------------------------------------------------
-- Pattern 2: newest order per customer (the "latest row per X" problem)
-- ---------------------------------------------------------------------------
SELECT c.id, c.email, last_order.id AS last_order_id, last_order.placed_at
FROM customers c
LEFT JOIN LATERAL (
    SELECT o.id, o.placed_at
    FROM orders o
    WHERE o.customer_id = c.id
    ORDER BY o.placed_at DESC
    LIMIT 1
) last_order ON true            -- LEFT keeps customers with zero orders
WHERE c.id <= 5
ORDER BY c.id;
-- The index (customer_id, placed_at DESC) makes the inner a single index
-- lookup per customer. Compare with the alternatives you now know:
--   DISTINCT ON (customer_id) ... ORDER BY customer_id, placed_at DESC
--   row_number() OVER (PARTITION BY customer_id ...) + rn = 1
-- All three can win depending on data shape — that's why you measure.

-- ---------------------------------------------------------------------------
-- Pattern 3: expand each row into a series (time-series, schedules)
-- ---------------------------------------------------------------------------
-- "Every customer's first 3 order anniversaries":
SELECT c.id, c.created_at::date + (n || ' years')::interval AS anniversary
FROM customers c
CROSS JOIN LATERAL generate_series(1, 3) AS n
WHERE c.id <= 3
ORDER BY c.id, anniversary;

-- Per-row function calls also need LATERAL semantics; in the SELECT list
-- set-returning functions work but are implicit and order-fragile — explicit
-- LATERAL in FROM is the maintainable form:
SELECT c.id, s.even
FROM customers c
CROSS JOIN LATERAL unnest(ARRAY[c.id, c.id * 2]) AS s(even)
WHERE c.id <= 3;

-- ---------------------------------------------------------------------------
-- What LATERAL is NOT
-- ---------------------------------------------------------------------------
-- * It's not a JOIN replacement: plain joins express their condition once;
--   LATERAL re-plans per outer row (parameterized). Use it when the inner
--   truly depends on the outer row.
-- * Subqueries in FROM normally can't see sibling columns — LATERAL lifts
--   exactly that restriction:
SELECT o.id, x.total
FROM orders o
JOIN LATERAL (
    SELECT sum(qty * unit_price) AS total
    FROM order_items oi WHERE oi.order_id = o.id
) x ON true
WHERE o.id <= 3;
-- (For a bare scalar like this the planner treats it like a correlated
-- subquery — but LATERAL generalizes to multiple columns/rows.)

-- TAKEAWAYS
-- * LATERAL = per-outer-row inner query; CROSS JOIN LATERAL = at least one,
--   LEFT JOIN LATERAL ... ON true = zero or more.
-- * Top-N/latest-per-X with an index is where it shines at scale.
-- * Prefer it over set-returning functions loose in the SELECT list.

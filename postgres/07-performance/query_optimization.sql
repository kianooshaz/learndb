-- ============================================================================
-- 07-performance/query_optimization.sql — a slow query, diagnosed and fixed
-- ============================================================================
-- Run:  make sql FILE=07-performance/query_optimization.sql
--
-- The methodology (never skip a step):
--   1. Find the slow query      — pg_stat_statements (10-extensions)
--   2. Measure                 — EXPLAIN (ANALYZE, BUFFERS), not guesses
--   3. Find the most expensive NODE (bottom-up: biggest actual time)
--   4. Fix that node only       (index, rewrite, work_mem, schema)
--   5. RE-MEASURE               (and confirm estimates vs actual improved)
--
-- Here: a "top customers" report that looks harmless and is awful.
-- ============================================================================

\set ON_ERROR_STOP on
\timing on
DROP SCHEMA IF EXISTS m07_opt CASCADE;
CREATE SCHEMA m07_opt;
SET search_path TO m07_opt, public;

-- The scene: 500k orders, 1M items, NO indexes beyond the pkey.
CREATE TABLE customers (id int PRIMARY KEY, name text NOT NULL, country text NOT NULL);
CREATE TABLE orders (
    id int PRIMARY KEY, customer_id int NOT NULL, status text NOT NULL, placed_at timestamptz NOT NULL);
CREATE TABLE order_items (
    order_id int NOT NULL, product_id int NOT NULL, qty int NOT NULL, unit_price numeric NOT NULL,
    PRIMARY KEY (order_id, product_id));

INSERT INTO customers SELECT g, 'c' || g, (ARRAY['US','DE','FR'])[1 + g % 3] FROM generate_series(1, 20000) g;
INSERT INTO orders
SELECT g, 1 + (g::bigint * 7919) % 20000,
       (ARRAY['paid','shipped','delivered'])[1 + g % 3],
       now() - ((g % 500000) || ' minutes')::interval
FROM generate_series(1, 500000) g;
INSERT INTO order_items
SELECT o.id, 1 + (g * 13) % 1000, 1 + g % 3, (g % 400)::numeric
FROM orders o, generate_series(1, 2 + (o.id * 7) % 3) g;

-- (int overflow guard: o.id * 7 with 500k is fine.)

ANALYZE customers; ANALYZE orders; ANALYZE order_items;

-- ---------------------------------------------------------------------------
-- THE OFFENDER: everything a real "dashboard" query does wrong at once
-- ---------------------------------------------------------------------------
\timing on
-- (commented out to save you 10+ seconds; uncomment ONCE to feel the pain:
-- SELECT c.name,
--        (SELECT sum(oi.qty * oi.unit_price) FROM order_items oi
--          WHERE oi.order_id IN (SELECT id FROM orders o
--                                 WHERE o.customer_id = c.id AND o.status = 'paid')) AS paid_total
-- FROM customers c
-- WHERE c.country = 'US'
-- ORDER BY paid_total DESC NULLS LAST
-- LIMIT 10;
-- )
-- Crimes: correlated subquery per customer (N+1 in SQL!), IN-subquery per
-- order, sort over computed values, no supporting index anywhere.

-- ---------------------------------------------------------------------------
-- STEP 1-2: measure. First fix measurement hygiene: run inside the plan so
-- timing doesn't depend on result transfer.
-- ---------------------------------------------------------------------------
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF, TIMING OFF, SUMMARY OFF)
SELECT c.name,
       (SELECT sum(oi.qty * oi.unit_price) FROM order_items oi
         WHERE oi.order_id IN (SELECT id FROM orders o
                                WHERE o.customer_id = c.id AND o.status = 'paid')) AS paid_total
FROM customers c
WHERE c.country = 'US'
ORDER BY paid_total DESC NULLS LAST
LIMIT 10;
-- Read bottom-up: the SubPlan runs ONCE PER US CUSTOMER (~6600x!) each with
-- hashed subqueries over 500k orders. Loops multiply everything.

-- ---------------------------------------------------------------------------
-- STEP 3-4: fix the shape FIRST (joins over correlated subqueries), then
-- add what indexes the shape needs.
-- ---------------------------------------------------------------------------
-- Rewrite: aggregate ONCE, join dimensions after (03-queries/joins.sql
-- "aggregate before joining fan-out"):
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF, TIMING OFF, SUMMARY OFF)
WITH per_order AS (
    SELECT o.id, o.customer_id, sum(oi.qty * oi.unit_price) AS total
    FROM orders o
    JOIN order_items oi ON oi.order_id = o.id
    WHERE o.status = 'paid'
    GROUP BY o.id, o.customer_id
),
per_customer AS (
    SELECT customer_id, sum(total) AS paid_total
    FROM per_order GROUP BY customer_id
)
SELECT c.name, round(pc.paid_total, 2)
FROM per_customer pc
JOIN customers c ON c.id = pc.customer_id
WHERE c.country = 'US'
ORDER BY pc.paid_total DESC
LIMIT 10;

-- STEP 5: re-measure with \timing on. One pass over orders+items instead
-- of 6,600 passes. Typically 10-50x faster with ZERO schema changes.

-- Now indexes ON TOP of the good shape (only where the plan begs for them):
CREATE INDEX orders_customer_idx ON orders (customer_id, status);
ANALYZE orders;
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF, TIMING OFF, SUMMARY OFF)
WITH per_order AS (
    SELECT o.id, o.customer_id, sum(oi.qty * oi.unit_price) AS total
    FROM orders o
    JOIN order_items oi ON oi.order_id = o.id
    WHERE o.status = 'paid'
    GROUP BY o.id, o.customer_id
),
per_customer AS (
    SELECT customer_id, sum(total) AS paid_total
    FROM per_order GROUP BY customer_id
)
SELECT c.name, round(pc.paid_total, 2)
FROM per_customer pc
JOIN customers c ON c.id = pc.customer_id
WHERE c.country = 'US'
ORDER BY pc.paid_total DESC
LIMIT 10;
-- For THIS query the aggregate dominates, so the index adds little — measure
-- before assuming every query needs more indexes. THAT is the lesson of
-- index_optimization.sql: indexes earn their write cost, or they go.

-- TAKEAWAYS
-- * Measure, fix the biggest node, re-measure — never "add indexes" blind.
-- * Correlated subqueries = loops in SQL; joins+pre-aggregation fix them.
-- * Buffers/timing: one pass over the data beats 6,600 passes over an index.
-- * pg_stat_statements finds the offenders in production (10-extensions).

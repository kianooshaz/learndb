-- ============================================================================
-- 03-queries/subqueries.sql — scalar, correlated, EXISTS/IN/ANY/ALL
-- ============================================================================
-- Run:  make sql FILE=03-queries/subqueries.sql
--
-- Subqueries live in three places: WHERE/FROM/SELECT. Each slot has its own
-- semantics and performance profile — including the most dangerous silent
-- bug in SQL: NOT IN over a nullable column.
-- ============================================================================

\set ON_ERROR_STOP on
\timing on
SET search_path TO demo, public;

-- ---------------------------------------------------------------------------
-- Scalar subquery (returns one row/col) — fine when it runs ONCE:
-- ---------------------------------------------------------------------------
SELECT id, sku, price,
       (SELECT round(avg(price), 2) FROM products) AS catalog_avg,
       round(price - (SELECT avg(price) FROM products), 2) AS vs_avg
FROM products
ORDER BY id LIMIT 5;

-- Correlated version (references the outer row; re-evaluated per row — the
-- "N+1 in SQL" if you're careless; compare its plan below):
SELECT id, sku, price,
       (SELECT round(avg(price), 2) FROM products p2 WHERE p2.category = p1.category)
           AS category_avg
FROM products p1
ORDER BY id LIMIT 5;

-- ---------------------------------------------------------------------------
-- IN vs EXISTS vs JOIN — three spellings, three plans
-- ---------------------------------------------------------------------------
-- Question: customers with at least one cancelled order.

-- IN (subquery): planner often rewrites to a semi-join anyway:
SELECT count(*) FROM customers c
WHERE c.id IN (SELECT customer_id FROM orders WHERE status = 'cancelled');

-- EXISTS (correlated): my default for semantics ("a matching row EXISTS") —
-- it stops at the FIRST match, and NULLs in the subquery can't poison it:
SELECT count(*) FROM customers c
WHERE EXISTS (SELECT 1 FROM orders o WHERE o.customer_id = c.id AND o.status = 'cancelled');

-- JOIN + DISTINCT: works, but forces dedup work the semi-joins avoid:
SELECT count(DISTINCT c.id) FROM customers c
JOIN orders o ON o.customer_id = c.id AND o.status = 'cancelled';

-- Compare plans: the two semi-joins (IN / EXISTS) usually plan identically
-- here; the JOIN+DISTINCT adds a dedup node:
EXPLAIN (COSTS OFF) SELECT count(*) FROM customers c
WHERE EXISTS (SELECT 1 FROM orders o WHERE o.customer_id = c.id AND o.status = 'cancelled');

EXPLAIN (COSTS OFF) SELECT count(DISTINCT c.id) FROM customers c
JOIN orders o ON o.customer_id = c.id AND o.status = 'cancelled';

-- ---------------------------------------------------------------------------
-- THE BUG: NOT IN with NULLs
-- ---------------------------------------------------------------------------
-- NOT IN returns NO ROWS if the subquery yields even one NULL — because
-- x NOT IN (1, 2, NULL) evaluates to NULL, never TRUE (see 02/boolean.sql).
-- Simulate by nulling one customer_id copy in a derived table:
CREATE TEMP TABLE bad_orders AS SELECT customer_id FROM orders LIMIT 100;
UPDATE bad_orders SET customer_id = NULL WHERE customer_id = 1;

SELECT count(*) AS matching_not_in FROM customers c
WHERE c.id NOT IN (SELECT customer_id FROM bad_orders);   -- ~0 rows: poisoned

SELECT count(*) AS matching_not_exists FROM customers c
WHERE NOT EXISTS (SELECT 1 FROM bad_orders b WHERE b.customer_id = c.id); -- correct

-- Guard if you must keep NOT IN:  ... WHERE key NOT IN (SELECT x FROM t
-- WHERE x IS NOT NULL). Better: write NOT EXISTS and move on.

-- ---------------------------------------------------------------------------
-- ANY / ALL / arrays as sets
-- ---------------------------------------------------------------------------
-- = ANY(array): membership; cleaner than OR chains AND it can use indexes:
SELECT id, sku, category FROM products
WHERE category = ANY(ARRAY['audio','gaming'])
ORDER BY id LIMIT 5;

-- <> ALL: "differs from every element" = NOT IN minus the NULL trap risk
-- from literals; > ALL = greater than the max of the set:
SELECT count(*) FROM products
WHERE price > ALL (SELECT price FROM products WHERE category = 'office');

-- ---------------------------------------------------------------------------
-- Derived tables (subquery in FROM) — always alias; they're your "stages"
-- ---------------------------------------------------------------------------
SELECT country, avg(n_orders) AS avg_orders_per_customer
FROM (
    SELECT c.country, c.id, count(o.id) AS n_orders
    FROM customers c
    LEFT JOIN orders o ON o.customer_id = c.id
    GROUP BY c.country, c.id
) per_customer
GROUP BY country
ORDER BY 2 DESC;

-- TAKEAWAYS
-- * EXISTS/NOT EXISTS: first-match semantics, NULL-proof — the default.
-- * NOT IN over nullable columns is a silent data-loss bug.
-- * Correlated scalar subqueries run per outer row; check the plan before
--   shipping one (LATERAL — lateral.sql — is often the better tool).
-- * = ANY(array) beats OR chains and stays index-friendly.

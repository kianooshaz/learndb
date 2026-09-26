-- ============================================================================
-- 03-queries/joins.sql — every JOIN shape, and the bugs they cause
-- ============================================================================
-- Run:   make demo   (once, if you haven't)
--        make sql FILE=03-queries/joins.sql
--
-- Join fundamentals the plans depend on:
--   * INNER JOIN keeps matching pairs; LEFT/RIGHT keep unmatched rows from
--     one side padded with NULLs; FULL keeps both; CROSS is a flat product.
--   * WHERE applies AFTER the join; ON conditions shape the join itself.
--     Filtering the outer side of a LEFT JOIN in WHERE silently converts it
--     back to an INNER join — a classic silent bug.
-- ============================================================================

\set ON_ERROR_STOP on
\timing on
SET search_path TO demo, public;

-- ---------------------------------------------------------------------------
-- INNER: revenue per product (join fan-out: each item row is one fact)
-- ---------------------------------------------------------------------------
SELECT p.category,
       sum(oi.qty * oi.unit_price) AS revenue
FROM order_items oi
JOIN products p ON p.id = oi.product_id
GROUP BY p.category
ORDER BY revenue DESC
LIMIT 5;

-- ---------------------------------------------------------------------------
-- LEFT JOIN + WHERE on the right side = accidental INNER JOIN
-- ---------------------------------------------------------------------------
-- Intended: ALL products, with sold_copies = 0 for unsold ones.
-- Buggy version — the WHERE kicks out the NULL-extended rows:
SELECT p.id, count(oi.order_id) AS sold_buggy
FROM products p
LEFT JOIN order_items oi ON oi.product_id = p.id
WHERE p.category = 'audio'
GROUP BY p.id
ORDER BY sold_buggy DESC
LIMIT 3;

-- Correct version: put the right-side filter in the ON clause (or skip it —
-- the join key already constrains oi):
SELECT p.id,
       count(oi.order_id) FILTER (WHERE oi.order_id IS NOT NULL) AS sold,
       count(oi.order_id) AS same_thing_count_skips_nulls
FROM products p
LEFT JOIN order_items oi ON oi.product_id = p.id AND p.category = 'audio'
WHERE p.category = 'audio'
GROUP BY p.id
ORDER BY p.id LIMIT 3;
-- Note: count(col) skips NULLs — with LEFT JOIN prefer explicit FILTER, and
-- NEVER use count(*) on the join result when you mean "matching rows".

-- Products that have NEVER been ordered (anti-join; see subqueries.sql for
-- NOT EXISTS / NOT IN variants):
SELECT p.id, p.sku
FROM products p
LEFT JOIN order_items oi ON oi.product_id = p.id
WHERE oi.order_id IS NULL
ORDER BY p.id LIMIT 5;

-- ---------------------------------------------------------------------------
-- RIGHT / FULL: same machinery, different preserved side
-- ---------------------------------------------------------------------------
-- RIGHT JOIN is just LEFT with sides swapped — always rewrite for readability:
SELECT count(*) AS customers_with_orders
FROM orders o RIGHT JOIN customers c ON c.id = o.customer_id;

-- FULL JOIN: row-level reconciliation report — customers without orders AND
-- orders without customers (the latter should be 0: FK guarantees it):
SELECT count(*) FILTER (WHERE c.id IS NULL) AS orphan_orders,
       count(*) FILTER (WHERE o.id IS NULL) AS customers_never_ordered
FROM customers c
FULL JOIN orders o ON o.customer_id = c.id;

-- ---------------------------------------------------------------------------
-- CROSS JOIN + aggregation: counting pairs (brush up on your combinatorics)
-- ---------------------------------------------------------------------------
SELECT count(*) AS pro_customers_times_audio_products
FROM customers c
CROSS JOIN (SELECT id FROM products WHERE category = 'audio') p
WHERE c.is_pro;

-- CROSS JOIN of a table with itself needs aliases — self-join for "customers
-- from the same country who registered in the same month":
SELECT a.id AS customer_a, b.id AS customer_b, a.country
FROM customers a
JOIN customers b
  ON a.country = b.country
 AND date_trunc('month', a.created_at) = date_trunc('month', b.created_at)
 AND a.id < b.id                       -- a < b: unordered pairs, no self-matches
LIMIT 5;

-- ---------------------------------------------------------------------------
-- THE classic reporting bug: fan-out double counting
-- ---------------------------------------------------------------------------
-- Question: total revenue and order count per customer, in one query.
-- WRONG: joining orders (to count) AND items (to sum) multiplies each item
-- by the number of items in its order:
SELECT c.id,
       count(DISTINCT o.id)                                    AS orders_wrong_way_to_fix,
       sum(oi.qty * oi.unit_price) * count(DISTINCT o.id) / count(*) AS revenue_inflated
FROM customers c
JOIN orders o ON o.customer_id = c.id
JOIN order_items oi ON oi.order_id = o.id
WHERE c.id <= 3
GROUP BY c.id
ORDER BY c.id;

-- RIGHT: aggregate each fan-out level BEFORE joining (subqueries/CTEs —
-- cte.sql formalizes this pattern):
WITH per_order AS (
    SELECT order_id, sum(qty * unit_price) AS order_total
    FROM order_items GROUP BY order_id
),
per_customer AS (
    SELECT o.customer_id, count(*) AS n_orders, sum(t.order_total) AS revenue
    FROM orders o JOIN per_order t ON t.order_id = o.id
    GROUP BY o.customer_id
)
SELECT c.id, pc.n_orders, round(pc.revenue, 2) AS revenue
FROM customers c JOIN per_customer pc ON pc.customer_id = c.id
WHERE c.id <= 3
ORDER BY c.id;

-- ---------------------------------------------------------------------------
-- Join performance reality check (read the plans; 05 explains node by node)
-- ---------------------------------------------------------------------------
EXPLAIN (COSTS OFF)
SELECT c.email, o.status
FROM customers c JOIN orders o ON o.customer_id = c.id
WHERE c.country = 'DE';
-- There is no index on orders.customer_id yet -> Hash Join with Seq Scan on
-- orders. Re-run this after 04-indexes/multicolumn_indexes.sql creates one
-- and watch it flip to a Nested Loop with an Index Scan — same result,
-- different plan, and that flip is the planner doing its job.

-- TAKEAWAYS
-- * ON shapes the join; WHERE filters the RESULT. Right-side predicates on
--   a LEFT JOIN belong in ON.
-- * Anti-join: LEFT JOIN + IS NULL, or NOT EXISTS (prefer the latter).
-- * Aggregate before joining fan-out tables, or your sums inflate.
-- * Join order is the PLANNER's choice, not yours — SQL is declarative.

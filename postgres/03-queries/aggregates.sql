-- ============================================================================
-- 03-queries/aggregates.sql — GROUP BY, HAVING, FILTER, GROUPING SETS
-- ============================================================================
-- Run:  make demo  &&  make sql FILE=03-queries/aggregates.sql
--
-- Aggregation pipeline order matters:
--   FROM -> WHERE -> GROUP BY -> HAVING -> SELECT -> ORDER BY -> LIMIT
-- WHERE filters ROWS before grouping; HAVING filters GROUPS after. Aggregates
-- in WHERE are illegal; that's what HAVING exists for.
-- ============================================================================

\set ON_ERROR_STOP on
\timing on
SET search_path TO demo, public;

-- ---------------------------------------------------------------------------
-- The workhorse: dimensions + measures
-- ---------------------------------------------------------------------------
SELECT c.country,
       count(*)                       AS orders,
       count(DISTINCT o.customer_id)  AS customers,
       round(avg(items.n_items), 2)  AS avg_items_per_order
FROM orders o
JOIN customers c ON c.id = o.customer_id
JOIN LATERAL (
    SELECT count(*) AS n_items FROM order_items oi WHERE oi.order_id = o.id
) items ON true
GROUP BY c.country
ORDER BY orders DESC LIMIT 6;

-- count(*) vs count(col) vs count(distinct col):
SELECT count(*)                    AS rows_all,        -- counts row versions
       count(customer_id)          AS rows_non_null,   -- skips NULLs
       count(DISTINCT customer_id) AS distinct_customers
FROM orders;

-- Exact count(*) on big tables reads everything (no free row counter —
-- MVCC makes one impossible). For estimates, use planner stats:
SELECT reltuples::bigint AS approx_rows FROM pg_class WHERE relname = 'orders';

-- ---------------------------------------------------------------------------
-- HAVING vs WHERE — filter groups, not rows
-- ---------------------------------------------------------------------------
-- "Countries whose average order value exceeds 300":
SELECT c.country, round(sum(i.total), 2) AS revenue
FROM orders o
JOIN customers c ON c.id = o.customer_id
JOIN LATERAL (SELECT sum(qty * unit_price) AS total FROM order_items oi WHERE oi.order_id = o.id) i ON true
GROUP BY c.country
HAVING sum(i.total) / count(*) > 300     -- aggregate condition -> HAVING
ORDER BY revenue DESC;

-- Same query with a row filter moved to WHERE (different question!):
-- WHERE o.placed_at > now() - interval '90 days'   -- filters BEFORE grouping

-- ---------------------------------------------------------------------------
-- FILTER — conditional aggregation, better than CASE-inside-sum
-- ---------------------------------------------------------------------------
-- One scan, many measures, pivoted by condition:
SELECT c.country,
       count(*) FILTER (WHERE o.status = 'delivered')        AS delivered,
       count(*) FILTER (WHERE o.status = 'cancelled')        AS cancelled,
       count(*) FILTER (WHERE o.status = 'placed')           AS placed,
       round(100.0 * count(*) FILTER (WHERE o.status = 'cancelled')
             / count(*), 1)                                  AS cancel_rate_pct
FROM orders o
JOIN customers c ON c.id = o.customer_id
GROUP BY c.country
ORDER BY cancel_rate_pct DESC LIMIT 6;
-- The pre-FILTER idiom still works and is 100% equivalent:
--   sum(CASE WHEN status='cancelled' THEN 1 ELSE 0 END)
-- FILTER reads better and plans identically.

-- ---------------------------------------------------------------------------
-- GROUPING SETS / ROLLUP / CUBE — many groupings in ONE scan
-- ---------------------------------------------------------------------------
-- ROLLUP(a, b): (a,b), (a), () — subtotals up a hierarchy:
SELECT coalesce(c.country, 'ALL')   AS country,
       coalesce(o.status, 'ALL')    AS status,
       count(*)                     AS orders
FROM orders o JOIN customers c ON c.id = o.customer_id
GROUP BY ROLLUP (c.country, o.status)
HAVING c.country IS NULL OR c.country IN ('US','DE')
ORDER BY 1, 2 LIMIT 12;
-- grouping() tells you which columns are NULL-because-of-rollup vs real NULLs.

-- CUBE(a, b): every combination — (a,b), (a), (b), ():
SELECT coalesce(c.country, 'ALL') AS country,
       coalesce(p.category, 'ALL') AS category,
       count(*) AS items
FROM order_items oi
JOIN orders o    ON o.id = oi.order_id
JOIN customers c ON c.id = o.customer_id
JOIN products p  ON p.id = oi.product_id
GROUP BY CUBE (c.country, p.category)
ORDER BY 1, 2 LIMIT 10;

-- Arbitrary subsets: GROUPING SETS ((a), (b), (a,b)) — pick exactly what you
-- need. Why care: one table scan instead of three UNIONed queries.

-- ---------------------------------------------------------------------------
-- Aggregating INTO structures — jsonb_agg / array_agg / string_agg
-- ---------------------------------------------------------------------------
-- Building an API response shape directly in SQL:
SELECT c.id,
       jsonb_build_object(
           'email', c.email,
           'recent_orders',
           coalesce(jsonb_agg(jsonb_build_object(
               'id', o.id, 'status', o.status
           ) ORDER BY o.placed_at DESC) FILTER (WHERE o.id IS NOT NULL), '[]'::jsonb)
       ) AS customer_doc
FROM customers c
LEFT JOIN LATERAL (
    SELECT id, status, placed_at FROM orders
    WHERE customer_id = c.id ORDER BY placed_at DESC LIMIT 3
) o ON true
WHERE c.id <= 2
GROUP BY c.id, c.email
ORDER BY c.id;
-- Note the FILTER (WHERE o.id IS NOT NULL) on LEFT JOIN: without it,
-- customers with zero orders get a one-element array containing NULLs.

SELECT string_agg(DISTINCT category, ', ' ORDER BY category) AS categories
FROM products;

-- TAKEAWAYS
-- * Pipeline order: WHERE before grouping, HAVING after. Aggregate in
--   WHERE = syntax error.
-- * FILTER > CASE-in-sum for conditional measures.
-- * ROLLUP/CUBE/GROUPING SETS = multi-level reports in one scan.
-- * jsonb_agg + FILTER builds nested API payloads without N+1 app queries.

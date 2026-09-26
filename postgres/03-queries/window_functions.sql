-- ============================================================================
-- 03-queries/window_functions.sql — analytics without collapsing rows
-- ============================================================================
-- Run:  make demo  &&  make sql FILE=03-queries/window_functions.sql
--
-- The mental model: a window function computes one value PER ROW over a
-- window of rows defined by OVER (...). Unlike GROUP BY, rows are NOT
-- collapsed — you keep detail AND add aggregates beside it.
--
--   row_number()  1,2,3,4          — positional, no ties
--   rank()        1,2,2,4          — ties share rank, gaps after
--   dense_rank()  1,2,2,3          — ties share rank, no gaps
-- ============================================================================

\set ON_ERROR_STOP on
\timing on
SET search_path TO demo, public;

-- ---------------------------------------------------------------------------
-- The three ranks, side by side (products by price within category)
-- ---------------------------------------------------------------------------
SELECT id, category, price,
       row_number() OVER w AS row_num,
       rank()       OVER w AS rnk,
       dense_rank() OVER w AS drnk
FROM products
WHERE category IN ('audio','office')
WINDOW w AS (PARTITION BY category ORDER BY price DESC)   -- named window reuse
ORDER BY category, row_num LIMIT 12;

-- ---------------------------------------------------------------------------
-- Running totals and deltas — frames in action
-- ---------------------------------------------------------------------------
-- Daily revenue over the last 30 days, with running total and day-over-day
-- change. ORDER BY inside OVER defines "so far"; the default frame is
-- RANGE BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW.
WITH daily AS (
    SELECT date_trunc('day', placed_at)::date AS day,
           sum(total) AS revenue
    FROM (
        SELECT o.placed_at, sum(oi.qty * oi.unit_price) AS total
        FROM orders o JOIN order_items oi ON oi.order_id = o.id
        GROUP BY o.id, o.placed_at
    ) per_order
    GROUP BY 1
)
SELECT day, revenue,
       sum(revenue) OVER (ORDER BY day)                    AS running_total,
       revenue - lag(revenue, 1) OVER (ORDER BY day)       AS delta_vs_yesterday,
       avg(revenue) OVER (ORDER BY day ROWS BETWEEN 6 PRECEDING AND CURRENT ROW)
                                                            AS rolling_7day_avg
FROM daily
ORDER BY day DESC LIMIT 8;
-- Frame cheat sheet:
--   ROWS  6 PRECEDING  -> exactly the last 6 physical rows
--   RANGE 6 PRECEDING  -> rows within a VALUE distance (peers included!)
--   GROUPS             -> peer groups (PG11+)

-- lag/lead gotcha: first row's lag() is NULL — coalesce it:
SELECT day, coalesce(lag(day) OVER (ORDER BY day), day) AS prev_day_fill
FROM (SELECT DISTINCT date_trunc('week', placed_at)::date AS day FROM orders) weeks
ORDER BY day LIMIT 4;

-- first_value/last_value trap: with the default frame (ending CURRENT ROW),
-- last_value is just... the current row. You almost always want the full frame
-- (and note: a named window can be EXTENDED with a frame, but its PARTITION BY
-- and ORDER BY are immutable — re-specify inline when they differ):
SELECT DISTINCT day,
       first_value(revenue) OVER (ORDER BY day) AS first_in_window,
       last_value(revenue)  OVER (ORDER BY day ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING) AS true_last
FROM (SELECT date_trunc('day', placed_at)::date AS day, count(*) AS revenue FROM orders GROUP BY 1) d
ORDER BY day LIMIT 4;

-- ---------------------------------------------------------------------------
-- Top-N per group — the pattern you'll ship weekly
-- ---------------------------------------------------------------------------
-- "3 most expensive products per category". Window version:
WITH ranked AS (
    SELECT id, category, name, price,
           row_number() OVER (PARTITION BY category ORDER BY price DESC) AS rn
    FROM products
)
SELECT category, id, name, price FROM ranked
WHERE rn <= 3
ORDER BY category, price DESC;
-- (lateral.sql shows the LATERAL alternative and when the planner prefers it.)
-- NOTE: PostgreSQL has no QUALIFY clause (Snowflake/Teradata). The subquery/
-- CTE + outer WHERE is the idiomatic workaround — you CANNOT put window
-- functions in WHERE directly: "window functions are not allowed in WHERE".

-- ntile: bucket rows into quartiles for pricing analysis. NOTE: you cannot
-- GROUP BY a window function's result ("window functions are not allowed in
-- GROUP BY") — compute the window in an inner stage, aggregate in the outer:
WITH quartiled AS (
    SELECT ntile(4) OVER (ORDER BY price) AS q, price FROM products
)
SELECT q AS price_quartile,
       round(min(price), 2) AS quartile_floor,
       round(max(price), 2) AS quartile_ceiling,
       count(*) AS products
FROM quartiled
GROUP BY q ORDER BY q;

-- percent_cont: continuous percentile without buckets (returns double, and
-- there is no round(double, int) overload — cast to numeric first):
SELECT round(percentile_cont(0.9) WITHIN GROUP (ORDER BY price)::numeric, 2) AS p90_price
FROM products;

-- ---------------------------------------------------------------------------
-- Window functions vs GROUP BY — same data, different row granularity
-- ---------------------------------------------------------------------------
-- GROUP BY collapses: one row per customer:
SELECT customer_id, count(*) FROM orders GROUP BY customer_id ORDER BY 1 LIMIT 3;
-- Window keeps rows and annotates: every order knows its customer's volume:
SELECT id, customer_id,
       count(*) OVER (PARTITION BY customer_id) AS customer_order_volume
FROM orders
ORDER BY customer_id, id LIMIT 6;

-- TAKEAWAYS
-- * OVER (PARTITION BY ... ORDER BY ... frame) — partition slices, order
--   defines "so far", frame defines the exact row set.
-- * row_number/rank/dense_rank differ only on ties; pick deliberately.
-- * Top-N per group = row_number + outer WHERE (no QUALIFY in PG).
-- * last_value needs an explicit full frame or it lies.

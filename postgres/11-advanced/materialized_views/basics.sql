-- ============================================================================
-- 11-advanced/materialized_views/basics.sql — cached aggregates, refreshed
-- ============================================================================
-- Run:  make demo  &&  make sql FILE=11-advanced/materialized_views/basics.sql
--
-- A materialized view is a QUERY'S RESULT stored as a real table:
--   view            = stored QUERY      (fresh every read, zero storage)
--   matview         = stored RESULT     (fast reads, manual/explicit refresh)
-- The price: staleness. REFRESH rebuilds everything (locking) unless
-- CONCURRENTLY (needs a unique index), and even then it's row-diffing, not
-- incremental in the strict sense.
-- ============================================================================

\set ON_ERROR_STOP on
\timing on
SET search_path TO demo, public;

DROP MATERIALIZED VIEW IF EXISTS mv_daily_revenue;

-- An expensive report: daily revenue by country (joins + aggregates):
CREATE MATERIALIZED VIEW mv_daily_revenue AS
SELECT date_trunc('day', o.placed_at)::date AS day,
       c.country,
       count(*)                AS orders,
       sum(oi.qty * oi.unit_price) AS revenue
FROM orders o
JOIN customers c    ON c.id = o.customer_id
JOIN order_items oi ON oi.order_id = o.id
GROUP BY 1, 2;
-- Building it costs the full query (watch \timing on the CREATE).

CREATE UNIQUE INDEX mv_daily_revenue_uq ON mv_daily_revenue (day, country);
-- ^ two jobs: lookup speed AND the entry ticket for REFRESH CONCURRENTLY.

-- Reads are table reads — instant regardless of source-query cost:
\timing on
SELECT day, country, round(revenue, 2) AS revenue
FROM mv_daily_revenue
WHERE country = 'US' ORDER BY day DESC, revenue DESC LIMIT 3;

-- Staleness demo: new orders land in the TABLES, not the matview:
INSERT INTO orders (customer_id, status, placed_at)
SELECT customer_id, 'paid', placed_at FROM orders LIMIT 1000;   -- 1000 more orders
-- (their items don't exist -> revenue shift is on the count axis here)

SELECT count(*) AS matview_rows FROM mv_daily_revenue;          -- unchanged

-- ---------------------------------------------------------------------------
-- REFRESH: plain (locked) vs CONCURRENTLY (readers never blocked)
-- ---------------------------------------------------------------------------
-- Plain REFRESH: ACCESS EXCLUSIVE on the matview; readers WAIT; fastest
-- total rebuild:
\timing on
REFRESH MATERIALIZED VIEW mv_daily_revenue;

-- CONCURRENTLY: diff old vs new and swap — readers keep reading; requires
-- the unique index; slower overall, zero downtime:
REFRESH MATERIALIZED VIEW CONCURRENTLY mv_daily_revenue;

SELECT count(*) AS refreshed FROM mv_daily_revenue;

-- ---------------------------------------------------------------------------
-- Choosing: view vs matview vs table vs precomputed column
-- ---------------------------------------------------------------------------
--  * plain view: query readability, always fresh, pays the query every read
--  * matview: expensive aggregates read often / source changes slowly
--  * incremental needs (real-time) -> summary TABLES maintained by triggers
--    (11-advanced/triggers/) or by the application in the same transaction
--  * matview refresh scheduling: pg_cron, app cron, or REFRESH after ETL
--    loads complete — pick one owner, never two
--
-- Gotchas worth knowing:
--  * REFRESH CONCURRENTLY still needs to EVALUATE the whole query (it just
--    avoids blocking reads while swapping the diff).
--  * matviews have no automatic invalidation. Nothing tells you they're
--    stale — monitor refresh lag yourself.
--  * You can index matviews (we did) — that's often the real speed win.
-- ============================================================================

DROP MATERIALIZED VIEW IF EXISTS mv_daily_revenue;

-- TAKEAWAYS
-- * Matview = persisted query result; fresh ONLY when you refresh.
-- * Unique index unlocks REFRESH CONCURRENTLY (non-blocking).
-- * Real-time numbers need triggers/summary tables, not matviews.
-- * Index the matview for read patterns exactly like a table.

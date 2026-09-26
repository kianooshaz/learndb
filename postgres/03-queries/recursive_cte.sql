-- ============================================================================
-- 03-queries/recursive_cte.sql — trees and graphs in vanilla SQL
-- ============================================================================
-- Run:  make sql FILE=03-queries/recursive_cte.sql
--
-- A recursive CTE is a worklist algorithm:
--   1. UNION the non-recursive "anchor" into the working table;
--   2. run the recursive term against rows not yet emitted;
--   3. repeat until the working table is empty.
-- Every iteration is one pass; loops in DATA will loop the query forever
-- unless you guard with a path/visited array.
-- ============================================================================

\set ON_ERROR_STOP on
\timing on
DROP SCHEMA IF EXISTS m03_rec CASCADE;
CREATE SCHEMA m03_rec;
SET search_path TO m03_rec, public;

-- A realistic org chart (employee -> manager):
CREATE TABLE employees (
    id        int PRIMARY KEY,
    name      text NOT NULL,
    manager_id int REFERENCES employees (id)
);
INSERT INTO employees VALUES
    (1, 'Ada',     NULL),          -- CEO
    (2, 'Grace',   1),
    (3, 'Linus',   1),
    (4, 'Barbara', 2),
    (5, 'Alan',    2),
    (6, 'Edsger',  3),
    (7, 'Margaret', 4),
    (8, 'Donald',  7);

-- ---------------------------------------------------------------------------
-- Top-down traversal: everyone under Grace, with depth and reporting path
-- ---------------------------------------------------------------------------
WITH RECURSIVE org AS (
    -- anchor: start at Grace
    SELECT id, name, manager_id, 1 AS depth, ARRAY[name] AS path
    FROM employees WHERE id = 2

    UNION ALL

    -- recursive step: direct reports of anyone found so far
    SELECT e.id, e.name, e.manager_id, o.depth + 1, o.path || e.name
    FROM employees e
    JOIN org o ON e.manager_id = o.id
)
SELECT * FROM org ORDER BY depth, id;

-- ---------------------------------------------------------------------------
-- Bottom-up: Donald's whole management chain
-- ---------------------------------------------------------------------------
WITH RECURSIVE chain AS (
    SELECT id, name, manager_id FROM employees WHERE id = 8
    UNION ALL
    SELECT e.id, e.name, e.manager_id
    FROM employees e
    JOIN chain c ON e.id = c.manager_id      -- walk UP: join on the parent
)
SELECT string_agg(name, ' -> ') AS escalation_path FROM chain;

-- Aggregate per subtree: headcount under every manager (fan out from each
-- manager, then count where they landed):
WITH RECURSIVE subtree AS (
    SELECT id AS root, id AS emp FROM employees
    UNION ALL
    SELECT s.root, e.id
    FROM subtree s JOIN employees e ON e.manager_id = s.emp
)
SELECT root,
       (SELECT name FROM employees WHERE id = root) AS manager,
       count(*) - 1 AS direct_and_indirect_reports
FROM subtree
GROUP BY root
ORDER BY 3 DESC;

-- ---------------------------------------------------------------------------
-- Graph with a CYCLE — the guard you must never forget
-- ---------------------------------------------------------------------------
CREATE TABLE follows (follower int, followee int);
INSERT INTO follows VALUES (1,2),(2,3),(3,1),(3,4);   -- 1 -> 2 -> 3 -> 1 cycle!

-- Unguarded: infinite loop (kill it with Ctrl-C / statement_timeout):
--   WITH RECURSIVE walk AS (
--       SELECT 1 AS node, ARRAY[1] AS visited
--       UNION ALL
--       SELECT f.followee, w.visited || f.followee
--       FROM walk w JOIN follows f ON f.follower = w.node
--   ) SELECT DISTINCT node FROM walk;

-- Guarded: only extend the path when the node is new:
WITH RECURSIVE walk AS (
    SELECT 1 AS node, ARRAY[1] AS visited
    UNION ALL
    SELECT f.followee, w.visited || f.followee
    FROM walk w JOIN follows f ON f.follower = w.node
    WHERE NOT f.followee = ANY(w.visited)      -- cycle breaker
)
SELECT DISTINCT node FROM walk ORDER BY node;
-- (UNION ALL + array guard is explicit; plain UNION dedups and would also
-- terminate here, but silently changes semantics for repeated nodes.)

-- ---------------------------------------------------------------------------
-- Generating series / sequencing — recursion as a query-time loop
-- ---------------------------------------------------------------------------
-- The first 10 Fibonacci numbers:
WITH RECURSIVE fib AS (
    SELECT 0 AS a, 1 AS b, 1 AS n
    UNION ALL
    SELECT b, a + b, n + 1 FROM fib WHERE n < 10
)
SELECT a AS fib FROM fib;

-- A date spine to LEFT JOIN against for gap-free reports (very common):
WITH RECURSIVE days AS (
    SELECT date_trunc('day', now())::date AS d
    UNION ALL
    SELECT d + 1 FROM days WHERE d < date_trunc('day', now())::date + 6
)
SELECT d FROM days ORDER BY d;

-- TAKEAWAYS
-- * Anchor + recursive term + UNION [ALL]; each pass sees only NEW rows.
-- * Carry a path array (or use UNION's dedup) on cyclical data.
-- * Trees: join child->parent to go up, parent->child to go down.
-- * CTEs can't reference themselves EXCEPT in the recursive term once.

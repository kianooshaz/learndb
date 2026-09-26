-- ============================================================================
-- 11-advanced/recursive_queries/deep.sql — beyond trees: graphs and gaps
-- ============================================================================
-- Run:  make sql FILE=11-advanced/recursive_queries/deep.sql
--
-- 03-queries/recursive_cte.sql covered the mechanics (anchor/step/cycles).
-- This file builds the PATTERNS you'll reuse in real systems:
--   1. bill-of-materials explosion (tree aggregation with quantities)
--   2. shortest path in a graph (BFS via recursion depth)
--   3. calendar/gap-filling for honest charts
-- ============================================================================

\set ON_ERROR_STOP on
\timing on
DROP SCHEMA IF EXISTS m11_rec CASCADE;
CREATE SCHEMA m11_rec;
SET search_path TO m11_rec, public;

-- ---------------------------------------------------------------------------
-- 1. Bill of materials: explode assemblies into leaf parts with quantities
-- ---------------------------------------------------------------------------
CREATE TABLE bom (
    assembly text NOT NULL,
    part     text NOT NULL,
    qty      numeric NOT NULL CHECK (qty > 0),
    PRIMARY KEY (assembly, part)
);
INSERT INTO bom VALUES
    ('bike',  'frame', 1),
    ('bike',  'wheel_pack', 1),
    ('bike',  'pedal', 2),
    ('wheel_pack', 'wheel', 2),
    ('wheel_pack', 'axle', 1),
    ('wheel', 'rim', 1),
    ('wheel', 'spokes', 1);

-- Walk the tree MULTIPLYING quantities along the path:
WITH RECURSIVE explode AS (
    SELECT part, qty, ARRAY[part] AS path
    FROM bom WHERE assembly = 'bike'
    UNION ALL
    SELECT b.part, e.qty * b.qty, e.path || b.part
    FROM bom b JOIN explode e ON b.assembly = e.part
)
SELECT part,
       (CASE WHEN EXISTS (SELECT 1 FROM bom x WHERE x.assembly = explode.part)
             THEN 'subassembly' ELSE 'leaf' END) AS kind,
       qty, path
FROM explode
ORDER BY qty DESC;

-- Reading it: one bike = 1 frame, 2 pedals, 2 wheels (via wheel_pack),
-- each wheel = rim + spokes, 1 axle per pack — quantities MULTIPLY down
-- the tree. GROUP BY part in an outer query would give shopping totals.

-- ---------------------------------------------------------------------------
-- 2. Shortest path (fewest hops) — BFS by depth
-- ---------------------------------------------------------------------------
CREATE TABLE edges (a int, b int);
INSERT INTO edges VALUES (1,2),(2,3),(3,4),(1,5),(5,4),(2,6),(6,4);

WITH RECURSIVE walk AS (
    SELECT 1 AS node, 1::int AS depth, ARRAY[1] AS visited
    UNION ALL
    SELECT e.b, w.depth + 1, w.visited || e.b
    FROM walk w JOIN edges e ON e.a = w.node
    WHERE NOT e.b = ANY(w.visited)          -- cycle guard (03/recursion)
)
SELECT visited AS shortest_path, depth - 1 AS hops
FROM walk
WHERE node = 4
ORDER BY depth                              -- BFS: first arrival = shortest
LIMIT 1;
-- 1->5->4 (2 hops) beats 1->2->3->4 (3 hops). ORDER BY depth + LIMIT = BFS.

-- ---------------------------------------------------------------------------
-- 3. Gap-filling: generate a series, LEFT JOIN reality onto it
-- ---------------------------------------------------------------------------
-- Charts need zeros for empty days; recursive series is the spine (works on
-- any version; generate_series does too — recursion shows the technique
-- for custom sequences like fiscal periods):
WITH RECURSIVE hours AS (
    SELECT 0 AS h
    UNION ALL
    SELECT h + 1 FROM hours WHERE h < 23
)
SELECT h, coalesce(n, 0) AS orders_per_hour
FROM hours
LEFT JOIN (
    SELECT extract(hour FROM placed_at)::int AS h, count(*) AS n
    FROM demo.orders
    WHERE placed_at > now() - interval '7 days'
    GROUP BY 1
) real USING (h)
ORDER BY h LIMIT 24;

-- Anti-pattern warning: recursive CTEs can't use their recursive term more
-- than once, can't aggregate over their own recursion mid-flight (aggregate
-- in an OUTER query), and every iteration is a fresh worktable — for
-- heavy graph algorithms, do it in Go (or an extension), not SQL.

-- TAKEAWAYS
-- * Carry arrays through recursion for paths AND cycle safety.
-- * Multiply/accumulate along the walk (qty * parent qty).
-- * ORDER BY depth LIMIT 1 = BFS shortest path.
-- * LEFT JOIN a generated spine to chart honest zeros.

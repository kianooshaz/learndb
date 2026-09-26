-- ============================================================================
-- 03-queries/set_operations.sql — UNION / INTERSECT / EXCEPT and dedup costs
-- ============================================================================
-- Run:  make demo  &&  make sql FILE=03-queries/set_operations.sql
--
-- Set operations combine ROW SETS, not tables: column count/types must
-- match positionally (names don't matter). The ALL suffix means "skip the
-- dedup step" — usually what you want for both semantics AND speed.
-- ============================================================================

\set ON_ERROR_STOP on
\timing on
SET search_path TO demo, public;

-- ---------------------------------------------------------------------------
-- UNION vs UNION ALL — the dedup tax, visible in the plan
-- ---------------------------------------------------------------------------
-- Question: which customer ids appear in orders OR have email at example.com
-- (trivially all, but the shape matters). UNION dedups:
EXPLAIN (COSTS OFF)
SELECT customer_id FROM orders WHERE status = 'cancelled'
UNION
SELECT customer_id FROM orders WHERE status = 'placed';

-- UNION ALL keeps duplicates and skips the dedup machinery:
EXPLAIN (COSTS OFF)
SELECT customer_id FROM orders WHERE status = 'cancelled'
UNION ALL
SELECT customer_id FROM orders WHERE status = 'placed';
-- The UNION plan has an extra HashAggregate (or Sort+Unique) node — real CPU
-- and memory on large inputs. Rule: if inputs are disjoint by construction
-- (or duplicates are acceptable/meaningful), write UNION ALL.

-- ---------------------------------------------------------------------------
-- INTERSECT / EXCEPT — including their rarely needed ALL forms
-- ---------------------------------------------------------------------------
-- Customers who ordered in BOTH statuses:
SELECT customer_id FROM orders WHERE status = 'shipped'
INTERSECT
SELECT customer_id FROM orders WHERE status = 'delivered'
ORDER BY 1 LIMIT 5;

-- EXCEPT = row-level set difference; the poor-man's data-diff tool:
-- rows in the left query that do not appear AT ALL in the right one.
SELECT customer_id FROM orders WHERE status = 'placed'
EXCEPT
SELECT customer_id FROM orders WHERE status = 'cancelled'
ORDER BY 1 LIMIT 5;

-- Table-diff pattern for QA / migrations (compare whole rows as composites):
-- Every (id, email) in customers that also exists in a copy... and any that
-- don't. On real tables you diff key + columns you care about:
CREATE TEMP TABLE customers_copy (LIKE customers INCLUDING ALL);
-- INCLUDING ALL copies the GENERATED ALWAYS identity, so we must explicitly
-- override it to copy ids verbatim (a real technique for snapshotting tables):
INSERT INTO customers_copy OVERRIDING SYSTEM VALUE SELECT * FROM customers;
UPDATE customers_copy SET email = 'changed@x.com' WHERE id = 1;
DELETE FROM customers_copy WHERE id = 2;

-- Rows only in the original (deleted or key-changed in the copy):
SELECT c.id FROM customers c
EXCEPT
SELECT cc.id FROM customers_copy cc
ORDER BY 1;
-- Rows differing in value: join on key and compare row composites:
SELECT c.id
FROM customers c JOIN customers_copy cc ON cc.id = c.id
WHERE ROW(c.email, c.name) IS DISTINCT FROM ROW(cc.email, cc.name)
ORDER BY 1;
-- ROW(...) IS DISTINCT FROM = NULL-safe full-row comparison
-- (02-data-types/composite_types.sql).

-- ---------------------------------------------------------------------------
-- Semantics details that bite
-- ---------------------------------------------------------------------------
-- 1) Duplicate rows within one input SURVIVE UNION ALL, are collapsed by
--    plain UNION/INTERSECT/EXCEPT:
SELECT * FROM (VALUES (1),(1),(2)) v(a)
UNION ALL
SELECT * FROM (VALUES (2),(3)) w(b)
ORDER BY 1;

-- 2) INTERSECT/EXCEPT bind TIGHTER than UNION: A UNION B EXCEPT C parses as
-- A UNION (B EXCEPT C). Parenthesize your intent:
(SELECT * FROM (VALUES (1),(2)) v(a)
 EXCEPT
 SELECT * FROM (VALUES (2)) w(b))
UNION ALL
SELECT * FROM (VALUES (3),(4)) x(c)
ORDER BY 1;

-- 3) ORDER BY/LIMIT apply to the WHOLE compound — per-branch sort needs
--    parentheses (like the query above).

-- 4) Column NAMES come from the FIRST branch; types are resolved across
--    branches (unknown literals get coerced):
SELECT 1 AS id, 'a' AS tag
UNION ALL
SELECT 2, 'b';

-- When NOT to use set operations: joining on a key gives you MORE power
-- (carrying extra columns, outer joins for anti-sets). Set ops shine for
-- literal set math on identical projections and quick diffs.

-- TAKEAWAYS
-- * UNION ALL by default; plain UNION only when dedup is the point.
-- * EXCEPT + ROW(...) IS DISTINCT FROM = table diff in pure SQL.
-- * Precedence: INTERSECT/EXCEPT > UNION — parenthesize compound queries.
-- * ORDER BY without parens scopes to the entire result.

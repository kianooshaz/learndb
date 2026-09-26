-- ============================================================================
-- 02-data-types/composite_types.sql — row values as first-class types
-- ============================================================================
-- Run:  make sql FILE=02-data-types/composite_types.sql
--
-- A composite type is a named (field1 type1, ...) row shape. Two reasons a
-- backend engineer should know them: (1) functions can return rows cleanly;
-- (2) ROW-value COMPARISON syntax powers correct keyset pagination.
-- ============================================================================

\set ON_ERROR_STOP on
DROP SCHEMA IF EXISTS m02_composite CASCADE;
CREATE SCHEMA m02_composite;
SET search_path TO m02_composite;

CREATE TYPE money_amount AS (currency char(3), value numeric(12,2));

CREATE TABLE payments (
    id     bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    amount money_amount NOT NULL
);
INSERT INTO payments (amount) VALUES
    ('(EUR,19.99)'), ('(USD,25.00)'), ('(USD,9.99)');

-- Field access with parentheses around the value:
SELECT (amount).currency, (amount).value FROM payments ORDER BY 1, 2;
-- And the literal form for inserts (note the quoting of the whole literal).

-- ---------------------------------------------------------------------------
-- Row-value comparison — the syntax nobody taught you
-- ---------------------------------------------------------------------------
-- (a, b) > (x, y) compares FIELD BY FIELD with left-to-right fallback:
-- true when a > x, or a = x AND b > y. This is lexicographic tuple order —
-- exactly what keyset pagination needs (03-queries/window_functions.sql and
-- 07-performance compare OFFSET vs keyset):
SELECT (5, 'b') > (5, 'a')  AS true_because_second_field,
       (5, 'a') > (5, 'b')  AS false,
       (4, 'z') > (5, 'a')  AS false_first_field_wins;

-- Keyset pagination in one honest WHERE clause ("after this row, in this
-- order") — the composite version is the readable/explicit form:
SELECT * FROM payments
WHERE (id) > (2)
ORDER BY id
LIMIT 2;

-- Composite types in functions (used heavily in 11-advanced/functions/):
CREATE TYPE order_line AS (sku text, qty int, unit numeric(10,2));
CREATE FUNCTION line_total(l order_line) RETURNS numeric LANGUAGE sql AS
$$ SELECT l.qty * l.unit $$;
SELECT line_total('(SKU-1, 3, 9.50)') AS total;

-- Every table implicitly has a composite type with the same name — you can
-- write function signatures against real row shapes:
CREATE FUNCTION payment_audit(p payments) RETURNS text LANGUAGE sql AS
$$ SELECT format('%s %s', (p.amount).value, (p.amount).currency) $$;
SELECT payment_audit(payments) FROM payments WHERE id = 1;

-- Caveats: composite columns (like our amount) can't be indexed directly or
-- compared with = without constructing row values; ALTER TYPE ... ADD
-- COLUMN works but changing field types is restrictive. Most teams prefer
-- generated columns/jsonb or plain columns; composites shine in function
-- signatures and ROW-comparison syntax, not as table columns.

-- TAKEAWAYS
-- * Composite types = named row shapes; tables double as types.
-- * (a,b) > (x,y) is lexicographic — the correct primitive for keyset
--   pagination (and unlike a > x OR (a = x AND b > y), the planner can use
--   an index on (a,b)).
-- * Great for function args/returns; rarely the right table column type.

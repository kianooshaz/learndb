-- ============================================================================
-- 11-advanced/generated_columns/basics.sql — computed columns, server-side
-- ============================================================================
-- Run:  make sql FILE=11-advanced/generated_columns/basics.sql
--
-- A STORED generated column = an IMMUTABLE expression over other columns,
-- computed by the server on write and physically stored. You can't write it
-- directly; the server maintains it forever. (PostgreSQL has no VIRTUAL
-- generated columns — unlike MySQL/Oracle; everything is stored.)
--
-- The killer use: promote hot jsonb/range fields into real, indexable,
-- typed columns with NO dual-write drift (09-json/jsonb_performance.sql).
-- ============================================================================

\set ON_ERROR_STOP on
\timing on
DROP SCHEMA IF EXISTS m11_gen CASCADE;
CREATE SCHEMA m11_gen;
SET search_path TO m11_gen, public;

CREATE TABLE products (
    id      bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name    text NOT NULL,
    price   numeric(10,2) NOT NULL,
    qty     int NOT NULL,
    attrs   jsonb NOT NULL,
    -- generated columns — note the parentheses and the IMMUTABLE rule:
    total   numeric(12,2) GENERATED ALWAYS AS (price * qty) STORED,
    color   text          GENERATED ALWAYS AS (attrs ->> 'color') STORED,
    weight_kg numeric     GENERATED ALWAYS AS (((attrs ->> 'weight_g')::numeric) / 1000) STORED
);

INSERT INTO products (name, price, qty, attrs) VALUES
 ('Keyboard', 99.00, 3, '{"color":"black","weight_g":1200}'),
 ('Mouse',    49.50, 0, '{"color":"silver","weight_g":95}');

SELECT name, total, color, weight_kg FROM products;

-- Writing them directly is an error (even with the "right" value):
\set ON_ERROR_STOP off
INSERT INTO products (name, price, qty, attrs, total) VALUES ('X', 1, 1, '{}', 1);
--   ERROR: cannot insert a non-DEFAULT value into column "total"
\set ON_ERROR_STOP on

-- They update when their inputs update — automatically:
UPDATE products SET qty = 10 WHERE name = 'Mouse';
SELECT name, qty, total FROM products ORDER BY name;

-- And they're fully indexable + analyzable like any column:
CREATE INDEX products_color_idx ON products (color);
ANALYZE products;
EXPLAIN (COSTS OFF) SELECT * FROM products WHERE color = 'black';

-- ---------------------------------------------------------------------------
-- The IMMUTABLE contract
-- ---------------------------------------------------------------------------
-- The expression must be immutable — no now(), no timezone conversions,
-- no subqueries, no other-table lookups. The value must be derivable from
-- THE ROW alone, forever:
--   ALTER TABLE products ADD COLUMN bad timestamptz
--       GENERATED ALWAYS AS (now()) STORED;
--   ERROR: generation expression is not immutable
-- This is the same contract as expression indexes (04-indexes), for the
-- same reason: stored derived data must never silently expire.

-- ---------------------------------------------------------------------------
-- Generated columns vs the alternatives
-- ---------------------------------------------------------------------------
--   expression INDEX (04) : index-only, no readable column in SELECT *
--   generated COLUMN      : real typed column everywhere + indexable
--   VIEW over expression  : recomputed per read (fine for cheap math,
--                           bad for jsonb extraction at scale)
--   app-computed column   : dual-write drift risk — exactly what generated
--                           columns eliminate
-- Constraints can reference generated columns too:
ALTER TABLE products ADD CONSTRAINT no_negative_stock CHECK (total >= 0);

-- Partitioning tie-in (11-advanced/partitioning): you cannot partition BY a
-- generated column directly (partition keys want raw columns), but you CAN
-- generate the raw input and partition on it via expression tricks — or
-- simply partition on the underlying column.

-- TAKEAWAYS
-- * STORED only; IMMUTABLE expression; write-through is forbidden.
-- * Perfect bridge: jsonb doc -> typed, indexed, normal columns.
-- * CHECK constraints can use them; no virtual variant in PG.
-- * Maintained on every write of their inputs — factor that into hot-path
--   UPDATE costs like any indexed column.

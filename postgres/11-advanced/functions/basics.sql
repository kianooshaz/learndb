-- ============================================================================
-- 11-advanced/functions/basics.sql — server functions and VOLATILITY
-- ============================================================================
-- Run:  make sql FILE=11-advanced/functions/basics.sql
--
-- Function volatility is the most consequential three-way switch in SQL:
--   IMMUTABLE   same input -> same output FOREVER (no clock, no tables).
--               Indexable, foldable at plan time, usable in generated cols.
--   STABLE      same input -> same output WITHIN A STATEMENT (reads tables,
--               now() qualifies). Safe in WHERE for the statement's snapshot.
--   VOLATILE    anything else (writes, random, sequence nexts).
-- Mislabeling is a data-corruption bug: an IMMUTABLE function reading a
-- table gets FROZEN into indexes/plan-time constants while the table moves.
-- ============================================================================

\set ON_ERROR_STOP on
\timing on
DROP SCHEMA IF EXISTS m11_fn CASCADE;
CREATE SCHEMA m11_fn;
SET search_path TO m11_fn, public;

CREATE TABLE prices (id int PRIMARY KEY, cents int NOT NULL);
INSERT INTO prices VALUES (1, 1999), (2, 500);

-- ---------------------------------------------------------------------------
-- 1. SQL functions: inlinable, fastest, for pure expressions
-- ---------------------------------------------------------------------------
CREATE FUNCTION price_display(cents int) RETURNS text
LANGUAGE sql IMMUTABLE
RETURN '$' || round(cents / 100.0, 2)::text;     -- SQL-standard body (PG14+)

SELECT price_display(1999);
SELECT price_display(cents) FROM prices;
-- Simple sql-language functions INLINE into the calling query — no function
-- call node at all in the plan (compare EXPLAIN with a plpgsql version).

-- ---------------------------------------------------------------------------
-- 2. plpgsql functions: procedural logic, loops, multiple statements
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION apply_discount(pct numeric)
RETURNS numeric LANGUAGE plpgsql STABLE AS $$
DECLARE
    factor numeric := 1 - pct / 100.0;
BEGIN
    IF pct < 0 OR pct > 100 THEN
        RAISE EXCEPTION 'discount must be 0..100, got %', pct
            USING ERRCODE = 'check_violation';   -- custom-raised SQLSTATE
    END IF;
    RETURN factor;
END $$;

SELECT round(apply_discount(20) * cents / 100.0, 2) AS discounted FROM prices;

-- ---------------------------------------------------------------------------
-- 3. Set-returning functions (SRFs): table functions
-- ---------------------------------------------------------------------------
CREATE FUNCTION top_prices(n int)
RETURNS TABLE (id int, cents int)     -- OUT params define the row shape
LANGUAGE sql STABLE AS $$
    SELECT id, cents FROM prices ORDER BY cents DESC LIMIT n
$$;

SELECT * FROM top_prices(1);

-- RETURN QUERY in plpgsql for imperative generation:
CREATE FUNCTION series_demo(n int) RETURNS SETOF int
LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN
    FOR i IN 1..n LOOP
        RETURN NEXT i;                -- emit one row per iteration
    END LOOP;
END $$;
SELECT series_demo(3);

-- ---------------------------------------------------------------------------
-- 4. Volatility, demonstrated — the exception subtransaction trap
-- ---------------------------------------------------------------------------
-- EXCEPTION blocks in plpgsql create SUBTRANSACTIONS: they ROLL BACK work
-- done inside the block. That makes EXCEPTION-handling loops SLOW (and the
-- function VOLATILE-compatible). Pattern vs alternative:
CREATE OR REPLACE FUNCTION safe_div(a numeric, b numeric)
RETURNS numeric LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN
    RETURN a / b;
EXCEPTION WHEN division_by_zero THEN
    RETURN NULL;
END $$;

SELECT safe_div(10, 2) AS ok, safe_div(10, 0) AS zero_gives_null;
-- Faster equivalent with no subtransaction — guard instead of catching:
CREATE OR REPLACE FUNCTION safe_div2(a numeric, b numeric)
RETURNS numeric LANGUAGE sql IMMUTABLE
RETURN CASE WHEN b = 0 THEN NULL ELSE a / b END;

\timing on
SELECT sum(safe_div(g, g % 7))  FROM generate_series(1, 50000) g;  -- exception path
SELECT sum(safe_div2(g, g % 7)) FROM generate_series(1, 50000) g;  -- guard path
-- Both correct; compare the timings psql prints — guards scale, handlers don't.

-- ---------------------------------------------------------------------------
-- 5. THE MISLABELING BUG (why you're learning this)
-- ---------------------------------------------------------------------------
-- Suppose this "immutable" function reads a table:
CREATE FUNCTION broken_lookup(id int) RETURNS int
LANGUAGE sql IMMUTABLE AS $$ SELECT cents FROM m11_fn.prices WHERE id = $1 $$;

CREATE TABLE order_refs (id int PRIMARY KEY, price_id int NOT NULL);
INSERT INTO order_refs SELECT g, 1 + g % 2 FROM generate_series(1, 1000) g;

-- Index the REFERENCING table (indexing prices with a scan of prices itself
-- is a pathological build we avoid here):
CREATE INDEX broken_idx ON order_refs ((broken_lookup(price_id)));
SELECT count(*) AS matches_1999 FROM order_refs WHERE broken_lookup(price_id) = 1999;

-- Now the underlying data changes... but IMMUTABLE promised it never would:
UPDATE m11_fn.prices SET cents = 1 WHERE id = 1;
SELECT count(*) AS still_returns_frozen_1999
FROM order_refs WHERE broken_lookup(price_id) = 1999;
-- The index STILL answers with the OLD value — real, silent data corruption.
DROP INDEX broken_idx;
DROP FUNCTION broken_lookup;
DROP TABLE order_refs;
-- Rule: reads tables -> STABLE (or VOLATILE); never IMMUTABLE.

-- Functions vs procedures (next file): functions RETURN values and can't
-- COMMIT; procedures orchestrate multi-step work with their OWN transaction
-- control. Functions = expressions; procedures = jobs.

-- TAKEAWAYS
-- * Volatility first, code second: IMMUTABLE/STABLE/VOLATILE semantics.
-- * sql-language functions inline; plpgsql does control flow.
-- * EXCEPTION blocks = subtransactions = per-invocation overhead.
-- * IMMUTABLE + table reads = corrupted indexes. Label honestly.

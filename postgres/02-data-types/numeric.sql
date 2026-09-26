-- ============================================================================
-- 02-data-types/numeric.sql — integers, numeric, floats: exact vs fast
-- ============================================================================
-- Run:  make sql FILE=02-data-types/numeric.sql
--
-- The one rule with no exceptions:
--   MONEY (and anything needing exact decimals — billing, tax, quantities
--   like 0.1 BTC) -> numeric. Floats CANNOT represent 0.1 exactly, and the
--   error compounds. Everything else measurable (ratios, temperatures,
--   scores) -> integer or double precision.
-- ============================================================================

\set ON_ERROR_STOP on
DROP SCHEMA IF EXISTS m02_numeric CASCADE;
CREATE SCHEMA m02_numeric;
SET search_path TO m02_numeric;

-- ---------------------------------------------------------------------------
-- Integer family: storage and ranges (from pg_type catalog — true sizes)
-- ---------------------------------------------------------------------------
SELECT typname, typlen AS bytes_on_disk
FROM pg_type
WHERE typname IN ('int2','int4','int8','numeric','float4','float8')
ORDER BY typlen, typname;
-- smallint 2B ±32,767 | integer 4B ±2.1B | bigint 8B ±9.2e18
-- float4 4B ~6 digits | float8 8B ~15 digits | numeric variable

-- Overflow is a hard ERROR, not a wraparound (unlike C). This protects data
-- but means your IDs must be bigint if growth is plausible:
--   SELECT 2147483647::integer + 1;
--   ERROR: integer out of range

-- Integer division truncates (deliberate, standard):
SELECT 7 / 2 AS int_div, 7::numeric / 2 AS exact_div, 7 / 2.0 AS float_div;

-- ---------------------------------------------------------------------------
-- Floats: fast, approximate — watch what that means
-- ---------------------------------------------------------------------------
SELECT 0.1::float8 + 0.2::float8 AS float_sum,
       0.1::float8 + 0.2::float8 = 0.3::float8 AS equals_three_tenths;
-- false! 0.1 and 0.2 have no exact binary fraction. Never compare floats
-- with = ; use a tolerance: abs(a - b) < 1e-9.

-- Float overflow: arithmetic that exceeds float8 range is an ERROR (not a
-- silent Infinity):   SELECT 1e308::float8 * 10;
--   ERROR: value out of range: overflow
-- Infinity exists as a VALUE you can store and compare:
SELECT 'Infinity'::float8 AS pos_inf, '-Infinity'::float8 AS neg_inf,
       'NaN'::float8, 'NaN'::float8 = 'NaN' AS nan_equals_nan;
-- (yes: floats violate normal equality semantics — NaN = NaN is TRUE —
-- another reason to keep them out of keys and constraints)

-- ---------------------------------------------------------------------------
-- numeric: exact decimal, variable length, slower
-- ---------------------------------------------------------------------------
SELECT 0.1::numeric + 0.2::numeric AS exact_sum,
       0.1::numeric + 0.2::numeric = 0.3::numeric AS exact_equals;

-- numeric(precision, scale): at most p digits, s after the decimal point.
CREATE TABLE invoices (
    id       bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    gross    numeric(12,2) NOT NULL,          -- up to 9,999,999,999.99
    tax_rate numeric(5,4)  NOT NULL           -- 0.2000 = 20%
);
INSERT INTO invoices (gross, tax_rate) VALUES (9999999999.99, 0.0725);

-- Input beyond precision/scale -> ERROR (not rounding):
--   INSERT INTO invoices (gross, tax_rate) VALUES (10000000000.00, 0.1);
--   ERROR: numeric field overflow
-- Computed results ARE rounded to the column scale on store:
INSERT INTO invoices (gross, tax_rate) VALUES (10.00, 0.333333);
SELECT gross, tax_rate, round(gross * tax_rate, 2) AS tax FROM invoices ORDER BY id;

-- scale=0 integer-like numeric:
SELECT 42::numeric(5,0) + 0.5 AS rounds_to_42_and_a_half_stored_as_43;

-- Performance: numeric is software-implemented decimal arithmetic (exact,
-- arbitrary precision); float8 uses the CPU's FPU. Typically 5-20x slower
-- per operation and wider on disk/indices. Irrelevant for a row here and
-- there; measurable in hot loops (see 07-performance/benchmarks).

-- The money type: avoid. It's a legacy locale-dependent fixed-point type;
-- output format changes with the server's lc_monetary setting. Use numeric.

-- ---------------------------------------------------------------------------
-- Realistic pattern: store cents as bigint? or numeric?
-- ---------------------------------------------------------------------------
-- Two defensible options:
--   A) amount_cents bigint        — exact, fast, but every API boundary must
--      convert; breaks the moment you need 0.5-cent precision.
--   B) amount numeric(12,2)       — exact, self-documenting, fine speed for
--      OLTP volumes. This lab uses B.
-- Never: float for currency. Ever.

-- TAKEAWAYS
-- * integer overflow raises; choose bigint for ids and anything growing.
-- * float8: ~15 significant digits, binary fractions, NaN=NaN — approximate.
-- * numeric(p,s): exact decimal, strict input bounds, slower and fatter.
-- * Currency -> numeric (or integer cents). Scores/ratios -> float8 is fine.

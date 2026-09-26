-- ============================================================================
-- 04-indexes/expression_indexes.sql — index computed values
-- ============================================================================
-- Run:  make sql FILE=04-indexes/expression_indexes.sql
--
-- If your WHERE/ORDER BY applies a FUNCTION to a column, a plain index is
-- useless (it's sorted by raw values). An expression index stores and sorts
-- the FUNCTION'S RESULT. Rules:
--   * the function must be IMMUTABLE (same input -> same output, forever —
--     no clock, locale, or table lookups inside);
--   * queries must use the EXACT same expression to match;
--   * the expression is recomputed on every INSERT/UPDATE of the column —
--     you pay CPU at write time to save it at read time.
-- ============================================================================

\set ON_ERROR_STOP on
\timing on
DROP SCHEMA IF EXISTS m04_expr CASCADE;
CREATE SCHEMA m04_expr;
SET search_path TO m04_expr, public;

CREATE TABLE users_t (
    id    bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    email text NOT NULL,
    data  jsonb NOT NULL
);
INSERT INTO users_t (email, data)
SELECT 'User' || g || '@Example.COM',
       jsonb_build_object('country', (ARRAY['US','DE','FR'])[1 + g % 3], 'age', 18 + g % 60)
FROM generate_series(1, 500000) g;

-- Case-insensitive email lookup — the wrong way first:
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF)
SELECT * FROM users_t WHERE lower(email) = 'user42@example.com';   -- seq scan

-- Expression index over lower(email):
CREATE INDEX users_t_email_lower ON users_t (lower(email));
ANALYZE users_t;
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF)
SELECT * FROM users_t WHERE lower(email) = 'user42@example.com';   -- index scan

-- THE MATCH RULE: the exact same expression, character for character:
EXPLAIN (ANALYZE, COSTS OFF)
SELECT * FROM users_t WHERE lower(email) = 'user42@example.com';              -- match
-- (equivalent but unmatched shapes:)
EXPLAIN (ANALYZE, COSTS OFF)
SELECT * FROM users_t WHERE email = lower('USER42@EXAMPLE.COM');              -- no match (different meaning anyway)
EXPLAIN (ANALYZE, COSTS OFF)
SELECT * FROM users_t WHERE upper(email) = 'USER42@EXAMPLE.COM';              -- no match: different expression

-- The IMMUTABLE rule — and why it exists. This is rejected outright:
-- functions containing now() are STABLE, not IMMUTABLE, so indexing them
-- fails with "functions in index expression must be marked IMMUTABLE":
\set ON_ERROR_STOP off
CREATE INDEX users_t_created_day ON users_t (to_char(now(), 'YYYY'));
\set ON_ERROR_STOP on
-- WHY: an index is a cache. If the expression could return something else
-- tomorrow (now() does, every microsecond!), the index would silently lie.

-- The classic timezone trap: date/at-time-zone conversions involving named
-- zones are STABLE (DST rules can change), so you cannot index them
-- directly — index the raw timestamptz and convert constants instead:
CREATE TABLE logs (id bigint PRIMARY KEY, at timestamptz NOT NULL);
INSERT INTO logs SELECT g, now() - (g || ' seconds')::interval FROM generate_series(1, 100000) g;
--   CREATE INDEX ON logs ((at AT TIME ZONE 'Europe/Berlin'));  -- rejected (stable)
CREATE INDEX logs_at ON logs (at);   -- index raw; query with converted bounds:
EXPLAIN (COSTS OFF)
SELECT count(*) FROM logs
WHERE at BETWEEN ('2026-09-25 00:00+02'::timestamptz) AND ('2026-09-26 00:00+02'::timestamptz);

-- jsonb expression index: promote a hot document field to an indexed key:
CREATE INDEX users_t_country ON users_t ((data ->> 'country'));
ANALYZE users_t;
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF)
SELECT count(*) FROM users_t WHERE data ->> 'country' = 'DE';
-- Note the extra parentheses around the expression in CREATE INDEX —
-- required for expressions beyond a bare column.

-- Functional buckets: index the computed grouping key:
CREATE INDEX users_t_age_decade ON users_t (((data ->> 'age')::int / 10));
EXPLAIN (COSTS OFF)
SELECT count(*) FROM users_t WHERE (data ->> 'age')::int / 10 = 3;

-- Write-cost reality: every expression index recomputes on writes to the
-- underlying columns. users_t now maintains email-lower + country + decade:
-- that's measurable CPU on insert-heavy paths. Keep the ones queries pay for.

-- TAKEAWAYS
-- * Match the expression EXACTLY in queries; refactors break matching
--   silently — re-EXPLAIN after refactors.
-- * IMMUTABLE-only expressions; now()/timezone conversions are out —
--   index raw values and transform constants instead.
-- * jsonb ->> 'field' expression index = poor man's promoted column
--   (11-advanced/generated_columns/ is the schema-level version).

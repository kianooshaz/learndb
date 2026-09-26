-- ============================================================================
-- 02-data-types/boolean.sql — booleans and three-valued logic
-- ============================================================================
-- Run:  make sql FILE=02-data-types/boolean.sql
--
-- SQL booleans are not true/false — they are TRUE / FALSE / UNKNOWN, because
-- NULL propagates through every predicate. If you internalize one file in
-- this module, make it this one: NULL logic causes subtle production bugs
-- in WHERE clauses, CHECK constraints, and ON conditions.
-- ============================================================================

\set ON_ERROR_STOP on
DROP SCHEMA IF EXISTS m02_bool CASCADE;
CREATE SCHEMA m02_bool;
SET search_path TO m02_bool;

-- Truth tables, straight from the server:
SELECT NULL AND FALSE AS null_and_false,   -- FALSE (FALSE is absorbing for AND)
       NULL AND TRUE  AS null_and_true,    -- NULL
       NULL OR TRUE   AS null_or_true,     -- TRUE (TRUE is absorbing for OR)
       NULL OR FALSE  AS null_or_false,   -- NULL
       NULL = NULL     AS null_eq_null,    -- NULL — unknown vs unknown!
       NULL IS NULL    AS null_is_null;    -- TRUE — IS NULL is the ONLY null test

-- WHERE keeps rows where the predicate is TRUE — NULL is rejected:
CREATE TABLE feature_flags (name text, enabled bool, rollout_pct int);
INSERT INTO feature_flags VALUES
    ('new_checkout', true,  100),
    ('new_search',   false, 0),
    ('beta_menu',    NULL,  5);   -- tri-state: not decided yet

-- "not enabled" does NOT include NULL rows:
SELECT name, enabled FROM feature_flags WHERE NOT enabled;
SELECT name, enabled FROM feature_flags WHERE enabled IS NOT TRUE;  -- FALSE *or* NULL
SELECT name FROM feature_flags WHERE enabled IS DISTINCT FROM true; -- same, general form

-- IS DISTINCT FROM: NULL-aware equality — invaluable in sync jobs comparing
-- two tables row by row:
SELECT NULL IS DISTINCT FROM NULL AS false_because_both_null,
       1    IS DISTINCT FROM NULL AS true_because_one_null;

-- Boolean columns and indexes:
-- Don't write `WHERE enabled = true` — noise (and tiny risk of accidentally
-- comparing with a nullable expression). The bare boolean IS the predicate:
SELECT name FROM feature_flags WHERE enabled;

-- A boolean column alone is a terrible index (2-3 distinct values; see
-- 04-indexes/partial_indexes.sql for the RIGHT pattern: partial index
-- WHERE enabled). Quick proof the planner ignores a low-selectivity index:
CREATE INDEX ON feature_flags (enabled);
EXPLAIN (COSTS OFF) SELECT * FROM feature_flags WHERE enabled;
DROP INDEX feature_flags_enabled_idx;

-- NOT NULL + DEFAULT false is the sane default for flags you'll filter on —
-- unknown states become an explicit second column or an enum instead.

-- Booleans from aggregates — FILTER (03-queries/aggregates.sql):
SELECT count(*) FILTER (WHERE enabled)      AS on_count,
       count(*) FILTER (WHERE NOT enabled)  AS off_count,
       count(*) FILTER (WHERE enabled IS NULL) AS undecided
FROM feature_flags;

-- TAKEAWAYS
-- * Predicates are three-valued; WHERE keeps TRUE only.
-- * NOT x excludes NULLs — use IS NOT TRUE / IS DISTINCT FROM when NULL
--   rows matter.
-- * NULL = NULL is NULL: never test nullability with =.
-- * Don't index bare booleans; partial indexes are the right tool.

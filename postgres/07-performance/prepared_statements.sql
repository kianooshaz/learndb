-- ============================================================================
-- 07-performance/prepared_statements.sql — plan caching and the skew trap
-- ============================================================================
-- Run:  make sql FILE=07-performance/prepared_statements.sql
--
-- PREPARE/EXECUTE (and what pgx does automatically — 13-go-postgres/
-- prepared_queries) caches the PARSED+PLANNED statement server-side:
--   * saves parse+plan CPU per execution
--   * generic vs custom plans: for the first 5 executions the server plans
--     with YOUR literal values (custom plan). Then it compares average
--     cost and may switch to ONE GENERIC plan for all values.
--
-- The trap: skewed data. A generic plan is optimal for the AVERAGE value —
-- and terrible for your rare-but-hotly-queried value. Watch it flip live.
-- ============================================================================

\set ON_ERROR_STOP on
\timing on
DROP SCHEMA IF EXISTS m07_prep CASCADE;
CREATE SCHEMA m07_prep;
SET search_path TO m07_prep, public;

CREATE TABLE events (id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY, kind text NOT NULL);
-- 99.9% 'common', 0.1% 'rare':
INSERT INTO events (kind)
SELECT CASE WHEN g % 1000 = 0 THEN 'rare' ELSE 'common' END
FROM generate_series(1, 2000000) g;
CREATE INDEX events_kind_idx ON events (kind);
ANALYZE events;

PREPARE by_kind (text) AS SELECT count(*) FROM events WHERE kind = $1;

-- Custom-plan phase: each EXECUTE plans with the actual literal ->
-- index scan for 'rare', seq scan for 'common' — both optimal:
EXECUTE by_kind('rare');
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF) EXECUTE by_kind('rare');
-- (custom plans show "Index Scan"; note it says "parameter $1 = 'rare'")

-- After FIVE executions, the switch check happens. Warm it up:
EXECUTE by_kind('common');
EXECUTE by_kind('common');
EXECUTE by_kind('common');
EXECUTE by_kind('common');

-- Now the moment of truth — plan may have gone generic:
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF) EXECUTE by_kind('rare');
-- If the plan is generic, this shows Seq Scan + Filter (plans for the
-- average case: 'common') — catastrophically slow for 'rare' at scale.
-- The signature in production: "the 6th call of the day got 100x slower"
-- or "slow only in staging/only in prod" (different data distributions).

-- ---------------------------------------------------------------------------
-- The knobs
-- ---------------------------------------------------------------------------
-- plan_cache_mode (per session/role/database/user):
SET plan_cache_mode = force_custom_plan;
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF) EXECUTE by_kind('rare');
SET plan_cache_mode = auto;                  -- default behavior
-- SET plan_cache_mode = force_generic_plan; -- the opposite corner
-- Or take THAT skewed query out of the statement cache entirely (pgx:
-- simple protocol for that statement, or a separate pool/conn setting).

-- pgx angle: pgx auto-prepares after ~5 executions of the same SQL string
-- on a connection — the SAME generic-plan flip applies to your Go service.
-- It is rare, but real: skew + parameterized equality = watch for it.

-- When prepared statements DON'T help: ad-hoc/one-shot queries (parse cost
-- is trivial vs execution), and plans that depend on value-specific stats
-- (your WHERE is not equality, or data is very skewed).

-- DEALLOCATE cleans up:
DEALLOCATE by_kind;

-- TAKEAWAYS
-- * Prepared = parse/plan once; 5-run custom->generic plan switch.
-- * Skewed equality columns + prepared statements = the classic trap.
-- * plan_cache_mode / keep skewed queries unprepared.
-- * pgx's statement cache inherits all of this — measure, don't assume.

-- ============================================================================
-- 04-indexes/partial_indexes.sql — index only the rows you query
-- ============================================================================
-- Run:  make sql FILE=04-indexes/partial_indexes.sql
--
-- A partial index has a WHERE clause: only matching rows enter the index.
-- Two superpowers:
--   1. SIZE/HOTNESS: index the 2% of rows your queries target (queue rows
--      that are pending, users that are active) — smaller, cache-hot, and
--      writes to the other 98% never touch it.
--   2. ENFORCED SELECTIVITY: the planner uses it confidently because it
--      knows every entry satisfies the predicate.
-- Requirement: your query's predicate must IMPLY the index predicate
-- (syntactically close enough for the planner's matcher).
-- ============================================================================

\set ON_ERROR_STOP on
\timing on
DROP SCHEMA IF EXISTS m04_partial CASCADE;
CREATE SCHEMA m04_partial;
SET search_path TO m04_partial, public;

-- A jobs table with a tiny hot set (the classic):
CREATE TABLE jobs (
    id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    status      text NOT NULL,            -- pending|running|done|failed
    payload     text NOT NULL,
    created_at  timestamptz NOT NULL DEFAULT now(),
    finished_at timestamptz
);
INSERT INTO jobs (status, payload, created_at, finished_at)
SELECT (ARRAY['pending','running','done','done','done','failed'])[1 + g % 6],
       'p' || g,
       now() - ((g % 900000) || ' seconds')::interval,
       CASE WHEN g % 6 >= 2 THEN now() - ((g % 900000) || ' seconds')::interval END
FROM generate_series(1, 1000000) g;

-- Full index on status: 1M entries, ~1/3 useless to anyone:
CREATE INDEX jobs_status_full ON jobs (status, created_at);
-- Partial index: only rows a worker would ever fetch:
CREATE INDEX jobs_pending ON jobs (created_at) WHERE status IN ('pending','running');
ANALYZE jobs;

SELECT relname, pg_size_pretty(pg_relation_size(oid)) AS size
FROM pg_class WHERE relname IN ('jobs_status_full','jobs_pending');

-- The worker query uses the partial one:
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF)
SELECT * FROM jobs WHERE status = 'pending' AND created_at > now() - interval '1 hour'
ORDER BY created_at LIMIT 10;
-- (If both qualify, the smaller usually wins; drop the full one to see it:)

DROP INDEX jobs_status_full;
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF)
SELECT * FROM jobs WHERE status = 'pending' AND created_at > now() - interval '1 hour'
ORDER BY created_at LIMIT 10;
-- Small index scan + ordered delivery (no sort) + LIMIT stops early.

-- ---------------------------------------------------------------------------
-- THE MATCHING RULE: query must imply the index predicate
-- ---------------------------------------------------------------------------
-- Query predicate EQUAL to index predicate -> used:
EXPLAIN (COSTS OFF) SELECT count(*) FROM jobs WHERE status = 'pending' AND created_at < now();

-- Query predicate WEAKER (only created_at) -> NOT used, correctly:
EXPLAIN (COSTS OFF) SELECT count(*) FROM jobs WHERE created_at < now();
-- The index only contains pending/running rows — it cannot answer about all.

-- Query predicate lists the same values in a different syntactic form —
-- the planner's implication matcher is mostly syntactic, not a theorem
-- prover. This one does NOT match and silently seq-scans:
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF)
SELECT count(*) FROM jobs
WHERE (status = 'pending' OR status = 'running') AND created_at < now();
-- ...although logically identical! Write predicates in the SAME shape as the
-- index (status IN ('pending','running')). Test both forms and keep the one
-- that matches — this is a real production foot-gun.

-- Partial UNIQUE index: "one X per Y, but only while active":
CREATE TABLE invites (
    user_id int NOT NULL,
    email   text NOT NULL,
    accepted_at timestamptz
);
CREATE UNIQUE INDEX invites_one_pending_per_user
    ON invites (user_id) WHERE accepted_at IS NULL;
INSERT INTO invites VALUES (1, 'a@x.com', NULL), (1, 'b@x.com', now());
--   INSERT INTO invites VALUES (1, 'c@x.com', NULL);
--   ERROR: duplicate key value violates unique constraint
-- One pending invite per user; unlimited accepted history. NULLS in UNIQUE
-- (01-basics/constraints.sql) can't express "one pending".

-- Also great: partial btree for "flagged only", "this tenant only" (if one
-- tenant dominates), IS NULL subsets, unarchived rows.

-- TAKEAWAYS
-- * Partial = smaller, hotter, write-cheaper for a known hot subset.
-- * The query's WHERE must imply the index's WHERE — in MATCHING SYNTAX.
-- * Partial UNIQUE encodes conditional uniqueness plain UNIQUE can't.
-- * Test with EXPLAIN after ANY refactor of query predicates.

-- ============================================================================
-- 11-advanced/procedures/basics.sql — CALL, INOUT, and transaction control
-- ============================================================================
-- Run:  make sql FILE=11-advanced/procedures/basics.sql
--
-- Procedures (PG11+) differ from functions in TWO ways that matter:
--   1. invoked with CALL, not SELECT; no expression use
--   2. they may run COMMIT/ROLLBACK INSIDE themselves — chunked work with
--      incremental progress, the batch-backfill pattern that functions
--      cannot express.
-- ============================================================================

\set ON_ERROR_STOP on
\timing on
DROP SCHEMA IF EXISTS m11_proc CASCADE;
CREATE SCHEMA m11_proc;
SET search_path TO m11_proc, public;

CREATE TABLE events (id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
                     at timestamptz NOT NULL,
                     processed boolean NOT NULL DEFAULT false);
INSERT INTO events (at) SELECT now() - (g || ' minutes')::interval
FROM generate_series(1, 50000) g;

-- ---------------------------------------------------------------------------
-- 1. Basic procedure with INOUT and output
-- ---------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE count_unprocessed(INOUT n int)
LANGUAGE plpgsql AS $$
BEGIN
    SELECT count(*) INTO n FROM events WHERE NOT processed;
END $$;

CALL count_unprocessed(0);      -- output shown as a result row
-- In Go: use pool.Exec(ctx, "CALL ...") — pgx surfaces INOUT results; or
-- return values via a small function when you need them in a SELECT.

-- ---------------------------------------------------------------------------
-- 2. THE pattern: chunked backfill with per-chunk COMMIT
-- ---------------------------------------------------------------------------
-- A function CANNOT commit; a single-statement UPDATE of 50M rows holds
-- locks/WAL for the whole duration. A procedure processes in chunks and
-- COMMITS each — restartable, lock-bounded, observable progress:
CREATE OR REPLACE PROCEDURE process_events(chunk int)
LANGUAGE plpgsql AS $$
DECLARE
    affected int;
    total    int := 0;
BEGIN
    LOOP
        UPDATE events SET processed = true
        WHERE id IN (SELECT id FROM events WHERE NOT processed
                     ORDER BY id LIMIT chunk);
        GET DIAGNOSTICS affected = ROW_COUNT;
        total := total + affected;
        EXIT WHEN affected = 0;
        COMMIT;                       -- <- ILLEGAL in a function
        RAISE NOTICE 'processed %, total %', affected, total;
    END LOOP;
END $$;

\timing on
CALL process_events(10000);
-- Watch the NOTICE lines: each chunk committed independently. Kill it
-- mid-run? Progress persists — restart resumes from where it stopped.

-- Long notes for production:
--  * chunk size trades lock duration vs overhead (1k-50k typical)
--  * ORDER BY id keeps the scan deterministic and resumable
--  * in autocommit-off contexts (a transaction from the app), COMMIT inside
--    the procedure ends THAT transaction — call procedures in autocommit or
--    understand what boundary you're crossing
--  * the same pattern powers index-friendly backfills (process by key
--    ranges) and retention sweeps

-- ---------------------------------------------------------------------------
-- 3. DO blocks — anonymous procedures for migrations/one-offs
-- ---------------------------------------------------------------------------
DO $$
DECLARE n int;
BEGIN
    SELECT count(*) INTO n FROM events WHERE processed;
    RAISE NOTICE 'events now processed: %', n;
END $$;
-- DO = procedure body without a name; perfect for migration-time data
-- fixes. It too may COMMIT in chunks.

-- TAKEAWAYS
-- * Procedures: CALL, INOUT, and internal COMMIT/ROLLBACK.
-- * Chunk+commit loops = bounded locks + restartable long jobs.
-- * DO for anonymous one-shot migration logic.
-- * Functions compute; procedures orchestrate.

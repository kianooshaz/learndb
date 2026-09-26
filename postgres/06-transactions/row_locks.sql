-- ============================================================================
-- 06-transactions/row_locks.sql — FOR UPDATE family, SKIP LOCKED, FK locks
-- ============================================================================
-- Run:  make sql FILE=06-transactions/row_locks.sql   (+ two-terminal demos)
--
-- Row-level locks are MVCC's write-side counterpart. Plain SELECT never
-- locks. To claim rows for a multi-statement read-modify-write, use the
-- FOR UPDATE family:
--
--   FOR UPDATE         strongest: blocks concurrent FOR UPDATE / UPDATE /
--                      DELETE on the row (any key or non-key change)
--   FOR NO KEY UPDATE  what a plain UPDATE (not touching key/unique cols)
--                      takes: conflicts with FOR UPDATE only
--   FOR SHARE          allows others' FOR NO KEY UPDATE, blocks DELETE /
--                      key changes — "I depend on this row as-is"
--   FOR KEY SHARE      weakest (what an INSERTing child takes on the FK
--                      parent): allows everything except DELETE of parent
--
-- SKIP LOCKED / NOWAIT modify acquisition behavior — the queue-worker pair.
-- ============================================================================

\set ON_ERROR_STOP on
DROP SCHEMA IF EXISTS m06_row CASCADE;
CREATE SCHEMA m06_row;
SET search_path TO m06_row, public;

CREATE TABLE jobs (
    id     int PRIMARY KEY,
    status text NOT NULL,
    worker text
);
INSERT INTO jobs SELECT g, 'pending', NULL FROM generate_series(1, 5) g;

-- ---------------------------------------------------------------------------
-- The job-queue pattern: SKIP LOCKED (single session demo of the semantics)
-- ---------------------------------------------------------------------------
-- Claim one job atomically. SKIP LOCKED makes N workers pull DISJOINT rows
-- with zero coordination:
UPDATE jobs SET status = 'running', worker = 'me'
WHERE id = (
    SELECT id FROM jobs
    WHERE status = 'pending'
    ORDER BY id
    LIMIT 1
    FOR UPDATE SKIP LOCKED           -- locked rows? pretend they don't exist
)
RETURNING id, worker;
-- Run this SAME statement in a second terminal immediately (before any
-- commit/reset): it returns the NEXT pending job, not a wait, not a clash.
-- That's a work queue in one statement — no advisory locks, no table lock.
-- (At scale add partial index WHERE status='pending' — 04-indexes.)

-- NOWAIT version: error 55P03 immediately instead of skipping:
--   SELECT id FROM jobs WHERE id = 1 FOR UPDATE NOWAIT;
BEGIN;
SAVEPOINT s;
SELECT id FROM jobs WHERE id = 1 FOR UPDATE NOWAIT;   -- 2nd terminal holds it
ROLLBACK TO s;   -- 1st terminal variant: handle 55P03 and move on
COMMIT;

-- ---------------------------------------------------------------------------
-- FOR UPDATE OF <table> — locking in joins
-- ---------------------------------------------------------------------------
CREATE TABLE owners (id int PRIMARY KEY, name text);
INSERT INTO owners VALUES (1, 'ops');
UPDATE jobs SET status = 'pending', worker = NULL;  -- reset for the demo

BEGIN;
SELECT j.id, o.name
FROM jobs j JOIN owners o ON o.id = 1
WHERE j.status = 'pending'
ORDER BY j.id
LIMIT 2
FOR UPDATE OF j;          -- lock ONLY jobs rows (not owners) — 1 row each
-- ... safe multi-statement work on those rows ...
COMMIT;

-- ---------------------------------------------------------------------------
-- The FK surprise: inserting a child locks the parent (FOR KEY SHARE)
-- ---------------------------------------------------------------------------
CREATE TABLE invoices (
    id     int PRIMARY KEY,
    owner  int NOT NULL REFERENCES owners (id)
);
-- Two-terminal demo of why DDL on parents can block/hang behind traffic:
-- A:  BEGIN;  INSERT INTO m06_row.invoices VALUES (100, 1);   -- holds KEY
--     -- SHARE on owners.id=1 (uncommitted child must not outlive parent)
-- B:  DELETE FROM m06_row.owners WHERE id = 1;   -- WAITS for A (conflict)
-- A:  COMMIT;  -> B proceeds, FK check runs, deletion fails if child stays.
-- Moral: FK enforcement IS row locking — bulk inserts of children serialize
-- against parent deletes/updates by design. Index the child FK column.

-- ---------------------------------------------------------------------------
-- Strength matrix in practice — NO KEY UPDATE lets key-share coexist:
-- ---------------------------------------------------------------------------
-- A: BEGIN; SELECT * FROM m06_row.owners WHERE id = 1 FOR NO KEY UPDATE;
-- B: BEGIN; INSERT INTO m06_row.invoices VALUES (101, 1);   -- succeeds NOW
--    (B only needs KEY SHARE; NO KEY UPDATE doesn't conflict with it)
-- B: COMMIT;  A: COMMIT;
-- Swap A's lock to full FOR UPDATE and B's insert BLOCKS until A commits.

-- TAKEAWAYS
-- * FOR UPDATE = claim; NO KEY UPDATE = plain-update lock; SHARE/KEY SHARE
--   for read-dependency (and FK machinery uses KEY SHARE silently).
-- * SKIP LOCKED = lock-free-ish queues; NOWAIT = fail fast (55P03).
-- * FOR UPDATE OF t locks only that table's rows in a join.
-- * Readers NEVER block (MVCC) — row locks matter only between writers.

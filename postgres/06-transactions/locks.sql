-- ============================================================================
-- 06-transactions/locks.sql — table locks, lock queues, pg_locks
-- ============================================================================
-- Run:  make sql FILE=06-transactions/locks.sql   (single-session parts)
--       + one two-terminal demo (marked)
--
-- Locks coordinate WRITERS (readers don't need them — MVCC). Two levels:
--   ROW locks    (row_locks.sql) — tuple-level, taken by UPDATE/DELETE/FOR UPDATE
--   TABLE locks  (this file)     — modes from ACCESS SHARE down to
--                                  ACCESS EXCLUSIVE
--
-- Table-lock strength ladder (weak -> strong):
--   ACCESS SHARE        taken by SELECT
--   ROW SHARE           taken by SELECT ... FOR UPDATE/SHARE
--   ROW EXCLUSIVE       taken by INSERT/UPDATE/DELETE
--   SHARE UPDATE EXCL.  VACUUM, ANALYZE (autovacuum's usual mode)
--   SHARE               CREATE INDEX (without CONCURRENTLY)
--   SHARE ROW EXCL.     specific forms of ALTER/TRIGGER work
--   EXCLUSIVE           REFRESH MATERIALIZED VIEW (non-concurrent)
--   ACCESS EXCLUSIVE    ALTER TABLE, DROP, TRUNCATE, VACUUM FULL, LOCK TABLE
--
-- Conflict rule: everything conflicts with ACCESS EXCLUSIVE; that's why a
-- trivial ALTER TABLE can wait behind (and block) your whole workload.
-- ============================================================================

\set ON_ERROR_STOP on
DROP SCHEMA IF EXISTS m06_locks CASCADE;
CREATE SCHEMA m06_locks;
SET search_path TO m06_locks, public;

CREATE TABLE t (id int PRIMARY KEY, v text);
INSERT INTO t VALUES (1, 'a');

-- What YOUR session holds right now (level 2+ rows; every statement takes
-- and releases; open transactions hold until commit):
SELECT locktype, relation::regclass AS rel, mode, granted
FROM pg_locks
WHERE relation IS NOT NULL
ORDER BY 1, 3;
-- Interpretation: each row is a lock; granted=f means someone is WAITING.

-- ---------------------------------------------------------------------------
-- DEMO (two terminals): the lock QUEUE and why it feels unfair
-- ---------------------------------------------------------------------------
-- A:  BEGIN;
--     LOCK TABLE m06_locks.t IN ACCESS EXCLUSIVE MODE;  -- e.g. ALTER-ish
--     -- (leave open)
-- B:  SELECT * FROM m06_locks.t;    -- BLOCKS (conflicts with A)
--
-- C:  SELECT * FROM m06_locks.t;    -- also blocks: requests QUEUE behind B
--     -- Even though a plain SELECT (ACCESS SHARE) wouldn't conflict with
--     -- OTHER SELECTs, the queue is FIFO-ish by conflict: C waits behind
--     -- the pending writer-class request. New readers queue behind it.
--
-- A:  COMMIT;                        -- everything unblocks in order.
-- Lesson: ONE long DDL under load can stall a fleet of innocent readers.
-- That's why migrations use lock_timeout + retries (12-production/migrations).

-- ---------------------------------------------------------------------------
-- Defensive tools every migration script should use
-- ---------------------------------------------------------------------------
-- lock_timeout: bound how long you'll WAIT for a lock (fail fast instead):
SET lock_timeout = '2s';
SHOW lock_timeout;
-- Typical migration preamble (the full story in 12-production/migrations/):
--   SET lock_timeout = '3s';
--   SET statement_timeout = '15s';
--   ALTER TABLE ... ;          -- if it can't get the lock in 3s: error 55P03

-- NOWAIT: acquire or error immediately:
BEGIN;
LOCK TABLE t IN ACCESS EXCLUSIVE MODE NOWAIT;
COMMIT;

-- Try-and-see if something is blocked RIGHT NOW (run while demo A/B is live):
SELECT pid, wait_event_type, wait_event, state,
       left(query, 60) AS query
FROM pg_stat_activity
WHERE datname = current_database() AND pid <> pg_backend_pid();
-- wait_event_type='Lock' = blocked on a lock. The full blocking-tree query
-- lives in 12-production/monitoring/locks.sql.

-- log_lock_waits (already ON in this lab's compose): every wait longer than
-- deadlock_timeout (1s) is logged — check:  docker compose logs postgres

-- Shared modes exist for real coordination: two ROW SHARE holders coexist;
-- two ACCESS EXCLUSIVE never do. For read-consistency you never need table
-- SHARE locks in application code — that's what transactions/snapshots are.

-- TAKEAWAYS
-- * Readers take ACCESS SHARE; writers ROW EXCLUSIVE; DDL ACCESS EXCLUSIVE.
-- * The queue is conflict-based: a pending strong lock blocks weaker NEW
--   requests too ("queue jumping" is prevented).
-- * lock_timeout + NOWAIT turn infinite waits into retryable errors.
-- * pg_locks + pg_stat_activity are your "who is blocking whom" toolbox.

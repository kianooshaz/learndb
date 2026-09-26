-- ============================================================================
-- 06-transactions/advisory_locks.sql — application-level locks in the DB
-- ============================================================================
-- Run:  make sql FILE=06-transactions/advisory_locks.sql
--
-- Advisory locks are locks on NUMBERS YOU choose — PostgreSQL stores the
-- hold, your application defines the meaning ("migration #17", "cron
-- leader", "tenant 42 export"). They cost no rows, no tables, and survive
-- being visible cluster-wide in pg_locks.
--
-- Two lifetimes, two key shapes:
--   session-level : pg_advisory_lock(key) ... held until unlock/disconnect
--   xact-level    : pg_advisory_xact_lock(key) ... held until COMMIT/ROLLBACK
--   key shapes    : one bigint, or two ints (namespace + id)
-- The try_* variants return false instead of waiting (NOWAIT semantics).
-- ============================================================================

\set ON_ERROR_STOP on
DROP SCHEMA IF EXISTS m06_adv CASCADE;
CREATE SCHEMA m06_adv;
SET search_path TO m06_adv, public;

-- Session-level lock with explicit release:
SELECT pg_advisory_lock(4242);                       -- "resource 4242 is mine"
SELECT locktype, objid, mode, granted FROM pg_locks
WHERE locktype = 'advisory' AND objid = 4242;        -- visible like any lock

SELECT pg_try_advisory_lock(4242) AS second_acquire_same_session;  -- true: reentrant-ish per session (counted)
SELECT pg_advisory_unlock(4242);                     -- release once per acquire
SELECT count(*) FROM pg_locks WHERE locktype='advisory' AND objid = 4242;

-- Two-int keys: namespace your lock space (one bigint can't collide-escape):
SELECT pg_advisory_lock(7, 101);    -- app 7, resource 101
SELECT pg_advisory_unlock(7, 101);

-- ---------------------------------------------------------------------------
-- Transaction-level locks: THE safer default for request-scoped work
-- ---------------------------------------------------------------------------
BEGIN;
SELECT pg_advisory_xact_lock(99);     -- auto-released at COMMIT/ROLLBACK:
SELECT count(*) FROM pg_locks WHERE locktype='advisory' AND objid = 99;
COMMIT;
SELECT count(*) FROM pg_locks WHERE locktype='advisory' AND objid = 99;  -- 0
-- Session locks + a Go panic + recovered-but-leaked connection = lock leaks
-- that block everything until the connection dies. xact locks cannot leak
-- past the transaction boundary — use them unless you truly need to hold a
-- lock across transactions.

-- ---------------------------------------------------------------------------
-- Single-flight / leader election: the try_lock pattern (2 terminals)
-- ---------------------------------------------------------------------------
-- A:  SELECT pg_try_advisory_lock(12345) AS got_it;    -- true
-- B:  SELECT pg_try_advisory_lock(12345) AS got_it;    -- false (instant!)
--     -> B becomes the standby / skips the job this round.
-- A:  SELECT pg_advisory_unlock(12345);
--
-- Cron leader in pure SQL (every minute, all nodes run it, ONE wins):
--   SELECT pg_try_advisory_lock(hashtext('nightly-export'));
--   -- true  -> you are the leader until you disconnect
--   -- false -> someone else has it; exit
-- Connection death releases session advisory locks automatically —
-- a crashed leader's lock evaporates with its TCP connection.

-- Shared variants exist for read-many/write-one coordination:
SELECT pg_advisory_xact_lock_shared(55);   -- many holders allowed
-- (an exclusive pg_advisory_xact_lock(55) in another session waits until
-- all shared holders finish — classic reader-writer latch.)

-- pg_advisory_unlock_all() — panic button for a session.

-- Lock keys hygiene: derive from stable names, never from countable rows:
--   hashtext('migrations:v17')        -- good: self-documenting
--   42                               -- bad: what is 42? collides with?
-- Keep a registry constant in your Go code (see 08-concurrency).

-- TAKEAWAYS
-- * Advisory locks = locks on numbers with app-defined meaning.
-- * Prefer XACT-scoped (no leaks); session-scoped for leader election.
-- * try_* for instant contention answers; shared_* for many-readers.
-- * Connection close releases session locks — design for crashes.

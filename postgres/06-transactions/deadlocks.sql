-- ============================================================================
-- 06-transactions/deadlocks.sql — create one, read the log, fix the code
-- ============================================================================
-- Run:  make sql FILE=06-transactions/deadlocks.sql    (prepares the scene)
--       The deadlock itself is a two-terminal (or Go) exercise.
--
-- A deadlock is a cycle of waits: A holds row 1 wants row 2; B holds row 2
-- wants row 1. Neither can proceed. PostgreSQL's detector runs every
-- deadlock_timeout (default 1s) and kills the transaction that detected the
-- cycle (error 40P01). The OTHER transaction proceeds normally.
--
-- Deadlocks are not "database problems" — they are CODE ORDERING bugs.
-- ============================================================================

\set ON_ERROR_STOP on
DROP SCHEMA IF EXISTS m06_dl CASCADE;
CREATE SCHEMA m06_dl;
SET search_path TO m06_dl, public;

CREATE TABLE accounts (id int PRIMARY KEY, balance int NOT NULL);
INSERT INTO accounts VALUES (1, 100), (2, 100);

-- ---------------------------------------------------------------------------
-- THE BUGGY PROTOCOL (run in two terminals, exactly interleaved)
-- ---------------------------------------------------------------------------
-- Terminal A (transfer 1 -> 2):          Terminal B (transfer 2 -> 1):
--   BEGIN;                                 BEGIN;
--   UPDATE m06_dl.accounts
--     SET balance = balance - 10 WHERE id = 1;
--                                         UPDATE m06_dl.accounts
--                                           SET balance = balance - 10 WHERE id = 2;
--   UPDATE m06_dl.accounts                -- A now waits for B's row 2...
--     SET balance = balance + 10 WHERE id = 2;
--                                         UPDATE m06_dl.accounts
--                                           SET balance = balance + 10 WHERE id = 1;
--                                         -- ...and B waits for A's row 1. CYCLE.
--   -- ~1s later ONE side gets:
--   -- ERROR: deadlock detected
--   -- DETAIL: Process 123 waits for ShareLock on transaction 456 ...
--   -- The other side commits happily. Data is CONSISTENT (nothing partial).
-- Both: ROLLBACK the failed one.
--
-- Then check the server log — the full cycle, both queries, both pids:
--   docker compose logs postgres | grep -A 20 'deadlock detected'

-- ---------------------------------------------------------------------------
-- THE FIX: a consistent global ordering
-- ---------------------------------------------------------------------------
-- Rule: every transaction touches rows (and tables!) in the SAME order.
-- Transfer code must lock source/dest ordered by id regardless of direction:
CREATE OR REPLACE FUNCTION transfer(from_id int, to_id int, amount int)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
    lo int := least(from_id, to_id);
    hi int := greatest(from_id, to_id);
BEGIN
    IF from_id = to_id THEN RETURN; END IF;
    -- Lock in ascending id order, ALWAYS:
    PERFORM 1 FROM m06_dl.accounts WHERE id = lo FOR UPDATE;
    PERFORM 1 FROM m06_dl.accounts WHERE id = hi FOR UPDATE;
    UPDATE m06_dl.accounts SET balance = balance - amount WHERE id = from_id;
    UPDATE m06_dl.accounts SET balance = balance + amount WHERE id = to_id;
END $$;

-- The ordered version cannot cycle: every locker queues on the SAME first
-- row, so wait relationships form a LINE, never a loop. Run transfer() from
-- two terminals concurrently in any direction — zero deadlocks.

-- When you can't order (user-driven flows): shorten the window
--   * acquire all locks UP FRONT (SELECT ... FOR UPDATE the full set, ordered)
--   * keep transactions TINY (no network calls between BEGIN/COMMIT!)
--   * lock_timeout + retry on 40P01 (13-go-postgres/retries)
--   * or avoid locks entirely with optimistic versioning (08/optimistic_locking)

-- ---------------------------------------------------------------------------
-- Deadlock FACTS that shape your response strategy
-- ---------------------------------------------------------------------------
--  * Detection is asynchronous (default check every 1s): a deadlock costs
--    ~1s of stall before the victim error — tune deadlock_timeout lower
--    only under heavy contention (it costs extra detector wakeups).
--  * The victim's error is 40P01: RETRYABLE — rerun the transaction.
--  * PostgreSQL never partially applies: the victim rolls back fully.
--  * Row-lock deadlocks across DIFFERENT objects (table A + row B) follow
--    the same fix: define one order for everything you touch.
SELECT * FROM accounts ORDER BY id;

-- TAKEAWAYS
-- * Deadlock = wait cycle; detector kills one side after ~deadlock_timeout.
-- * Fix by CONSISTENT ORDERING (rows, tables, advisory locks — everywhere).
-- * 40P01 is retryable; make the retry path real in your Go service.
-- * Automation: 08-concurrency/pessimistic_locking reproduces & fixes this.

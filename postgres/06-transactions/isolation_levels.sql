-- ============================================================================
-- 06-transactions/isolation_levels.sql — anomalies per level, hands-on
-- ============================================================================
-- Run:  make sql FILE=06-transactions/isolation_levels.sql
--       The interesting parts are TWO-TERMINAL scripts (precise steps below).
--
-- A snapshot = what one statement/transaction can see. The isolation level
-- decides WHEN a snapshot is taken:
--   READ COMMITTED  (default): a NEW snapshot EVERY statement. Sees others'
--                    committed changes between your statements.
--   REPEATABLE READ: one snapshot at the FIRST statement; held to COMMIT.
--                    (PG's RR also prevents phantoms — stricter than the SQL
--                    standard requires.)
--   SERIALIZABLE: RR + SSI (Serializable Snapshot Isolation) — detects
--                    dangerous read/write overlaps and ABORTS with 40001.
-- Postgres uses MVCC snapshots, never read locks: readers never block.
--
-- Anomaly scorecard (PG-specific, single-value-writes):
--   dirty read        impossible at every level (MVCC)
--   non-repeatable R  RC yes / RR no / SER no
--   phantom read      RC yes / RR no* / SER no
--   lost update       RC yes (see below) / RR no (aborts) / SER no
--   write skew        RC yes / RR yes(!) / SER aborts (serialization_failures)
-- ============================================================================

\set ON_ERROR_STOP on
DROP SCHEMA IF EXISTS m06_iso CASCADE;
CREATE SCHEMA m06_iso;
SET search_path TO m06_iso, public;

CREATE TABLE accounts (id int PRIMARY KEY, balance int NOT NULL);
INSERT INTO accounts VALUES (1, 100), (2, 100);

-- Session defaults and how to change them per-transaction:
SHOW transaction_isolation;
BEGIN;
SET TRANSACTION ISOLATION LEVEL REPEATABLE READ;
SHOW transaction_isolation;
ROLLBACK;

-- ---------------------------------------------------------------------------
-- DEMO 1 (two terminals): non-repeatable read at READ COMMITTED
-- ---------------------------------------------------------------------------
-- A:  BEGIN;                                              -- READ COMMITTED
--     SELECT sum(balance) FROM m06_iso.accounts;          -- 200
-- B:  UPDATE m06_iso.accounts SET balance = balance + 50 WHERE id = 1;
-- A:  SELECT sum(balance) FROM m06_iso.accounts;          -- 250: CHANGED
--     COMMIT;
--
-- Run 2 (same steps) but A starts with:
--     BEGIN ISOLATION LEVEL REPEATABLE READ;
--     ...B's update commits between the SELECTs...
-- A:  SELECT sum(balance) FROM m06_iso.accounts;          -- STILL 200
--     -- and if A now tries:  UPDATE accounts SET ...  -> ERROR 40001
--     -- "could not serialize access due to concurrent update" (conflict).
-- That ERROR is RR's answer to lost updates: abort and RETRY (see 13
-- -go-postgres/retries). RC would NOT abort; it silently works on the NEW
-- version — the lost-update anomaly demo (08-concurrency/lost_updates).

-- ---------------------------------------------------------------------------
-- DEMO 2: PG's REPEATABLE READ also blocks phantoms (nonstandard bonus)
-- ---------------------------------------------------------------------------
-- RR snapshot = whole database as of tx start. New matching rows committed
-- by others simply do not exist for you. (Standard RR allows them!)
-- Automated: 08-concurrency/race_conditions.

-- ---------------------------------------------------------------------------
-- Single-session proof of "writers don't block readers" (RC):
-- ---------------------------------------------------------------------------
BEGIN;
UPDATE accounts SET balance = 0 WHERE id = 1;      -- hold a modified row
SELECT count(*) FROM accounts WHERE balance = 0;   -- sees own uncommitted work
COMMIT;

SELECT id, balance FROM accounts ORDER BY id;      -- committed state

-- What RC means for UPDATES racing on the same row (EvalPlanQual):
-- Two sessions UPDATE the same row at RC: the second WAITS for the first,
-- then re-evaluates the WHERE on the NEW version. So:
UPDATE accounts SET balance = balance - 10 WHERE id = 1 AND balance >= 10;  -- you
-- another session running the SAME statement cannot make balance negative:
-- it waits, re-checks balance >= 10 against the post-you value, and skips
-- if false. Atomic UPDATE predicates + EvalPlanQual = lost-update-proof at
-- RC for single-statement read-modify-writes. (The 08 Go labs verify this.)

-- Choosing levels for a Go service (practical table):
--   * reports/exports spanning rows -> REPEATABLE READ for a consistent cut
--   * normal OLTP -> READ COMMITTED (fewest aborts; use atomic UPDATEs)
--   * invariants spanning multiple rows ("on-call can't be empty") ->
--     SERIALIZABLE + retry loop, or explicit locking (08/optimistic_locking)
-- Multi-statement read-modify-write at RC is where you MUST opt in to one
-- of: FOR UPDATE locks, SERIALIZABLE, or optimistic version columns.

-- TAKEAWAYS
-- * Level = WHEN the snapshot is frozen; MVCC makes dirty reads impossible.
-- * PG RR = no non-repeatable reads AND no phantoms; conflicts abort (40001).
-- * RC re-evaluates predicates on waiting UPDATEs (EvalPlanQual) — single-
--   statement read-modify-write is safe at RC.
-- * Multi-statement invariants need RR/SERIALIZABLE or explicit locking.

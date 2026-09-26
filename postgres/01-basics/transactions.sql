-- ============================================================================
-- 01-basics/transactions.sql — ACID building blocks in PostgreSQL
-- ============================================================================
-- Run:  make sql FILE=01-basics/transactions.sql
--
-- A transaction turns a group of statements into one all-or-nothing unit.
-- Two PostgreSQL-specific facts that surprise people coming from MySQL:
--   1. DDL is transactional: CREATE TABLE / ALTER TABLE roll back cleanly.
--   2. Any error inside a transaction poisons the WHOLE transaction — you
--      must ROLLBACK; you cannot just continue with the next statement.
-- ============================================================================

-- We deliberately trigger errors and must keep going after them.
\set ON_ERROR_STOP off

DROP SCHEMA IF EXISTS m01_tx CASCADE;
CREATE SCHEMA m01_tx;
SET search_path TO m01_tx;

CREATE TABLE accounts (id int PRIMARY KEY, balance numeric NOT NULL);
INSERT INTO accounts VALUES (1, 100), (2, 100);

-- Classic transfer: both changes or neither.
BEGIN;
UPDATE accounts SET balance = balance - 40 WHERE id = 1;
UPDATE accounts SET balance = balance + 40 WHERE id = 2;
COMMIT;
SELECT * FROM accounts ORDER BY id;

-- ROLLBACK undoes everything since BEGIN:
BEGIN;
UPDATE accounts SET balance = 0 WHERE id = 1;
SELECT balance FROM accounts WHERE id = 1;   -- sees 0: OUR OWN uncommitted work
ROLLBACK;
SELECT balance FROM accounts WHERE id = 1;   -- back to 60

-- ---------------------------------------------------------------------------
-- Error inside a transaction -> the transaction is ABORTED
-- ---------------------------------------------------------------------------
BEGIN;
UPDATE accounts SET balance = balance - 1 WHERE id = 1;
SELECT * FROM nonexistent_table;
-- ERROR: relation "nonexistent_table" does not exist
UPDATE accounts SET balance = balance - 1 WHERE id = 1;
-- ERROR: current transaction is aborted, commands ignored until end of
-- transaction block   <- THE error everyone meets once. Nothing runs after a
-- failure until ROLLBACK (or COMMIT, which doubles as rollback here).
ROLLBACK;

-- ---------------------------------------------------------------------------
-- SAVEPOINTs = nested transactions (sort of)
-- ---------------------------------------------------------------------------
-- A savepoint is a named point you can partially roll back to, without
-- losing the outer work. Perfect for "try; on failure, log and continue".
BEGIN;
INSERT INTO accounts VALUES (3, 100);
SAVEPOINT before_risky;
INSERT INTO accounts VALUES (4, 100 / 0);   -- division by zero
ROLLBACK TO before_risky;                   -- undoes ONLY the failed part
INSERT INTO accounts VALUES (5, 100);
COMMIT;
SELECT id FROM accounts ORDER BY id;        -- 1,2,3,5 — 4 never landed

-- ---------------------------------------------------------------------------
-- DDL is transactional
-- ---------------------------------------------------------------------------
BEGIN;
CREATE TABLE temp_thing (id int);
CREATE INDEX ON temp_thing (id);
ROLLBACK;
-- Table and index are GONE. This makes migrations far safer: a failed
-- migration's CREATE/ALTER statements vanish instead of half-applying.
-- (Exceptions exist outside plain DDL: CREATE INDEX CONCURRENTLY and a few
-- others cannot run inside a transaction block.)

-- Read-only transactions: the server rejects writes — useful to prove an
-- import job / reporting query can never mutate data.
BEGIN;
SET TRANSACTION READ ONLY;
SELECT count(*) FROM accounts;
-- UPDATE accounts SET balance = 0;  -- ERROR: cannot execute UPDATE in a read-only transaction
ROLLBACK;

-- Isolation levels are covered hands-on in 06-transactions/isolation_levels.sql.
SHOW transaction_isolation;   -- default: read committed

-- TAKEAWAYS
-- * BEGIN/COMMIT/ROLLBACK bracket all-or-nothing units; DDL included.
-- * After ANY error the transaction is aborted; only ROLLBACK is valid.
-- * SAVEPOINT + ROLLBACK TO = partial undo (per-item resilience).
-- * SET TRANSACTION READ ONLY = a correctness guard, not a performance knob.

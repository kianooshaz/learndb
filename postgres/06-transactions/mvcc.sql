-- ============================================================================
-- 06-transactions/mvcc.sql — tuples, xmin/xmax, snapshots: the machinery
-- ============================================================================
-- Run:  make sql FILE=06-transactions/mvcc.sql
--       (+ one two-terminal demo mid-file, marked clearly)
--
-- PostgreSQL's concurrency engine is MVCC: Multi-Version Concurrency
-- Control. Writers never overwrite data in place. Instead:
--   INSERT  -> a new tuple (row version) with xmin = your transaction id
--   UPDATE  -> a NEW tuple version; the OLD one gets xmax = your txid
--   DELETE  -> the existing tuple gets xmax = your txid
-- Readers pick which version is visible to THEM using a snapshot. Result:
--   * readers never block writers, writers never block readers
--   * old tuples linger as DEAD TUPLES until VACUUM reclaims them
--     (why vacuum exists at all — 07-performance/vacuum.sql)
--
-- System columns you can SELECT (but never see in SELECT *):
--   xmin  txid that CREATED this version
--   xmax  txid that DELETED/invalidated it (0 = still current)
--   ctid  physical (page, slot) address of this exact version
-- ============================================================================

\set ON_ERROR_STOP on
DROP SCHEMA IF EXISTS m06_mvcc CASCADE;
CREATE SCHEMA m06_mvcc;
SET search_path TO m06_mvcc, public;

CREATE TABLE accounts (id int PRIMARY KEY, balance int NOT NULL);
INSERT INTO accounts VALUES (1, 100);

-- Version #1 right after INSERT:
SELECT id, balance, xmin, xmax, ctid FROM accounts;

-- UPDATE creates a version, leaves the old one behind:
SELECT txid_current() AS my_tx;
UPDATE accounts SET balance = 150 WHERE id = 1;
SELECT id, balance, xmin, xmax, ctid FROM accounts;
-- xmin = your txid (this version is new); the OLD version still exists on
-- disk with xmax = your txid. Plain SELECT can't see dead versions — but
-- a REPEATABLE READ transaction still holding the old snapshot CAN:

-- ---------------------------------------------------------------------------
-- TWO-TERMINAL DEMO: old versions are really still there
-- ---------------------------------------------------------------------------
-- Terminal A (this file's schema is set up — run in a fresh `make psql`):
--   BEGIN TRANSACTION ISOLATION LEVEL REPEATABLE READ;
--   SELECT id, balance, xmin, xmax, ctid FROM m06_mvcc.accounts;   -- 100
--   (leave this open)
--
-- Terminal B:
--   UPDATE m06_mvcc.accounts SET balance = 999 WHERE id = 1;
--   -- (this blocks nobody! writers don't block readers, readers don't block writers)
--
-- Back in Terminal A (same REPEATABLE READ tx):
--   SELECT id, balance, xmin, xmax, ctid FROM m06_mvcc.accounts;
--   -- STILL 100, with the OLD xmin. Your snapshot frozen the world.
--   COMMIT;
--   SELECT id, balance, xmin, xmax, ctid FROM m06_mvcc.accounts;
--   -- NOW 999 (new snapshot). The old version is a dead tuple awaiting vacuum.
--
-- The automated version of this exact experiment: 08-concurrency/lost_updates

-- ---------------------------------------------------------------------------
-- Delete = mark xmax; space comes back only after VACUUM
-- ---------------------------------------------------------------------------
DELETE FROM accounts WHERE id = 1;
SELECT id, balance, xmin, xmax FROM accounts;   -- 0 rows to YOU (snapshot)
-- The tuple is dead but still occupying its page slot. Live vs dead counts:
SELECT n_live_tup, n_dead_tup FROM pg_stat_user_tables
WHERE schemaname = 'm06_mvcc' AND relname = 'accounts';
VACUUM accounts;
SELECT n_live_tup, n_dead_tup FROM pg_stat_user_tables
WHERE schemaname = 'm06_mvcc' AND relname = 'accounts';

-- ---------------------------------------------------------------------------
-- HOT updates — when indexes don't need to know about your UPDATE
-- ---------------------------------------------------------------------------
-- If the updated columns are NOT indexed, the new tuple is placed on the
-- SAME page and the index entry gets a pointer chain instead of a new
-- entry: a HOT (Heap-Only Tuple) update. Update an indexed column, and
-- EVERY index on the table gets new entries. Demonstrate the difference:
CREATE TABLE items (id int PRIMARY KEY, name text, status text);
CREATE INDEX items_name_idx ON items (name);
INSERT INTO items SELECT g, 'n' || g, 'draft' FROM generate_series(1, 10000) g;
ANALYZE items;

-- HOT-able: status isn't indexed:
SELECT pg_stat_get_tuples_hot_updated('m06_mvcc.items'::regclass) AS hot_before;
UPDATE items SET status = 'active';
SELECT pg_stat_get_tuples_hot_updated('m06_mvcc.items'::regclass) AS hot_after_10000;
-- 10,000 HOT updates: items_name_idx never noticed.

-- Not HOT-able: name IS indexed — 10k new index entries:
UPDATE items SET name = name || '!';
SELECT pg_stat_get_tuples_hot_updated('m06_mvcc.items'::regclass) AS hot_barely_moved;
-- Practical consequences: keep indexes to the columns you actually query;
-- every extra indexed column turns cheap UPDATEs into expensive ones.

-- Transaction id context (wraparound deep-dive is 07-performance/bloat.sql):
SELECT txid_current() AS current_txid,
       2^31 AS wraparound_horizon;
-- xmin/xmax are 32-bit; vacuum "freezes" old tuples so ancient txids can be
-- recycled. Skipping vacuum eventually forces the cluster to halt to
-- protect visibility — the infamous wraparound shutdown.

-- TAKEAWAYS
-- * UPDATE/DELETE never modify in place: new versions + xmax marks.
-- * Readers pick versions per SNAPSHOT, so writers never block readers.
-- * Dead tuples are the cost of MVCC; VACUUM is the garbage collector.
-- * HOT updates skip index maintenance when unindexed columns change —
--   fewer indexes = cheaper updates.

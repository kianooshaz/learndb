-- ============================================================================
-- 11-advanced/logical_replication/demo.sql — publications & subscriptions
-- ============================================================================
-- Run:
--   make logical   (starts the subscriber instance on port 5435 — REQUIRED)
--   make sql FILE=11-advanced/logical_replication/demo.sql
--
-- Logical replication streams ROW CHANGES (INSERT/UPDATE/DELETE) from a
-- publication on one database to a subscription on another — decoded from
-- WAL, applied as normal SQL. Unlike physical replication (12-production/
-- replication: byte-level, whole cluster), logical replication is:
--   * per-TABLE, per-DATABASE, writable target
--   * cross-major-version (the online-upgrade path!)
--   * the foundation of CDC (Debezium et al)
-- What it does NOT replicate: DDL, sequences, large objects. You manage
-- schema drift yourself.
--
-- GOTCHA this lab encodes in its own setup: creating a subscription that
-- connects back to the SAME instance deadlocks on its own snapshot (the
-- slot waits on the creating session's transaction). Real deployments
-- always involve two instances — hence the `shopdb` container.
-- ============================================================================

\set ON_ERROR_STOP on
\timing on

-- ---------------------------------------------------------------------------
-- 1. On the PUBLISHER (learndb, this connection): data + publication
-- ---------------------------------------------------------------------------
DROP SCHEMA IF EXISTS m11_lr CASCADE;
CREATE SCHEMA m11_lr;
CREATE TABLE m11_lr.orders (
    id bigint PRIMARY KEY, amount numeric NOT NULL, note text
);
INSERT INTO m11_lr.orders SELECT g, g * 1.5, 'seed' FROM generate_series(1, 1000) g;

DROP PUBLICATION IF EXISTS orders_pub;
CREATE PUBLICATION orders_pub FOR TABLE m11_lr.orders;

-- ---------------------------------------------------------------------------
-- 2. On the SUBSCRIBER (shop on the shopdb container): schema + subscription
-- ---------------------------------------------------------------------------
\connect postgres://postgres:postgres@shopdb:5432/shop
CREATE SCHEMA IF NOT EXISTS m11_lr;
DROP TABLE IF EXISTS m11_lr.orders CASCADE;
CREATE TABLE m11_lr.orders (
    id bigint PRIMARY KEY, amount numeric NOT NULL, note text
);
-- (In prod: the table can pre-exist with extra indexes/columns; extra
-- columns on the subscriber are allowed and stay untouched.)

DROP SUBSCRIPTION IF EXISTS orders_sub;
CREATE SUBSCRIPTION orders_sub
    CONNECTION 'host=postgres port=5432 dbname=learndb user=postgres password=postgres'
    PUBLICATION orders_pub;
-- Creating the subscription:
--   * opens a REPLICATION SLOT on the publisher (retains WAL until applied!)
--   * copies the EXISTING table (initial sync)
--   * then streams live changes

-- Watch the initial data arrive:
SELECT count(*) AS initial_rows, min(amount), max(amount) FROM m11_lr.orders;

-- ---------------------------------------------------------------------------
-- 3. Live changes flow (publisher writes -> subscriber sees them)
-- ---------------------------------------------------------------------------
\connect postgres://postgres:postgres@postgres:5432/learndb
INSERT INTO m11_lr.orders VALUES (1001, 42.0, 'live-insert');
UPDATE m11_lr.orders SET note = 'live-update' WHERE id = 1;
DELETE FROM m11_lr.orders WHERE id = 2;

\connect postgres://postgres:postgres@shopdb:5432/shop
-- Changes apply asynchronously — rerun the file or wait a beat if you catch
-- it mid-flight:
SELECT count(*) AS after_live, count(*) FILTER (WHERE note = 'live-insert') AS live_ins,
       count(*) FILTER (WHERE note = 'live-update') AS live_upd
FROM m11_lr.orders;
SELECT EXISTS (SELECT 1 FROM m11_lr.orders WHERE id = 2) AS deleted_row_gone;

-- UPDATE/DELETE require identity: REPLICA IDENTITY (default = PK). Tables
-- WITHOUT a PK need REPLICA IDENTITY FULL to replicate deletes.

\connect postgres://postgres:postgres@postgres:5432/learndb
-- Publisher-side monitoring (slots + lag — the operational core):
SELECT slot_name, plugin, active,
       pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), confirmed_flush_lsn)) AS retained_wal
FROM pg_replication_slots;

-- A dead subscription that never releases its slot = WAL GROWTH on the
-- publisher until disk fills. THE logical-replication operational risk:
-- monitor retained_wal, drop subscriptions you abandon.

-- Subscriber-side view (status of the apply workers):
--   on shopdb: SELECT * FROM pg_stat_subscription;

-- ---------------------------------------------------------------------------
-- 4. Teardown (clean slots!)
-- ---------------------------------------------------------------------------
\connect postgres://postgres:postgres@shopdb:5432/shop
DROP SUBSCRIPTION orders_sub;      -- releases the slot on the publisher
\connect postgres://postgres:postgres@postgres:5432/learndb
DROP PUBLICATION orders_pub;
DROP SCHEMA m11_lr CASCADE;

-- Logical vs physical (the decision):
--   logical : selective tables, writable target, cross-version, CDC feeds
--   physical: full-cluster HA/failover, exact replica, same major version
--   (12-production/replication builds a physical streaming replica.)
-- ============================================================================

-- TAKEAWAYS
-- * Publication (publisher) + subscription (subscriber); initial copy +
--   live streaming via WAL decoding.
-- * No DDL/sequence replication; schema is YOUR job.
-- * Slots retain WAL: monitor or disk-full the publisher.
-- * Cross-version upgrades + CDC are its superpowers.

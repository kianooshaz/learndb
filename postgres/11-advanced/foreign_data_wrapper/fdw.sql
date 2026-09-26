-- ============================================================================
-- 11-advanced/foreign_data_wrapper/fdw.sql — query another server locally
-- ============================================================================
-- Run:  make sql FILE=11-advanced/foreign_data_wrapper/fdw.sql
--
-- postgres_fdw proxies a REMOTE PostgreSQL as local tables: CREATE FOREIGN
-- TABLE + a server definition + user mapping. The planner PUSHES DOWN
-- what it can (WHERE, JOINs, aggregates, sorts) and fetches only what
-- survives. Same-instance loopback here; identical mechanics across hosts.
--
-- Uses: cross-cluster reporting, gradual service extraction ("read the old
-- DB while writing the new"), sharded reads. Limits: latency amplification,
-- limited 2PC, no DDL sync.
-- ============================================================================

\set ON_ERROR_STOP on
\timing on
DROP SCHEMA IF EXISTS m11_fdw CASCADE;
CREATE SCHEMA m11_fdw;
SET search_path TO m11_fdw, public;

-- Source data living in a separate schema (stands in for "the other DB"):
CREATE SCHEMA IF NOT EXISTS m11_fdw_source;
DROP TABLE IF EXISTS m11_fdw_source.orders CASCADE;
CREATE TABLE m11_fdw_source.orders (
    id int PRIMARY KEY, customer_id int NOT NULL, total numeric NOT NULL);
INSERT INTO m11_fdw_source.orders
SELECT g, g % 500, (g % 300)::numeric FROM generate_series(1, 100000) g;

-- ---------------------------------------------------------------------------
-- The three-piece setup
-- ---------------------------------------------------------------------------
-- 1) SERVER: where and how to connect (loopback here — in prod: host/db of
--    the other cluster):
DROP SERVER IF EXISTS loopback CASCADE;
CREATE SERVER loopback FOREIGN DATA WRAPPER postgres_fdw
    OPTIONS (host 'localhost', port '5432', dbname 'learndb');

-- 2) USER MAPPING: credentials per local role (secrets! use a dedicated
--    read-only role in production, and keep this file out of migrations):
DROP USER MAPPING IF EXISTS FOR postgres SERVER loopback;
CREATE USER MAPPING FOR postgres SERVER loopback
    OPTIONS (user 'postgres', password 'postgres');

-- 3) FOREIGN TABLE: the local view of the remote table:
CREATE FOREIGN TABLE remote_orders (
    id int, customer_id int, total numeric
) SERVER loopback OPTIONS (schema_name 'm11_fdw_source', table_name 'orders');

-- Or IMPORT FOREIGN SCHEMA for bulk adoption:
IMPORT FOREIGN SCHEMA m11_fdw_source FROM SERVER loopback INTO m11_fdw;
-- (that created m11_fdw.orders too — drop the duplicate demo):
DROP FOREIGN TABLE IF EXISTS m11_fdw.orders;

-- ---------------------------------------------------------------------------
-- Query through it — and verify pushdown
-- ---------------------------------------------------------------------------
\timing on
SELECT count(*), round(avg(total), 2) FROM remote_orders WHERE customer_id = 7;

-- EXPLAIN (VERBOSE) prints "Remote SQL": what ACTUALLY ran remotely:
EXPLAIN (VERBOSE, COSTS OFF)
SELECT count(*) FROM remote_orders WHERE total > 250;
-- Look for:  Remote SQL: SELECT count(*) FROM m11_fdw_source.orders WHERE ...
-- The WHERE went WITH it. That's pushdown: filtering happens remotely,
-- only the result crosses the wire.

-- Joins between local and remote (federated query):
CREATE TABLE local_customers (id int PRIMARY KEY, name text);
INSERT INTO local_customers SELECT g, 'c' || g FROM generate_series(1, 500) g;
SELECT c.name, sum(r.total) AS spend
FROM remote_orders r JOIN local_customers c ON c.id = r.customer_id
GROUP BY c.name ORDER BY spend DESC LIMIT 3;
-- PG12+ pushes down full remote joins when both sides are foreign.

-- What NOT to put behind FDW blindly:
--  * OLTP-critical reads: every access is a network round trip + remote plan
--  * writes without understanding 2PC semantics (local tx commits,
--    remote failure windows exist)
--  * anything needing strong consistency across both sides in one query
-- For reporting/architecture bridges, it's excellent.

-- Introspection:
SELECT srvname, srvoptions FROM pg_foreign_server;
SELECT ft.ftrelid::regclass AS foreign_table, fs.srvname AS server
FROM pg_foreign_table ft JOIN pg_foreign_server fs ON fs.oid = ft.ftserver;

-- TAKEAWAYS
-- * SERVER + USER MAPPING + FOREIGN TABLE (or IMPORT FOREIGN SCHEMA).
-- * Check "Remote SQL" in EXPLAIN VERBOSE: pushdown is the whole game.
-- * Great for cross-cluster reads/migrations; poor for hot-path OLTP.
-- * file_fdw (same family) mounts server-side CSV/text files read-only.

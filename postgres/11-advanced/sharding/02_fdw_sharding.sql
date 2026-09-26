-- ============================================================================
-- 11-advanced/sharding/02_fdw_sharding.sql — a coordinator that routes for you
-- ============================================================================
-- Run:  make sql FILE=11-advanced/sharding/02_fdw_sharding.sql
--       (plain `make up` is enough — shards are schemas on the same instance;
--        the mechanics are IDENTICAL across real servers)
--
-- Level-2 sharding: PostgreSQL ITSELF as the router. Hash-partitioned table
-- whose partitions are FOREIGN TABLES (postgres_fdw) pointing at shard
-- databases. Your app writes normal SQL; the coordinator partitions route,
-- prune, and scatter. This is (simplified) how Citus-like systems look from
-- the planner's perspective — and it surfaces the classic limitations:
-- no global unique constraints, no cross-shard transactions.
-- ============================================================================

\set ON_ERROR_STOP on
\timing on

-- ---------------------------------------------------------------------------
-- 0. The "cluster": 3 shard schemas + one loopback server
-- ---------------------------------------------------------------------------
DROP SCHEMA IF EXISTS m11_coord CASCADE;
DROP SCHEMA IF EXISTS m11_shard0 CASCADE;
DROP SCHEMA IF EXISTS m11_shard1 CASCADE;
DROP SCHEMA IF EXISTS m11_shard2 CASCADE;
CREATE SCHEMA m11_coord;
CREATE SCHEMA m11_shard0;
CREATE SCHEMA m11_shard1;
CREATE SCHEMA m11_shard2;

DROP SERVER IF EXISTS loopback CASCADE;
CREATE SERVER loopback FOREIGN DATA WRAPPER postgres_fdw
    OPTIONS (host 'localhost', port '5432', dbname 'learndb');
CREATE USER MAPPING FOR postgres SERVER loopback
    OPTIONS (user 'postgres', password 'postgres');

-- Shard tables (NO globally-unique id possible here — note the plain PKs):
CREATE TABLE m11_shard0.events (id bigint, user_id int, body text, PRIMARY KEY (id, user_id));
CREATE TABLE m11_shard1.events (LIKE m11_shard0.events INCLUDING ALL);
CREATE TABLE m11_shard2.events (LIKE m11_shard0.events INCLUDING ALL);

-- ---------------------------------------------------------------------------
-- 1. The coordinator: hash partitions over foreign tables
-- ---------------------------------------------------------------------------
-- Foreign tables need their columns DECLARED (they import nothing); the
-- column list must match the parent partition exactly (names AND order):
CREATE FOREIGN TABLE m11_coord.events_0 (id bigint NOT NULL, user_id int NOT NULL, body text NOT NULL)
    SERVER loopback OPTIONS (schema_name 'm11_shard0', table_name 'events');
CREATE FOREIGN TABLE m11_coord.events_1 (id bigint NOT NULL, user_id int NOT NULL, body text NOT NULL)
    SERVER loopback OPTIONS (schema_name 'm11_shard1', table_name 'events');
CREATE FOREIGN TABLE m11_coord.events_2 (id bigint NOT NULL, user_id int NOT NULL, body text NOT NULL)
    SERVER loopback OPTIONS (schema_name 'm11_shard2', table_name 'events');

CREATE TABLE m11_coord.events (
    id bigint NOT NULL,
    user_id int NOT NULL,
    body text NOT NULL
) PARTITION BY HASH (user_id);

-- Attach shards as hash partitions (same modulus/remainder scheme every
-- sharding router uses — 01_shard_key.sql):
ALTER TABLE m11_coord.events ATTACH PARTITION m11_coord.events_0
    FOR VALUES WITH (MODULUS 3, REMAINDER 0);
ALTER TABLE m11_coord.events ATTACH PARTITION m11_coord.events_1
    FOR VALUES WITH (MODULUS 3, REMAINDER 1);
ALTER TABLE m11_coord.events ATTACH PARTITION m11_coord.events_2
    FOR VALUES WITH (MODULUS 3, REMAINDER 2);

-- ---------------------------------------------------------------------------
-- 2. Writes route automatically
-- ---------------------------------------------------------------------------
INSERT INTO m11_coord.events (id, user_id, body)
SELECT g, (g % 500) + 1, 'payload ' || g
FROM generate_series(1, 10000) g;

-- Physical truth: rows landed on shards by hash(user_id) % 3:
SELECT 'shard0' AS shard, count(*) FROM m11_shard0.events
UNION ALL SELECT 'shard1', count(*) FROM m11_shard1.events
UNION ALL SELECT 'shard2', count(*) FROM m11_shard2.events
ORDER BY 1;
-- (roughly even — modulo on 500 users into 3 buckets)

-- ---------------------------------------------------------------------------
-- 3. Reads: routed vs scattered (pruning in action)
-- ---------------------------------------------------------------------------
-- WITH the shard key: one partition, pushed to that shard:
EXPLAIN (ANALYZE, VERBOSE, COSTS OFF, TIMING OFF, SUMMARY OFF)
SELECT count(*) FROM m11_coord.events WHERE user_id = 42;
-- "Insert on ..." — one partition; the Remote SQL carries WHERE user_id=42.
-- The coordinator opened exactly ONE remote connection's worth of work.

-- WITHOUT the key: all three shards queried in parallel and merged:
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF)
SELECT count(*) FROM m11_coord.events WHERE body LIKE 'payload 42%';
-- Every partition scanned = scatter-gather. Latency = slowest shard.

-- Aggregates: PG pushes down per-shard partial aggregation when it can:
EXPLAIN (COSTS OFF) SELECT user_id, count(*) FROM m11_coord.events
WHERE user_id = 42 GROUP BY user_id;

-- ---------------------------------------------------------------------------
-- 4. THE failure: no global uniqueness
-- ---------------------------------------------------------------------------
-- The coordinator table CANNOT have a PK across foreign partitions
-- (foreign tables can't host constraints). Each shard enforces (id,user_id)
-- only WITHIN itself. Same id, different user_id -> different shard ->
-- both accepted; the "table" now has duplicate ids:
INSERT INTO m11_coord.events VALUES (999, 1,   'first');   -- hash(1)   -> one shard
INSERT INTO m11_coord.events VALUES (999, 250, 'second');  -- hash(250) -> another
SELECT count(*) AS rows_with_id_999 FROM m11_coord.events WHERE id = 999;
-- 2. In an unsharded table this was impossible (PK). THIS is why sharded
-- systems generate ids differently: per-shard ranges, UUIDs, or a central
-- ticket service (app_router/ implements two of those).

-- ---------------------------------------------------------------------------
-- 5. THE failure: no cross-shard transaction
-- ---------------------------------------------------------------------------
-- "Move event 999 from user 250 to user 1" spans two shards = two foreign
-- servers = two local transactions. postgres_fdw will NOT give you one ACID
-- transaction across them:
BEGIN;
UPDATE m11_coord.events SET body = 'updated-both' WHERE user_id = 1 AND id = 999;
UPDATE m11_coord.events SET body = 'updated-both' WHERE user_id = 250 AND id = 999;
COMMIT;
-- Each UPDATE commits on its own shard. A crash between them = half-applied.
-- Real options: (a) redesign so multi-row writes share one shard key,
-- (b) two-phase commit (PREPARE TRANSACTION — off by default; has real
-- operational costs), (c) sagas/outbox with compensations (the usual
-- microservice answer). Choice (a) is why shard-key design is EVERYTHING.

-- ---------------------------------------------------------------------------
-- 6. Why real systems don't stop here (and what Citus adds)
-- ---------------------------------------------------------------------------
-- This DIY coordinator: routes and prunes (real), but each query opens
-- fresh remote connections, no parallel scatter across shards by default,
-- no rebalancer, no colocated join planning, DDL on shards is manual.
-- Citus (citus.md) implements this same architecture WITH all of those —
-- which is why "extension" beats "hand-rolled FDW" for production.
-- ============================================================================

-- TAKEAWAYS
-- * Hash partitioning over foreign tables = Postgres-native sharding.
-- * WITH shard key -> single-shard remote SQL; WITHOUT -> scatter-gather.
-- * Uniqueness and cross-shard ACID are structurally absent: design the
-- * shard key so hot paths never need either.

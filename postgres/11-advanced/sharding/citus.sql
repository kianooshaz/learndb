-- ============================================================================
-- 11-advanced/sharding/citus.sql — production sharding via the Citus extension
-- ============================================================================
-- Run:
--   make citus                                                    # port 5436
--   make sql-citus FILE=11-advanced/sharding/citus.sql
--
-- Citus turns the FDW architecture from 02_fdw_sharding.sql into a first-
-- class distributed planner: one `create_distributed_table()` call and you
-- get:
--   * hash-distributed shards (real tables on worker nodes)
--   * COLocation: tables with the same distribution column & shard count
--     have matching shard layouts -> local joins
--   * reference tables: replicated to every node (small dimensions)
--   * parallel scatter-gather, pushed-down aggregates
--   * a REBALANCER that moves shards between nodes online
--   * distributed DDL and (with citus_mx) multi-statement coordination
-- The lab runs single-node Citus (coordinator only) — every concept below
-- behaves identically; the workers are just shards on one machine.
-- ============================================================================

\set ON_ERROR_STOP on
\timing on

CREATE EXTENSION IF NOT EXISTS citus;

-- ---------------------------------------------------------------------------
-- 1. Distributed table: the one-call shard
-- ---------------------------------------------------------------------------
CREATE TABLE events (id bigint GENERATED ALWAYS AS IDENTITY,
                     user_id int NOT NULL, body text NOT NULL,
                     PRIMARY KEY (id, user_id));   -- distribution col required
SELECT create_distributed_table('events', 'user_id');

-- Which shards exist and where (single-node: all on the coordinator):
SELECT shardid, nodename, nodeport, shardstate
FROM citus_shards
WHERE table_name = 'public.events'
ORDER BY shardid LIMIT 6;

-- Writes route by hash(user_id) — same math, handled BY the extension:
INSERT INTO events (user_id, body)
SELECT (g % 500) + 1, 'payload ' || g FROM generate_series(1, 50000) g;

-- Routed query (shard key present): one shard:
EXPLAIN (COSTS OFF) SELECT count(*) FROM events WHERE user_id = 42;

-- Scatter-gather (no shard key): all shards, parallel, merged at coordinator:
EXPLAIN (COSTS OFF) SELECT count(*) FROM events WHERE body LIKE 'payload 42%';

-- ---------------------------------------------------------------------------
-- 2. Colocation: joins that stay LOCAL
-- ---------------------------------------------------------------------------
CREATE TABLE users_t (user_id int PRIMARY KEY, name text NOT NULL);
SELECT create_distributed_table('users_t', 'user_id');   -- SAME column + default
-- colocation group -> matching shard layout:
INSERT INTO users_t SELECT g, 'user' || g FROM generate_series(1, 500) g;

EXPLAIN (COSTS OFF)
SELECT u.name, count(*) AS events
FROM users_t u JOIN events e ON e.user_id = u.user_id   -- joins ON the
WHERE u.user_id = 42                                    -- distribution column
GROUP BY u.name;
-- No inter-shard traffic: colocated shards join LOCALLY on each worker and
-- only aggregates come back. Join NOT on the distribution column -> Citus
-- repartitions (pulls both sides to the coordinator) — correct but slow.

-- ---------------------------------------------------------------------------
-- 3. Reference tables: replicate small dimensions everywhere
-- ---------------------------------------------------------------------------
CREATE TABLE countries (code text PRIMARY KEY, name text NOT NULL);
INSERT INTO countries VALUES ('US','United States'), ('DE','Germany');
SELECT create_reference_table('countries');
-- Now every shard has its own full copy: joins vs countries are LOCAL for
-- every query, on every worker — the "broadcast join" done right.
EXPLAIN (COSTS OFF)
SELECT c.name, count(*) FROM events e JOIN countries c ON c.code = 'US'
GROUP BY c.name;

-- ---------------------------------------------------------------------------
-- 4. The same hard problems, handled honestly
-- ---------------------------------------------------------------------------
-- Global uniqueness: still no cross-shard UNIQUE on a non-distribution
-- column. Citus answer for ids: sequence coordination is NOT automatic —
-- use UUIDs, or per-shard id ranges (or Citus MX + the citus addon).
-- Cross-shard writes: Citus DOES coordinate 2PC for multi-shard
-- transactions in the same session (single-node here: trivially local).
-- Rebalancing: with real workers:
--   SELECT rebalance_table_shards('events');
-- moves shards online, throttled, resumable — the feature DIY-FDW lacks.

-- Local (non-distributed) tables still exist on the coordinator for tiny
-- config data — choose deliberately per table.

-- TAKEAWAYS
-- * create_distributed_table(hash col) = automatic sharding + routing.
-- * Same distribution column => colocation => local joins.
-- * create_reference_table = replicated dimension tables.
-- * rebalance_table_shards = online resharding; DIY FDW has no equivalent.

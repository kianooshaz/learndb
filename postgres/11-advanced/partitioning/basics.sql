-- ============================================================================
-- 11-advanced/partitioning/basics.sql — declarative partitioning, hands-on
-- ============================================================================
-- Run:  make sql FILE=11-advanced/partitioning/basics.sql
--
-- Partitioning splits ONE logical table into many physical child tables.
-- Why engineers do it:
--   * DROP PARTITION = instant bulk retention (vs DELETE of millions of rows)
--   * partition pruning: queries touch only relevant partitions
--   * smaller indexes/vacuum units per partition
-- Why NOT (be honest): extra DDL automation, cross-partition uniqueness
-- limits, per-partition plan overhead. Under ~50-100GB it's often overhead.
--
-- Three strategies: RANGE (time/number series), LIST (discrete keys),
-- HASH (spread a hot key). Every row must have a home: no partition key
-- match = ERROR (or the DEFAULT partition catches it).
-- ============================================================================

\set ON_ERROR_STOP on
\timing on
DROP SCHEMA IF EXISTS m11_part CASCADE;
CREATE SCHEMA m11_part;
SET search_path TO m11_part, public;

-- ---------------------------------------------------------------------------
-- 1. RANGE partitioning by month — the time-series workhorse
-- ---------------------------------------------------------------------------
-- KEY RULE: the partition key MUST be part of the primary key (and any
-- unique constraint). An index cannot enforce uniqueness across separate
-- physical partitions:
CREATE TABLE events (
    id        bigint NOT NULL,
    at        timestamptz NOT NULL,
    kind      text NOT NULL,
    PRIMARY KEY (id, at)                     -- note: 'at' is IN the pkey
) PARTITION BY RANGE (at);

CREATE TABLE events_2026_08 PARTITION OF events
    FOR VALUES FROM ('2026-08-01') TO ('2026-09-01');
CREATE TABLE events_2026_09 PARTITION OF events
    FOR VALUES FROM ('2026-09-01') TO ('2026-10-01');
CREATE TABLE events_2026_10 PARTITION OF events
    FOR VALUES FROM ('2026-10-01') TO ('2026-11-01');

-- Rows route automatically:
INSERT INTO events (id, at, kind)
SELECT g,
       '2026-08-15'::timestamptz + ((g % 70) || ' days')::interval,
       'k' || g % 10
FROM generate_series(1, 100000) g;
--   ... wait: some rows land past 2026-10-31? No: max = Aug 15 + 69 days
--   = Oct 23 — inside events_2026_10. Rows outside ALL partitions ERROR:
--   INSERT INTO events VALUES (1, '2026-12-01', 'x');
--   ERROR: no partition of relation "events" found for row

SELECT tableoid::regclass AS partition, count(*)
FROM events GROUP BY 1 ORDER BY 1;

-- ---------------------------------------------------------------------------
-- 2. Pruning: the planner skips partitions your query can't touch
-- ---------------------------------------------------------------------------
-- STATIC pruning (constant in the query) — visible in the plan:
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF)
SELECT count(*) FROM events WHERE at >= '2026-09-01' AND at < '2026-09-15';
-- Only events_2026_09 appears — the other partitions don't exist for this
-- query. Check with \timing on: it reads 1/3 of the data.

-- RUNTIME pruning (parameter from a prepared statement/app) also works:
PREPARE q(timestamptz) AS SELECT count(*) FROM events WHERE at >= $1 AND at < $1 + interval '1 day';
EXPLAIN (COSTS OFF) EXECUTE q('2026-08-20');
EXPLAIN (COSTS OFF) EXECUTE q('2026-08-20');
EXPLAIN (COSTS OFF) EXECUTE q('2026-08-20');
EXPLAIN (COSTS OFF) EXECUTE q('2026-08-20');
EXPLAIN (COSTS OFF) EXECUTE q('2026-08-20');
-- Custom plans prune exactly; after the 5-run generic-plan switch the
-- "Subplans Removed" line shows RUNTIME pruning (07-performance/
-- prepared_statements.sql explains the 5-run rule).

-- The one query shape pruning CANNOT help: no partition key in WHERE:
EXPLAIN (COSTS OFF) SELECT count(*) FROM events WHERE kind = 'k3';   -- all partitions

-- ---------------------------------------------------------------------------
-- 3. Retention: DROP is instant; DELETE is not
-- ---------------------------------------------------------------------------
\timing on
DELETE FROM events WHERE at < '2026-09-01';     -- scans + writes dead tuples
DROP TABLE events_2026_08;                      -- catalog metadata: ~0ms
-- This asymmetry (and skipping vacuum/bloat of huge DELETEs) is why
-- time-partitioned retention policies exist.

-- Detach instead of DROP to keep data aside (zero-loss rollback path):
ALTER TABLE events DETACH PARTITION events_2026_09;
\set ON_ERROR_STOP off
INSERT INTO events VALUES (99, '2026-09-10', 'x');   -- no partition -> ERROR
\set ON_ERROR_STOP on
-- (ATTACH needs the bounds spelled out — DETACH drops them, ATTACH re-states)
ALTER TABLE events ATTACH PARTITION events_2026_09
    FOR VALUES FROM ('2026-09-01') TO ('2026-10-01');
INSERT INTO events VALUES (99, '2026-09-10', 'x');   -- routed again

-- ---------------------------------------------------------------------------
-- 4. LIST and HASH — the other two strategies
-- ---------------------------------------------------------------------------
CREATE TABLE tenants (id int NOT NULL, region text NOT NULL) PARTITION BY LIST (region);
CREATE TABLE tenants_eu PARTITION OF tenants FOR VALUES IN ('DE','FR','NL');
CREATE TABLE tenants_us PARTITION OF tenants FOR VALUES IN ('US','CA');
CREATE TABLE tenants_other PARTITION OF tenants DEFAULT;   -- catch-all
INSERT INTO tenants VALUES (1,'US'), (2,'DE'), (3,'JP');
SELECT tableoid::regclass, * FROM tenants ORDER BY id;

CREATE TABLE sessions (id bigint NOT NULL) PARTITION BY HASH (id);
CREATE TABLE sessions_0 PARTITION OF sessions FOR VALUES WITH (MODULUS 4, REMAINDER 0);
CREATE TABLE sessions_1 PARTITION OF sessions FOR VALUES WITH (MODULUS 4, REMAINDER 1);
CREATE TABLE sessions_2 PARTITION OF sessions FOR VALUES WITH (MODULUS 4, REMAINDER 2);
CREATE TABLE sessions_3 PARTITION OF sessions FOR VALUES WITH (MODULUS 4, REMAINDER 3);
INSERT INTO sessions SELECT g FROM generate_series(1, 1000) g;
SELECT tableoid::regclass, count(*) FROM sessions GROUP BY 1 ORDER BY 1;

-- ---------------------------------------------------------------------------
-- 5. Indexes on partitioned parents cascade to all partitions
-- ---------------------------------------------------------------------------
CREATE INDEX events_kind_idx ON events (kind);
-- -> one index per partition (check pg_indexes). Planner merges them.
-- CREATE INDEX ... ONLY ON parent (single-partition index) is the escape
-- hatch for special cases. CONCURRENTLY works on PG14+ partitioned parents.

-- Automation note: PostgreSQL does NOT create future partitions. Real
-- systems use cron/pg_cron/pg_partman or app-side migration jobs to stay
-- ahead of the clock (the #1 partitioning operational incident is "we ran
-- out of partitions at 00:01 on the 1st").

-- TAKEAWAYS
-- * Partition key must join the PK/unique constraints.
-- * Pruning = don't scan what your WHERE already excludes (static AND
--   runtime). Queries without the key pay the multi-partition tax.
-- * Retention by DROP/DETACH: the whole point for time-series.
-- * Automate partition creation ahead of time — the calendar doesn't wait.

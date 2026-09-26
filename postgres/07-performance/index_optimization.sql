-- ============================================================================
-- 07-performance/index_optimization.sql — index lifecycle in production
-- ============================================================================
-- Run:  make sql FILE=07-performance/index_optimization.sql
--
-- Creating indexes is easy; keeping the RIGHT set is engineering:
--   * every index taxes every write on its columns (measured in 04)
--   * unused indexes = pure waste (disk, cache pollution, write amplification)
--   * CONCURRENTLY builds without blocking writes (and its failure modes)
--   * REINDEX / REINDEX CONCURRENTLY for bloated or corrupted indexes
--   * pg_stat_user_indexes.idx_scan tells you what's actually used
-- ============================================================================

\set ON_ERROR_STOP on
\timing on
DROP SCHEMA IF EXISTS m07_idx CASCADE;
CREATE SCHEMA m07_idx;
SET search_path TO m07_idx, public;

CREATE TABLE events (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    kind text NOT NULL,
    user_id int NOT NULL,
    payload text NOT NULL DEFAULT repeat('p', 100)
);
INSERT INTO events (kind, user_id)
SELECT 'k' || (g % 20), 1 + (g::bigint * 7919) % 50000
FROM generate_series(1, 500000) g;

-- ---------------------------------------------------------------------------
-- 1. CREATE INDEX vs CREATE INDEX CONCURRENTLY
-- ---------------------------------------------------------------------------
-- Plain CREATE INDEX takes SHARE lock: READS continue, but INSERT/UPDATE/
-- DELETE on the table BLOCK for the whole build. On a hot table that's an
-- outage. Try the timing of the plain build here (1s on lab data; minutes
-- in prod):
\timing on
CREATE INDEX events_user_idx ON events (user_id);

-- CONCURRENTLY: builds in TWO table scans + waits for concurrent tx to
-- finish; writes proceed (briefly weaker lock phases). Costs: slower build,
-- and it CANNOT run inside a transaction block:
CREATE INDEX CONCURRENTLY events_kind_idx ON events (kind);
-- psql gotcha: since CONCURRENTLY can't be in a tx, any migration tool that
-- wraps everything in BEGIN must special-case it (golang-migrate, goose all
-- have escape hatches — 12-production/migrations).

-- FAILURE MODE you will meet: if CREATE INDEX CONCURRENTLY is interrupted,
-- it leaves an INVALID index (built but not usable, still maintained!):
--   SELECT relname FROM pg_class, pg_index
--   WHERE pg_index.indexrelid = pg_class.oid AND NOT pg_index.indisvalid;
-- Fix: DROP INDEX CONCURRENTLY and retry (or REINDEX CONCURRENTLY).

-- ---------------------------------------------------------------------------
-- 2. Is this index earning its keep? Ask the statistics.
-- ---------------------------------------------------------------------------
-- Run some queries to generate scans:
SELECT count(*) FROM events WHERE user_id = 42;
SELECT count(*) FROM events WHERE kind = 'k7';

-- idx_scan counts scans SINCE LAST STATS RESET (per-table, cluster-wide):
SELECT indexrelname, idx_scan, pg_size_pretty(pg_relation_size(indexrelid)) AS size
FROM pg_stat_user_indexes
WHERE schemaname = 'm07_idx' AND relname = 'events'
ORDER BY idx_scan DESC;
-- The PRIMARY KEY index shows scans from our queries. An index with
-- idx_scan=0 for weeks on a busy table is a DROP candidate (cache + write
-- savings) — coordinate with owners first, then:
--   DROP INDEX CONCURRENTLY events_kind_idx;   (also can't run in a tx)

-- ---------------------------------------------------------------------------
-- 3. Redundancy: (a) is covered by (a, b)
-- ---------------------------------------------------------------------------
CREATE INDEX events_a ON events (user_id);
CREATE INDEX events_a_b ON events (user_id, kind);
-- A query on user_id alone can use (user_id, kind): events_a is redundant:
EXPLAIN (COSTS OFF) SELECT count(*) FROM events WHERE user_id = 42;
EXPLAIN (COSTS OFF) SELECT count(*) FROM events WHERE user_id = 42 AND kind = 'k3';
DROP INDEX events_a;   -- the narrow one goes
-- (Exception: keep a narrow UNIQUE index if the constraint needs exactly it.)

-- ---------------------------------------------------------------------------
-- 4. REINDEX: fixing bloat/corruption without an exclusive lock
-- ---------------------------------------------------------------------------
-- Plain REINDEX locks writes; PG12+ has REINDEX CONCURRENTLY:
--   REINDEX INDEX CONCURRENTLY events_user_idx;
-- When: index bloat after mass UPDATE/DELETE (bloat.sql measures it),
-- or "index is not a btree" corruption after crashes (rare, but real).
SELECT pg_size_pretty(pg_relation_size('events_user_idx')) AS current_size;

-- ---------------------------------------------------------------------------
-- 5. The write tax, visible in one number
-- ---------------------------------------------------------------------------
\timing on
-- Insert with 2 secondary indexes vs with 6 — same rows:
CREATE INDEX tmp1 ON events (kind, user_id);
CREATE INDEX tmp2 ON events (user_id, kind);
CREATE INDEX tmp3 ON events (payload);
CREATE INDEX tmp4 ON events (payload, kind);
INSERT INTO events (kind, user_id) SELECT 'bulk', g % 50000 FROM generate_series(1, 20000) g;
DROP INDEX tmp1, tmp2, tmp3, tmp4;

INSERT INTO events (kind, user_id) SELECT 'bulk', g % 50000 FROM generate_series(1, 20000) g;
-- Compare the two INSERT timings psql printed: ~6 indexes vs 2 on the same
-- write. Multiply by your production write rate and index count.

-- TAKEAWAYS
-- * CREATE INDEX CONCURRENTLY for anything near production traffic; handle
-- * its invalid-on-failure state.
-- * Audit with pg_stat_user_indexes: idx_scan=0 = DROP candidate.
-- * (a) inside (a,b) is dead weight; UNIQUE needs exactly its own index.
-- * REINDEX CONCURRENTLY exists for bloat/corruption without locking writes.

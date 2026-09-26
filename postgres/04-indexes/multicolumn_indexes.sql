-- ============================================================================
-- 04-indexes/multicolumn_indexes.sql — column order is a design decision
-- ============================================================================
-- Run:  make demo  &&  make sql FILE=04-indexes/multicolumn_indexes.sql
--
-- A btree on (a, b, c) sorts rows by a, THEN b, THEN c — like a phone book
-- sorted by (lastname, firstname). Consequences:
--   * equality on a (or a+b)          -> usable
--   * equality on b alone             -> NOT usable (scattered across a's)
--   * range on a + anything on b      -> only "a" part narrows the range
--   * ORDER BY a, b                   -> sorted output free of a Sort node
-- The leftmost-prefix rule governs everything. Watch it live:
-- ============================================================================

\set ON_ERROR_STOP on
\timing on
SET search_path TO demo, public;

DROP TABLE IF EXISTS m04_multi CASCADE;
CREATE TABLE m04_multi (
    id      bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant  int  NOT NULL,
    status  text NOT NULL,
    created timestamptz NOT NULL,
    note    text NOT NULL DEFAULT 'n'
);
INSERT INTO m04_multi (tenant, status, created)
SELECT 1 + (g % 50),
       (ARRAY['new','open','done'])[1 + g % 3],
       now() - ((g % 300000) || ' seconds')::interval
FROM generate_series(1, 1000000) g;

CREATE INDEX m04_multi_tenant_status_created
    ON m04_multi (tenant, status, created);
ANALYZE m04_multi;

-- ---------------------------------------------------------------------------
-- EXPERIMENT 1: the leftmost rule
-- ---------------------------------------------------------------------------
-- (a=) — leading column equality: perfect:
EXPLAIN (COSTS OFF) SELECT count(*) FROM m04_multi WHERE tenant = 7;

-- (a=, b=) — two leading columns: even better:
EXPLAIN (COSTS OFF) SELECT count(*) FROM m04_multi WHERE tenant = 7 AND status = 'open';

-- (a=, b=, c range) — the FULL design of this index pays off:
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF)
SELECT count(*) FROM m04_multi
WHERE tenant = 7 AND status = 'open' AND created > now() - interval '1 hour';

-- (b=) — NON-leading column: index useless (each of 50 tenants' sections
-- contains 'open' rows):
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF)
SELECT count(*) FROM m04_multi WHERE status = 'open';

-- ---------------------------------------------------------------------------
-- EXPERIMENT 2: range on the MIDDLE column breaks the rest
-- ---------------------------------------------------------------------------
-- Range on b stops c from helping:
EXPLAIN (COSTS OFF)
SELECT count(*) FROM m04_multi
WHERE tenant = 7 AND status > 'open' AND created > now() - interval '1 hour';
-- Only tenant + status-range narrow it; 'created' can't be used within the
-- index — the planner may still filter with it (Filter:), reading more rows.
-- RULE: put equality columns FIRST, your ONE range/ORDER BY column LAST.

-- ---------------------------------------------------------------------------
-- EXPERIMENT 3: ORDER BY and LIMIT — the index as a pre-sorted stream
-- ---------------------------------------------------------------------------
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF)
SELECT * FROM m04_multi
WHERE tenant = 7 AND status = 'open'
ORDER BY created DESC
LIMIT 10;
-- No Sort node: rows arrive newest-first from the index, stop after 10.
-- (DESC works because btree can be scanned backwards; mixed ASC/DESC needs
-- matching index order: (tenant, status, created DESC).)

-- And the WRONG order for the same query (status/tenant swapped) forces a
-- full sort of all matching rows before LIMIT can stop:
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF)
SELECT * FROM m04_multi
WHERE tenant = 7 AND status = 'open'
ORDER BY created DESC
LIMIT 10;
-- (same here because our index IS the right shape — the point stands when
-- your index is (created, tenant, status): run that variant yourself:)

-- CREATE INDEX m04_multi_wrong ON m04_multi (created, tenant, status);
-- EXPLAIN ANALYZE ... ORDER BY created DESC LIMIT 10;  -> Sort? No! index
-- helps ORDER BY but the tenant=7 filter becomes a Filter over the whole
-- scan. One index cannot serve every access pattern: pick by your queries.

-- ---------------------------------------------------------------------------
-- EXPERIMENT 4: how many indexes is too many? (write amplification, measured)
-- ---------------------------------------------------------------------------
\timing on
-- Baseline insert with ONE index (plus pkey):
INSERT INTO m04_multi (tenant, status, created)
SELECT 1 + (g % 50), 'new', now() FROM generate_series(1, 20000) g;

CREATE INDEX m04_multi_s2 ON m04_multi (status);
CREATE INDEX m04_multi_s3 ON m04_multi (created);
CREATE INDEX m04_multi_s4 ON m04_multi (tenant);
ANALYZE m04_multi;

-- Same insert now maintaining FOUR secondary indexes:
INSERT INTO m04_multi (tenant, status, created)
SELECT 1 + (g % 50), 'new', now() FROM generate_series(1, 20000) g;
-- Compare the two INSERT timings psql printed. On this box it's roughly
-- 2x; on write-heavy services with wide indexes it's much worse.
--
-- Also: UPDATE only touches indexes whose columns changed (plus HOT updates
-- may skip index maintenance entirely — 07-performance/vacuum.sql).

-- Drop the strays so later modules stay honest:
DROP INDEX m04_multi_s2, m04_multi_s3, m04_multi_s4;

-- ---------------------------------------------------------------------------
-- Redundancy rules of thumb:
--   * (a) is subsumed by (a, b): drop the narrower one (rare exceptions for
--     covering narrowness/HOT). Check with pg_stats + real plans.
--   * id columns already have the pkey btree; don't re-index them.
--   * FK child columns: index them unless you NEVER delete/update parents.
-- ============================================================================

-- TAKEAWAYS
-- * Leftmost prefix rules usability: design order = equality columns first,
--   range/order column last.
-- * A range in the middle strands everything after it.
-- * Index-as-sorted-stream (ORDER BY + LIMIT) is a top-10 query pattern.
-- * Every index taxes every write — measure with your own INSERT timings.

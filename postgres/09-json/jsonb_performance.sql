-- ============================================================================
-- 09-json/jsonb_performance.sql — document size, TOAST, update economics
-- ============================================================================
-- Run:  make sql FILE=09-json/jsonb_performance.sql
--
-- The performance physics of jsonb:
--   * a jsonb column stores the WHOLE document in one varlena value
--   * big values get TOASTed (compressed/out-of-line) — every read that
--     needs ANY field pays decompression + detoast CPU
--   * any edit rewrites the WHOLE document (MVCC) — a 10KB doc edited per
--     field-fragment 10KB of WAL and dead tuples
-- Compare with the alternatives: hot fields promoted to columns, and
-- generated columns (11-advanced) that keep ONE source of truth.
-- ============================================================================

\set ON_ERROR_STOP on
\timing on
DROP SCHEMA IF EXISTS m09_perf CASCADE;
CREATE SCHEMA m09_perf;
SET search_path TO m09_perf, public;

-- 200k "large-ish" docs (payload text ~3KB each):
CREATE TABLE docs (
    id       bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant   int NOT NULL,
    data     jsonb NOT NULL
);
INSERT INTO docs (tenant, data)
SELECT g % 100,
       jsonb_build_object(
           'tenant', g % 100,
           'filler', repeat('f', 3000)
       )
FROM generate_series(1, 200000) g;
ANALYZE docs;

SELECT pg_size_pretty(pg_total_relation_size('docs')) AS table_size;

-- ---------------------------------------------------------------------------
-- 1. Single-field filtering on the doc vs a REAL column
-- ---------------------------------------------------------------------------
\timing on
SELECT count(*) FROM docs WHERE data @> '{"tenant": 5}';        -- GIN-able but heavy docs
CREATE INDEX ON docs (tenant);
ANALYZE docs;
SELECT count(*) FROM docs WHERE tenant = 5;                     -- tiny btree + narrow rows
-- \timing shows the gap. Every doc-approach row read pays TOAST decompress.

-- ---------------------------------------------------------------------------
-- 2. TOAST mechanics, visible: the filler is compressible and out-of-line
-- ---------------------------------------------------------------------------
SELECT pg_column_size(data)  AS doc_bytes_in_row,
       pg_column_compression(data) AS compression
FROM docs LIMIT 1;
-- repeat('f') compresses extremely well; random payload compresses worse.
-- The classic trap: docs whose FILLER dominates — every query touching the
-- row detoasts the whole thing for one small field.

-- ---------------------------------------------------------------------------
-- 3. Update economics: doc-update rewrites EVERYTHING
-- ---------------------------------------------------------------------------
\timing on
-- Promote a counter INSIDE a 3KB document, 50k times:
UPDATE docs SET data = jsonb_set(data, '{tenant}', ((data ->> 'tenant')::int + 1)::text::jsonb)
WHERE id <= 50000;
-- ~50k x (new full doc + old doc becomes dead). Wall time + WAL tell the
-- story; check bloat after:
SELECT n_dead_tup FROM pg_stat_user_tables WHERE relid = 'm09_perf.docs'::regclass;

-- Same logical update against a narrow COLUMN:
VACUUM docs;
UPDATE docs SET tenant = tenant + 1 WHERE id <= 50000;
-- Notably faster: 4-byte column delta vs 3KB doc rewrite (plus HOT updates
-- possible when no indexed COLUMN changed — impossible for jsonb blobs).

-- ---------------------------------------------------------------------------
-- 4. The hybrid (the pattern that wins in production):
--    document as source of truth + generated columns for the hot fields
-- ---------------------------------------------------------------------------
CREATE TABLE docs_hybrid (
    id       bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    data     jsonb NOT NULL,
    -- generated columns are IMMUTABLE expressions over the row: maintained
    -- by the server on write, indexable, and queryable as normal columns:
    tenant   int  GENERATED ALWAYS AS ((data ->> 'tenant')::int) STORED,
    status   text GENERATED ALWAYS AS (data ->> 'status') STORED
);
INSERT INTO docs_hybrid (data)
SELECT jsonb_build_object('tenant', g % 100, 'status', 'live') FROM generate_series(1, 100000) g;
ANALYZE docs_hybrid;

CREATE INDEX docs_hybrid_tenant ON docs_hybrid (tenant);
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF)
SELECT count(*) FROM docs_hybrid WHERE tenant = 5;
-- Fast column access; the doc stays canonical; no dual-write drift possible.
-- (Full treatment: 11-advanced/generated_columns.)

-- ---------------------------------------------------------------------------
-- 5. jsonb vs columns vs docs-at-scale, honest summary
-- ---------------------------------------------------------------------------
--   schema known & relational  -> COLUMNS. Always. jsonb is not "modern".
--   true schema variability    -> jsonb doc + GIN + promoted/generated fields
--   append-only audit payloads -> json (verbatim) or jsonb, rarely queried
--   per-field heavy editing     -> NEVER one giant doc; split or promote
-- ============================================================================

-- TAKEAWAYS
-- * Big jsonb = TOAST = per-read detoast tax; don't let filler dominate.
-- * Any doc edit rewrites the whole value (MVCC): churn = bloat + WAL.
-- * Hybrid (doc + generated columns + btree on generated) gives you both
-- * worlds with one source of truth.
-- * Measure with pg_column_size, \timing, and pg_stat_user_tables.

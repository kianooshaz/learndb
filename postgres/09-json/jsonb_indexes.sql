-- ============================================================================
-- 09-json/jsonb_indexes.sql — making document queries index-served
-- ============================================================================
-- Run:  make sql FILE=09-json/jsonb_indexes.sql
--
-- Three index strategies, three jobs:
--   A. GIN on the whole column (jsonb_ops)   -> @> ? ?| ?& anywhere in doc
--   B. GIN with jsonb_path_ops               -> smaller/faster @> ONLY
--   C. btree EXPRESSION indexes              -> one hot promoted field
--   (+ partial index on a jsonb predicate — bonus)
-- ============================================================================

\set ON_ERROR_STOP on
\timing on
DROP SCHEMA IF EXISTS m09_idx CASCADE;
CREATE SCHEMA m09_idx;
SET search_path TO m09_idx, public;

CREATE TABLE docs (id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY, data jsonb NOT NULL);
INSERT INTO docs (data)
SELECT jsonb_build_object(
           'tenant', 't' || (g % 50),
           'status', (ARRAY['draft','live','archived'])[1 + g % 3],
           'tags', jsonb_build_array('tag' || (g % 25)),
           'author', jsonb_build_object('id', g % 5000, 'name', 'n' || g % 100)
       )
FROM generate_series(1, 300000) g;
ANALYZE docs;

-- Baseline (no index): containment = full scan:
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF)
SELECT count(*) FROM docs WHERE data @> '{"status": "live"}';

-- ---------------------------------------------------------------------------
-- A. GIN jsonb_ops: all containment/existence operators
-- ---------------------------------------------------------------------------
CREATE INDEX docs_gin ON docs USING gin (data);
ANALYZE docs;
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF)
SELECT count(*) FROM docs WHERE data @> '{"status": "live"}';
-- Bitmap scan. Deep containment works with the same index:
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF)
SELECT count(*) FROM docs WHERE data @> '{"author": {"id": 42}}';
-- And the existence operators (jsonb_path_ops CANNOT serve these):
EXPLAIN (COSTS OFF) SELECT count(*) FROM docs WHERE data ? 'tenant';

-- ---------------------------------------------------------------------------
-- B. GIN jsonb_path_ops: @> only, ~30-50% smaller, often faster
-- ---------------------------------------------------------------------------
CREATE INDEX docs_gin_path ON docs USING gin (data jsonb_path_ops);
ANALYZE docs;
SELECT relname, pg_size_pretty(pg_relation_size(oid)) AS size
FROM pg_class WHERE relname IN ('docs_gin','docs_gin_path');
-- The planner may pick either for @>; both are correct. Trade: path_ops
-- indexes complete paths+values as hashes — small and exact for @>, useless
-- for ? / ?| / ?&.

-- ---------------------------------------------------------------------------
-- C. btree expression index: one hot field, classic SQL performance
-- ---------------------------------------------------------------------------
CREATE INDEX docs_tenant_expr ON docs ((data ->> 'tenant'));
ANALYZE docs;
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF)
SELECT count(*) FROM docs WHERE data ->> 'tenant' = 't7';
-- Cheaper than GIN for single-field equality: smaller entries, ordering
-- support (ORDER BY tenant!), range predicates (btree semantics).
-- The match rule from 04-indexes/expression_indexes.sql applies verbatim:
-- queries must write data ->> 'tenant' EXACTLY like this.

-- Multi-column with a promoted field — tenant + document containment in
-- ONE index (btree_gin lets scalars live inside GIN):
CREATE INDEX docs_tenant_gin ON docs USING gin ((data ->> 'tenant'), data);
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF)
SELECT count(*) FROM docs
WHERE data ->> 'tenant' = 't7' AND data @> '{"status": "live"}';

-- ---------------------------------------------------------------------------
-- D. Partial GIN: index only the hot slice (e.g., live docs)
-- ---------------------------------------------------------------------------
DROP INDEX docs_gin;   -- keep the demo honest (path_ops still covers @>)
CREATE INDEX docs_live_gin ON docs USING gin (data) WHERE data @> '{"status": "live"}';
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF)
SELECT count(*) FROM docs WHERE data @> '{"status": "live"}' AND data ? 'tenant';
-- Only 'live' documents entered the index: smaller, hotter. The query must
-- imply the index predicate (same rules as 04/partial_indexes).

-- Decision cheat sheet:
--   unknown schema, many query shapes      -> GIN jsonb_ops (default)
--   only @> containment, big docs          -> jsonb_path_ops
--   one hot field                          -> btree expression (or generated
--                                             column: 11-advanced)
--   one dominant slice of documents        -> partial GIN
-- ============================================================================

-- TAKEAWAYS
-- * GIN ops vs path_ops: all operators vs @>-only-but-leaner.
-- * Promoted-field btree beats GIN for single-field equality + ORDER BY.
-- * btree_gin composes scalar + jsonb containment in one index.
-- * Partial GIN on a document predicate mirrors partial btree economics.

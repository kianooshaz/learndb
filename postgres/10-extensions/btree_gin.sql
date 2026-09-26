-- ============================================================================
-- 10-extensions/btree_gin.sql — scalars inside GIN composite indexes
-- ============================================================================
-- Run:  make sql FILE=10-extensions/btree_gin.sql
--
-- GIN indexes need opclasses per column type. Native GIN speaks jsonb,
-- arrays, tsvector... but NOT int/text/timestamp. btree_gin teaches the
-- scalar types GIN equality — enabling composite indexes like:
--     GIN (tenant_id, tags)          -- tenant + array containment
--     GIN (tenant_id, data)          -- tenant + jsonb containment
-- One index answers "this tenant AND these tags", instead of bitmap-ANDing
-- two single-column indexes.
-- ============================================================================

\set ON_ERROR_STOP on
\timing on
DROP SCHEMA IF EXISTS m10_btgin CASCADE;
CREATE SCHEMA m10_btgin;
SET search_path TO m10_btgin, public;

CREATE TABLE docs (
    id        bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id int  NOT NULL,
    tags      text[] NOT NULL,
    body      jsonb NOT NULL
);
INSERT INTO docs (tenant_id, tags, body)
SELECT g % 40,
       ARRAY['t' || (g % 30)] || CASE WHEN g % 4 = 0 THEN ARRAY['hot'] ELSE ARRAY[]::text[] END,
       jsonb_build_object('kind', (ARRAY['note','task'])[1 + g % 2], 'prio', g % 5)
FROM generate_series(1, 300000) g;
ANALYZE docs;

-- The query every multi-tenant app has — tenant + tag filter:
\timing on
-- Without support, GIN can't hold tenant_id:
--   CREATE INDEX ON docs USING gin (tenant_id, tags);
--   ERROR: data type integer has no default operator class for "gin"
CREATE INDEX docs_tenant_tags ON docs USING gin (tenant_id, tags);   -- btree_gin!
ANALYZE docs;

EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF)
SELECT count(*) FROM docs
WHERE tenant_id = 7 AND tags @> ARRAY['t3'];
-- ONE index, one lookup: tenant equality (btree_gin opclass) + array
-- containment (native array GIN). Compare the alternative (bitmap AND of
-- two indexes) by creating the pair and re-running:
CREATE INDEX docs_tenant_btree ON docs (tenant_id);
CREATE INDEX docs_tags_gin ON docs USING gin (tags);
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF)
SELECT count(*) FROM docs
WHERE tenant_id = 7 AND tags @> ARRAY['t3'];
-- The planner may BitmapAnd them. The composite avoids the AND step and
-- only indexes what tenant 7 actually contains.

-- Scalar + jsonb containment in one GIN:
CREATE INDEX docs_tenant_body ON docs USING gin (tenant_id, body);
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF)
SELECT count(*) FROM docs
WHERE tenant_id = 7 AND body @> '{"kind": "task"}';

-- Limitations of btree_gin to know:
--   * equality only (no ranges/ordering — that's btree's job)
--   * scalar columns in GIN don't bring index-only scans or ORDER BY
--   * build/update costs follow normal GIN economics
-- Choose it when the composite lookup shape is your HOT query and the
-- parts are (equality-scalar + GIN-native predicate).

-- TAKEAWAYS
-- * btree_gin gives scalar types GIN equality opclasses.
-- * Enables GIN (tenant, tags/jsonb/tsvector) composites: one-lookup plans.
-- * Equality only; ranges/order still belong to btree.
-- * A real pattern for multi-tenant document/tag search services.

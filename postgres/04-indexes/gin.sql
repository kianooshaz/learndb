-- ============================================================================
-- 04-indexes/gin.sql — inverted indexes: jsonb, arrays, full-text
-- ============================================================================
-- Run:  make demo  &&  make sql FILE=04-indexes/gin.sql
--
-- GIN = Generalized Inverted iNdex. Instead of "row -> key", it maps
-- KEY COMPONENT -> list of rows containing it". That's why it answers
-- containment questions ("which documents have this key/word/element?")
-- in one lookup. Cost: bigger, slower to build/update than btree.
-- Operators: jsonb @> ? ?| ?&, array @> &&, full-text @@.
-- ============================================================================

\set ON_ERROR_STOP on
\timing on
SET search_path TO demo, public;

-- ---------------------------------------------------------------------------
-- Arrays: product tags (demo.products.tags)
-- ---------------------------------------------------------------------------
-- No index: containment over 1,000 products is instant — so let's give the
-- planner a REAL table to care about first (200k rows of tagged events):
DROP TABLE IF EXISTS m04_tagged CASCADE;
CREATE TABLE m04_tagged (
    id   bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tags text[] NOT NULL
);
INSERT INTO m04_tagged (tags)
SELECT ARRAY['t' || (g % 50)] ||
       CASE WHEN g % 3 = 0 THEN ARRAY['t' || (g % 20)] ELSE ARRAY[]::text[] END
FROM generate_series(1, 200000) g;

\timing on
SELECT count(*) FROM m04_tagged WHERE tags @> ARRAY['t7'];      -- seq scan

CREATE INDEX m04_tagged_tags_gin ON m04_tagged USING gin (tags);
ANALYZE m04_tagged;

EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF)
SELECT count(*) FROM m04_tagged WHERE tags @> ARRAY['t7'];      -- bitmap scan now
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF)
SELECT count(*) FROM m04_tagged WHERE tags && ARRAY['t7','t19']; -- overlap too

-- ---------------------------------------------------------------------------
-- jsonb: containment on the demo products' attrs
-- ---------------------------------------------------------------------------
-- Un-indexed (1,000 rows — fine, but imagine the events table):
SELECT count(*) FROM products WHERE attrs @> '{"color": "black"}';

DROP TABLE IF EXISTS m04_profiles CASCADE;
CREATE TABLE m04_profiles (id bigint PRIMARY KEY, data jsonb NOT NULL);
INSERT INTO m04_profiles
SELECT g, jsonb_build_object(
           'country', (ARRAY['US','DE','JP'])[1 + g % 3],
           'plan',    (ARRAY['free','pro','team'])[1 + g % 3],
           'devices', jsonb_build_array('d' || (g % 10), 'd' || (g % 5)))
FROM generate_series(1, 100000) g;

-- Two GIN flavors — default jsonb_ops vs jsonb_path_ops:
CREATE INDEX m04_profiles_gin        ON m04_profiles USING gin (data);          -- jsonb_ops
CREATE INDEX m04_profiles_gin_path   ON m04_profiles USING gin (data jsonb_path_ops);
ANALYZE m04_profiles;

EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF)
SELECT count(*) FROM m04_profiles WHERE data @> '{"plan": "pro"}';

-- jsonb_path_ops: smaller (hashes paths+values, ~30-50% smaller), faster
-- containment, but ONLY supports @> (no ? / ?| / ?&):
SELECT relname, pg_size_pretty(pg_relation_size(oid)) AS size
FROM pg_class
WHERE relname IN ('m04_profiles_gin','m04_profiles_gin_path');

-- ---------------------------------------------------------------------------
-- Key existence operators only work with the default jsonb_ops:
-- ---------------------------------------------------------------------------
EXPLAIN (COSTS OFF) SELECT count(*) FROM m04_profiles WHERE data ? 'plan';
-- (uses m04_profiles_gin; jsonb_path_ops can't serve this)

-- ---------------------------------------------------------------------------
-- Full-text search (11-advanced/full_text_search/ goes deeper):
-- ---------------------------------------------------------------------------
DROP TABLE IF EXISTS m04_docs CASCADE;
CREATE TABLE m04_docs (id bigint PRIMARY KEY, body text NOT NULL);
INSERT INTO m04_docs
SELECT g, 'release notes for feature ' || g || ' performance improvements '
       || CASE WHEN g % 2 = 0 THEN 'search ranking ' ELSE '' END
FROM generate_series(1, 100000) g;

-- to_tsvector parses+stems text into (lexeme, positions):
SELECT to_tsvector('english', 'The cats quickly caught the mice');

CREATE INDEX m04_docs_fts_gin ON m04_docs USING gin (to_tsvector('english', body));
ANALYZE m04_docs;

EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF)
SELECT count(*) FROM m04_docs
WHERE to_tsvector('english', body) @@ to_tsquery('english', 'performance & feature');
-- The @@ (matches) operator over an indexed tsvector is a GIN lookup.
-- Note the index is over an EXPRESSION — queries must repeat it exactly.

-- GIN build/update mechanics worth knowing:
--  * Fast updates go through a pending list merged later (gin_pending_list_limit);
--  * BUILD on an existing table is much faster than row-by-row maintenance;
--    for bulk loads, create the index AFTER loading (same as every AM).
--  * gin_clean_pending_list() forces a merge.

-- TAKEAWAYS
-- * GIN answers CONTAINMENT (@> ? ?| && @@) — components -> rows.
-- * jsonb_path_ops: smaller/faster @>-only; jsonb_ops: all operators.
-- * Index the exact expression your queries use (to_tsvector('english', col)).
-- * Build after bulk load; expect slower writes than btree.

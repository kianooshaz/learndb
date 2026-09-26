-- ============================================================================
-- 10-extensions/pg_trgm.sql — fuzzy matching AND fast substring search
-- ============================================================================
-- Run:  make sql FILE=10-extensions/pg_trgm.sql
--
-- pg_trgm splits text into TRIGRAMS (3-char sequences) and indexes their
-- sets. Two killer features:
--   1. fuzzy: similarity('%') / word_similarity / distance ordering
--   2. indexed LIKE '%anything%' / ILIKE — which btree CANNOT do
-- Both GIN (fast lookups) and GiST (KNN ordering) opclasses ship.
-- ============================================================================

\set ON_ERROR_STOP on
\timing on
DROP SCHEMA IF EXISTS m10_trgm CASCADE;
CREATE SCHEMA m10_trgm;
SET search_path TO m10_trgm, public;

CREATE TABLE products (id int PRIMARY KEY, name text NOT NULL);
INSERT INTO products
SELECT g,
       (ARRAY['Keyboard','Keyboard','Mechanical Keyboard','Keypad',
              'Mouse','Webcam','Cable'])[1 + g % 7] || ' ' || g
FROM generate_series(1, 100000) g;
ANALYZE products;

-- Trigrams of a word (the model behind everything below):
SELECT show_trgm('keyboard');

-- ---------------------------------------------------------------------------
-- 1. Fuzzy search before indexing (see the model, feel the cost)
-- ---------------------------------------------------------------------------
SELECT similarity('keyboard', 'keybord')          AS close_typo,
       similarity('keyboard', 'mouse')            AS different;
SHOW pg_trgm.similarity_threshold;   -- 0.3 default

-- % is the "similar enough" operator (uses the threshold):
\timing on
SELECT id, name, round(similarity(name, 'keybord')::numeric, 2) AS sim
FROM products
WHERE name % 'keybord'
ORDER BY sim DESC, id
LIMIT 5;
-- Sequential scan + trigram computation per row — right answer, slow shape.

-- ---------------------------------------------------------------------------
-- 2. GIN trigram index: fuzzy AND substring, index-served
-- ---------------------------------------------------------------------------
CREATE INDEX products_name_trgm_gin ON products USING gin (name gin_trgm_ops);
ANALYZE products;

EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF)
SELECT id FROM products WHERE name % 'keybord' LIMIT 5;

-- THE headline feature: indexed leading-wildcard LIKE/ILIKE:
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF)
SELECT count(*) FROM products WHERE name ILIKE '%board 12%';
-- Before pg_trgm this could ONLY be a seq scan (04-indexes/btree.sql).

-- ---------------------------------------------------------------------------
-- 3. GiST trigram: similarity-ORDERED results straight from the index
-- ---------------------------------------------------------------------------
CREATE INDEX products_name_trgm_gist ON products USING gist (name gist_trgm_ops);
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF)
SELECT id, name, name <-> 'mechanical keybord' AS dist
FROM products
ORDER BY name <-> 'mechanical keybord'        -- KNN: index delivers order
LIMIT 5;
-- GIN can filter; only GiST can ORDER BY distance without sorting all
-- candidates (04-indexes/gist.sql covers the mechanics).

-- word_similarity: prefix containment ("is X similar to a WORD in Y"):
SELECT word_similarity('keyb', 'mechanical keyboard') AS word_sim,
       'mechanical keyboard' <% 'keyb'                AS strict_word_similar;

-- unaccent interplay: strip diacritics before matching (extension loaded):
SELECT unaccent('Piña Colada'), similarity(unaccent('pina colada'), unaccent('Piña Colada'));

-- ---------------------------------------------------------------------------
-- GIN vs GiST for trigrams (the honest trade):
--   GIN : bigger, slower updates, faster exact filtering — mostly static
--   GiST: smaller, faster updates, KNN ordering — churny data + ranking
-- ============================================================================

-- TAKEAWAYS
-- * % + similarity_threshold = typo-tolerant filtering; <-> = ranked KNN.
-- * gin_trgm_ops makes LIKE '%x%' / ILIKE indexable — the unique superpower.
-- * GiST for distance ordering; GIN for pure filtering on stable data.
-- * Tune pg_trgm.similarity_threshold per query/role (lower = more results).

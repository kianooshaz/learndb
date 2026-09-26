-- ============================================================================
-- 11-advanced/full_text_search/basics.sql — real search, no external engine
-- ============================================================================
-- Run:  make sql FILE=11-advanced/full_text_search/basics.sql
--
-- PostgreSQL FTS pipeline: text -> to_tsvector (parse, stem, positions)
-- matched against to_tsquery (language-aware terms). GIN indexes the
-- tsvector. Ranking (ts_rank), highlighting (ts_headline), weights, and
-- dictionaries ship built-in. Often "good enough" to skip Elasticsearch.
-- ============================================================================

\set ON_ERROR_STOP on
\timing on
DROP SCHEMA IF EXISTS m11_fts CASCADE;
CREATE SCHEMA m11_fts;
SET search_path TO m11_fts, public;

-- The core transformation: stemming + stop words, per LANGUAGE config:
SELECT to_tsvector('english', 'The cats were quickly chasing the mice');
-- 'cat':2 'chase':5 'quickli':4 'mice':6  (the/were dropped, stems folded)
SELECT to_tsquery('english', 'cat & chase');          -- AND
SELECT plainto_tsquery('english', 'cats chasing');    -- user input -> AND terms
SELECT phraseto_tsquery('english', 'quickly chasing');-- phrase (adjacent)

-- Matching operator @@ :
SELECT to_tsvector('english', 'The cats quickly caught the mice')
       @@ to_tsquery('english', 'cat & catch') AS matches;

-- ---------------------------------------------------------------------------
-- Realistic corpus + weighted, indexed search
-- ---------------------------------------------------------------------------
CREATE TABLE articles (
    id      bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    title   text NOT NULL,
    body    text NOT NULL
);
INSERT INTO articles (title, body)
SELECT 'PostgreSQL release notes ' || g,
       CASE g % 3
         WHEN 0 THEN 'Performance improvements in query planning and parallel scans'
         WHEN 1 THEN 'Security fixes for authentication and row level policies'
         ELSE 'Bug fixes for replication and vacuum in large clusters'
       END || ' edition ' || g
FROM generate_series(1, 200000) g;

-- Weighted vector: A=title, B/C/D body zones (rank tuning later). Stored as
-- a real column for index reuse — or computed per query if you prefer:
ALTER TABLE articles ADD COLUMN search tsvector
    GENERATED ALWAYS AS (
        setweight(to_tsvector('english', title), 'A') ||
        setweight(to_tsvector('english', body), 'B')
    ) STORED;

CREATE INDEX articles_search_gin ON articles USING gin (search);
ANALYZE articles;

-- The production query (as a parameterized statement from Go):
\timing on
SELECT id, title,
       ts_rank(search, q) AS rank,
       ts_headline('english', body, q, 'MinWords=5, MaxWords=15') AS snippet
FROM articles, plainto_tsquery('english', 'performance improvements planning') q
WHERE search @@ q
ORDER BY rank DESC
LIMIT 5;
-- Index-served containment + rank-ordered top-N. Verify the plan shape:
EXPLAIN (COSTS OFF)
SELECT id FROM articles
WHERE search @@ plainto_tsquery('english', 'performance improvements planning');

-- Phrase search (adjacency matters):
SELECT count(*) FROM articles
WHERE search @@ phraseto_tsquery('english', 'query planning');

-- Prefix matching (search-as-you-type), combine with ranking:
SELECT count(*) FROM articles
WHERE search @@ to_tsquery('english', 'replicat:*');

-- Multi-language: config per row/column (store the config name, use it):
SELECT to_tsvector('german', 'Die Katzen jagten die Mäuse');

-- FTS vs the neighbors (each has a file in this lab):
--   LIKE '%x%' / ILIKE : raw substrings; needs pg_trgm to scale (10/pg_trgm)
--   pg_trgm similarity : typo tolerance ("postgersql")
--   FTS (this)         : meaning-aware words, phrases, ranking, weights
-- Combine them (union) for a forgiving production search box.

-- TAKEAWAYS
-- * to_tsvector/to_tsquery + @@ + GIN = indexed language-aware search.
-- * Weights (A>B>C>D) tune title-over-body ranking; ts_rank orders.
-- * phraseto for exact phrases; prefix:* for autocomplete.
-- * Generated tsvector column = one pipeline, consistently indexed.

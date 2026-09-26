-- ============================================================================
-- 09-json/json_queries.sql — querying documents like a pro
-- ============================================================================
-- Run:  make sql FILE=09-json/json_queries.sql
--
-- Realistic event-sourcing-ish queries over jsonb documents: expansion,
-- aggregation into documents, SQL/JSON path (PG12+), and the patterns that
-- keep json queries maintainable in a codebase.
-- ============================================================================

\set ON_ERROR_STOP on
\timing on
DROP SCHEMA IF EXISTS m09_q CASCADE;
CREATE SCHEMA m09_q;
SET search_path TO m09_q, public;

CREATE TABLE events (
    id     bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    type   text NOT NULL,
    at     timestamptz NOT NULL,
    body   jsonb NOT NULL
);
INSERT INTO events (type, at, body)
SELECT (ARRAY['page_view','add_to_cart','checkout'])[1 + g % 3],
       now() - ((g * 13) || ' minutes')::interval,
       jsonb_build_object(
           'user', 'u' || (g % 500),
           'page', '/p/' || (g % 40),
           'amount', CASE WHEN g % 3 = 2 THEN (g % 300)::text ELSE NULL END,
           'device', jsonb_build_object('os', (ARRAY['ios','android'])[1 + g % 2],
                                        'lang', 'en')
       )
FROM generate_series(1, 200000) g;
ANALYZE events;

-- ---------------------------------------------------------------------------
-- 1. Scalar promotion: pull hot fields into typed SQL expressions
-- ---------------------------------------------------------------------------
SELECT count(*), sum((body ->> 'amount')::numeric)
FROM events
WHERE type = 'checkout'
  AND (body ->> 'amount') IS NOT NULL;
-- ->> gives text; cast inside aggregates. NULL-safe: filter first.

-- ---------------------------------------------------------------------------
-- 2. jsonb_array_elements: expand arrays into rows (the unnest of jsonb)
-- ---------------------------------------------------------------------------
-- Multi-item carts in a single event:
CREATE TABLE carts (id int PRIMARY KEY, items jsonb NOT NULL);
INSERT INTO carts VALUES
 (1, '[{"sku":"A","qty":2,"price":10},{"sku":"B","qty":1,"price":25}]'),
 (2, '[{"sku":"C","qty":5,"price":3}]');

SELECT c.id,
       (item ->> 'sku')  AS sku,
       (item ->> 'qty')::int AS qty,
       (item ->> 'qty')::int * (item ->> 'price')::numeric AS line_total
FROM carts c
CROSS JOIN LATERAL jsonb_array_elements(c.items) AS item(value);
-- LATERAL keeps the correlation explicit (03-queries/lateral.sql).

-- ---------------------------------------------------------------------------
-- 3. Aggregating rows BACK into documents
-- ---------------------------------------------------------------------------
-- Rebuild a compact per-cart doc:
SELECT c.id,
       jsonb_build_object(
           'n_items', sum((item ->> 'qty')::int),
           'total',   sum((item ->> 'qty')::int * (item ->> 'price')::numeric),
           'skus',    jsonb_agg(item ->> 'sku' ORDER BY item ->> 'sku')
       ) AS receipt
FROM carts c
CROSS JOIN LATERAL jsonb_array_elements(c.items) AS item(value)
GROUP BY c.id ORDER BY c.id;

-- jsonb_object_agg: key-value pairs from rows:
SELECT jsonb_object_agg(type, n) FROM
    (SELECT type, count(*) n FROM events GROUP BY type) s;

-- ---------------------------------------------------------------------------
-- 4. SQL/JSON path (PG12+): jsonpath language for deep/typed queries
-- ---------------------------------------------------------------------------
-- Path variables: $ = the document, .key access, .keyvalue/type filters.
-- jsonb_path_exists / _query / _query_first, all GIN-indexable with
-- jsonb_path_ops:
SELECT jsonb_path_query_first(
           body,
           '$.device.os ? (@ == "ios")'
       ) AS os_ios_marker
FROM events WHERE id = 1;

-- Filters with comparisons — amount > 200 as a NUMBER (path language is
-- typed, no casting text):
SELECT count(*)
FROM events
WHERE jsonb_path_exists(body, '$.amount ? (@ > 200)');

-- Returning matched subvalues:
SELECT DISTINCT jsonb_path_query(body, '$.page') AS hot_page
FROM events
WHERE type = 'page_view'
ORDER BY 1 LIMIT 5;

-- ---------------------------------------------------------------------------
-- 5. EXISTS + containment vs plain filtering (readability + indexability)
-- ---------------------------------------------------------------------------
-- Same result three ways (jsonb_indexes.sql compares plans):
SELECT count(*) FROM events WHERE body @> '{"device": {"os": "ios"}}';
SELECT count(*) FROM events WHERE body -> 'device' ->> 'os' = 'ios';
SELECT count(*) FROM events WHERE jsonb_path_exists(body, '$.device.os == "ios"');
-- @> is the GIN-served form; ->> chains scan+filter; jsonpath is the most
-- expressive. Choose by index + team readability.

-- TAKEAWAYS
-- * Promote hot scalars with ->> + cast; arrays expand via jsonb_array_elements.
-- * jsonb_build_object/agg/object_agg assemble API documents in one query.
-- * jsonpath ($) gives typed deep queries — learn it once, use everywhere.
-- * For index-served filtering, @> (or jsonpath) beats ->> chains.

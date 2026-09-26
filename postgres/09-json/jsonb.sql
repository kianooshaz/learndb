-- ============================================================================
-- 09-json/jsonb.sql — the binary document type: operators and editing
-- ============================================================================
-- Run:  make sql FILE=09-json/jsonb.sql
--
-- jsonb = parsed, decomposed binary: keys sorted, duplicates collapsed,
-- whitespace gone. You get equality, containment, indexing (GIN), and an
-- editing toolbox. You pay: slower writes, no original formatting, and
-- MVCC-rewrites on every document update (jsonb_performance.sql measures).
-- ============================================================================

\set ON_ERROR_STOP on
\timing on
DROP SCHEMA IF EXISTS m09_jsonb CASCADE;
CREATE SCHEMA m09_jsonb;
SET search_path TO m09_jsonb, public;

CREATE TABLE profiles (id int PRIMARY KEY, data jsonb NOT NULL);
INSERT INTO profiles VALUES
 (1, '{"name": "Ada", "plan": "pro", "tags": ["beta", "vip"],
       "address": {"city": "London", "zip": "E1"},
       "login_at": "2026-09-25T10:00:00Z"}'),
 (2, '{"name": "Bob", "plan": "free", "tags": [],
       "address": {"city": "Berlin"},
       "login_at": "2026-09-20T08:00:00Z"}');

-- ---------------------------------------------------------------------------
-- Reading: the operator ladder
-- ---------------------------------------------------------------------------
SELECT data ->  'plan'            AS jsonb_form,     -- '"pro"' (jsonb)
       data ->> 'plan'            AS text_form,      -- 'pro'
       data #>  '{address,city}'  AS deep_jsonb,
       data #>> '{address,city}'  AS deep_text
FROM profiles WHERE id = 1;

-- Types survive as jsonb kinds; ->> always gives TEXT — cast for math:
SELECT jsonb_typeof(data -> 'tags') AS tags_kind,       -- 'array'
       jsonb_typeof(data -> 'missing') AS missing_kind, -- NULL
       (data #>> '{address,zip}') IS NULL AS absent_is_null,
       (data ->> 'login_at')::timestamptz AS casted_ts
FROM profiles WHERE id = 1;

-- ---------------------------------------------------------------------------
-- Predicates: containment and existence (the GIN-indexable set)
-- ---------------------------------------------------------------------------
SELECT data @> '{"plan": "pro"}'            AS contains_exact_kv,
       data @> '{"tags": ["beta"]}'         AS contains_array_elem,
       data ? 'name'                        AS top_key_exists,
       data ?| ARRAY['pets','plan']         AS any_key_exists,
       data ?& ARRAY['name','plan']         AS all_keys_exist
FROM profiles WHERE id = 1;
-- @> semantics: arrays match SUBSETS, objects match PARTIALLY (nested).
-- ? only checks TOP-LEVEL keys (use a path/expression for depth).

-- ---------------------------------------------------------------------------
-- Editing: every operation returns a NEW document (immutability + MVCC)
-- ---------------------------------------------------------------------------
SELECT jsonb_set(data, '{plan}', '"enterprise"')                 AS updated_plan,
       jsonb_set(data, '{address,zip}', '"10435"', true)         AS set_nested,
       jsonb_set(data, '{nickname}', '"AC"', false)              AS no_create_when_absent,
       data || '{"plan": "team"}'::jsonb                         AS shallow_merge,
       data - 'tags'                                             AS key_removed,
       data #- '{address,zip}'                                   AS path_removed
FROM profiles WHERE id = 1;
-- CRITICAL: these are expressions, not in-place mutations. An UPDATE writes
-- a WHOLE new document version (and old one becomes a dead tuple):
UPDATE profiles SET data = jsonb_set(data, '{plan}', '"enterprise"') WHERE id = 1;
SELECT data ->> 'plan' FROM profiles WHERE id = 1;

-- || merge rules: top-level only, right side wins, arrays REPLACED not
-- concatenated (concat arrays explicitly):
SELECT '{"a":1,"arr":[1,2]}'::jsonb || '{"arr":[3]}'::jsonb AS array_replaced;

-- Handy shapers:
SELECT jsonb_strip_nulls(data) AS no_nulls,
       jsonb_pretty(data) AS readable
FROM profiles WHERE id = 2;

-- ---------------------------------------------------------------------------
-- Building documents relationally (the API-response pattern)
-- ---------------------------------------------------------------------------
SELECT jsonb_build_object(
           'id', p.id,
           'name', p.data ->> 'name',
           'address', p.data -> 'address',          -- keep as jsonb sub-doc
           'tag_count', jsonb_array_length(p.data -> 'tags')
       ) AS api_shape
FROM profiles p ORDER BY p.id;

-- jsonb_agg for collections (with the LEFT JOIN empty-guard):
SELECT p.id,
       coalesce(jsonb_agg(t.value) FILTER (WHERE t.value IS NOT NULL), '[]'::jsonb) AS demo
FROM profiles p
LEFT JOIN LATERAL (
    SELECT jsonb_build_object('v', x.value) AS value
    FROM jsonb_array_elements(p.data -> 'tags') AS x(value)
) t ON true
GROUP BY p.id ORDER BY p.id;

-- TAKEAWAYS
-- * ->> + cast for values; @>/?: for filtering (indexable — next files).
-- * Editing is copy-on-write: jsonb_set / || / - / #-.
-- * || is shallow; arrays replace, never merge.
-- * Build API shapes with jsonb_build_object/agg — often one query beats
--   an ORM's N+1 assembly.

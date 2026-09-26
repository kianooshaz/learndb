-- ============================================================================
-- 02-data-types/json_jsonb.sql — the two JSON types, and when each
-- ============================================================================
-- Run:  make sql FILE=02-data-types/json_jsonb.sql
--
-- json  = stored as the ORIGINAL TEXT (whitespace, key order, duplicate
--         keys preserved). Every use re-parses it. No indexing, no equality.
-- jsonb = parsed into a decomposed binary form (keys sorted, duplicates
--         merged, whitespace gone). Slower to write, fast to query, supports
--         GIN indexes, equality and containment operators.
--
-- Rule of thumb: jsonb for data you QUERY (99% of cases); json only to keep
-- an exact record of a payload (audit/archive of what an API sent).
-- Deep-dive continues in 09-json/.
-- ============================================================================

\set ON_ERROR_STOP on
DROP SCHEMA IF EXISTS m02_json CASCADE;
CREATE SCHEMA m02_json;
SET search_path TO m02_json;

-- json preserves the input verbatim:
SELECT '{"b": 1,   "a": 2, "a": 3}'::json  AS json_keeps_order_and_dupes;
-- jsonb normalizes: keys sorted, duplicate 'a' collapsed to LAST value,
-- whitespace dropped:
SELECT '{"b": 1,   "a": 2, "a": 3}'::jsonb AS jsonb_normalized;

-- Equality: meaningless for json (text comparison), exact for jsonb:
SELECT '{"a":1,"b":2}'::jsonb = '{"b":2, "a":1}'::jsonb AS jsonb_equal_despite_order;

-- The operators you'll use daily (jsonb side). Note: keep -> / ->> at the
-- END of a line — a line-initial operator confuses even the SQL parser.
SELECT '{"name": "Ada"}'::jsonb -> 'name' AS json_dotted,      -- -> returns jsonb
       '{"name": "Ada"}'::jsonb ->> 'name' AS text_unquoted;   -- ->> returns text
SELECT '{"addr": {"city": "London"}}'::jsonb #>> '{addr,city}' AS deep_path_text;

-- Containment (indexable by GIN — the query you'll actually ship):
SELECT '{"tags": ["pro"]}'::jsonb @> '{"tags":["pro","beta"]}'::jsonb AS contained_wrong_direction,
       '{"tags": ["pro","beta"]}'::jsonb @> '{"tags":["pro"]}'::jsonb AS contains_subobject,
       '{"a": 1}'::jsonb ? 'a' AS key_exists;

-- jsonb is NOT schemaless magic: there's no arithmetic on extracted values:
\set ON_ERROR_STOP off
SELECT '5'::jsonb + 1;
-- ERROR: operator does not exist: jsonb + integer — you must extract and cast:
\set ON_ERROR_STOP on
SELECT ('{"qty": 5}'::jsonb ->> 'qty')::int + 1 AS qty_plus_one;
-- ->> gives text; casting EVERY time is the tax of semi-structured data.
-- If a field appears in WHERE clauses or joins, promote it to a real column
-- (generated columns — 11-advanced/generated_columns/).

-- Storage: jsonb is typically a bit larger on disk than the raw text and
-- TOASTed when wide; both are variable-length varlena. Whole-document
-- updates REWRITE the value (MVCC: new row version) — see 09-jsonb_performance.

-- Validation: neither type validates a SCHEMA. jsonb only guarantees valid
-- JSON syntax. Enforce shape with CHECK constraints:
CREATE TABLE api_events (
    id    bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    body  jsonb NOT NULL CHECK (body ? 'type' AND jsonb_typeof(body) = 'object')
);
INSERT INTO api_events (body) VALUES ('{"type": "click"}');
-- INSERT INTO api_events (body) VALUES '{"type": "click", "extra": 1}' vs
-- '["not", "an", "object"]' -> rejected by the CHECK.

-- TAKEAWAYS
-- * json = faithful text; jsonb = queryable binary. Default to jsonb.
-- * -> keep jsonb, ->> give text (then cast) — pick deliberately.
-- * @> containment is the GIN-indexable operator; = is not how you query.
-- * jsonb stores syntax, not schema: CHECK what your code assumes.

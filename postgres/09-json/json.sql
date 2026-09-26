-- ============================================================================
-- 09-json/json.sql — the faithful-text type: audits, archives, wire payloads
-- ============================================================================
-- Run:  make sql FILE=09-json/json.sql
--
-- json stores the input TEXT VERBATIM. That inflexibility IS the feature
-- when the point is fidelity: webhook receipts, audit trails, legal records
-- of "exactly what the API sent". You give up indexing/equality/speed.
-- ============================================================================

\set ON_ERROR_STOP on
\timing on
DROP SCHEMA IF EXISTS m09_json CASCADE;
CREATE SCHEMA m09_json;
SET search_path TO m09_json, public;

CREATE TABLE webhook_receipts (
    id        bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    received  timestamptz NOT NULL DEFAULT now(),
    source    text NOT NULL,
    payload   json NOT NULL
);

-- Verbatim storage: duplicate keys, original order, spacing — all preserved:
INSERT INTO webhook_receipts (source, payload) VALUES
    ('stripe', '{"amount": 1999,   "currency": "usd", "metadata": {"a": 1, "a": 2}}');

SELECT payload FROM webhook_receipts;
-- The duplicate "a" and the odd spacing survive exactly. jsonb would have
-- normalized both — losing evidence of a buggy sender.

-- json still validates SYNTAX:
--   INSERT INTO webhook_receipts (source) ... payload '{"amount": }';
--   ERROR: invalid input syntax for type json

-- Extraction operators exist (same families as jsonb):
SELECT payload::json -> 'amount'   AS raw_json,
       payload ->> 'amount'        AS text_form,
       payload #>> '{metadata,a}'  AS deep
FROM webhook_receipts
WHERE source = 'stripe';
-- But every use RE-PARSES the text. json has no binary form cached.

-- json is fully unicode-faithful (JSON escapes kept as written) and keeps
-- numbers EXACTLY as sent (jsonb converts to numeric — e.g. 1.000 stays
-- 1.000 here, becomes 1.000 in jsonb too, but 1e3 becomes 1000).

-- json -> jsonb direction (normalize on demand):
SELECT jsonb_pretty(payload::jsonb) AS normalized
FROM webhook_receipts WHERE source = 'stripe';

-- Construction from rows (json_*, the un-binary family):
SELECT json_build_object('id', 1, 'tags', json_build_array('a', 'b')) AS obj,
       to_json('2026-09-25'::date) AS wrapped_value;

-- row_to_json: whole rows as json (json_agg for sets — 03-queries/aggregates
-- shows the jsonb versions):
SELECT row_to_json(r) FROM (SELECT id, source FROM webhook_receipts LIMIT 1) r;

-- ---------------------------------------------------------------------------
-- Decision frame: json vs jsonb vs columns
--   * "must reproduce input exactly"            -> json (this file)
--   * "query/filter/index the document"         -> jsonb (jsonb.sql)
--   * "field appears in WHERE/JOIN/ORDER"       -> real column, or generated
--     column promoted out of the document (11-advanced/generated_columns)
--   * schema known & stable                     -> plain columns beat both
-- ============================================================================

-- TAKEAWAYS
-- * json = exact-text JSON: fidelity over everything.
-- * Verbatim duplicates/order/whitespace; re-parsed on every use.
-- * No GIN indexing, no equality — you cannot WHERE on it efficiently.
-- * Perfect for audit/receipt tables that are written once, read rarely,
--   and argued about precisely.

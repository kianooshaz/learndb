-- ============================================================================
-- 02-data-types/uuid.sql — 128-bit identifiers done right
-- ============================================================================
-- Run:  make sql FILE=02-data-types/uuid.sql
--
-- UUIDs solve: "generate an id on any node with no coordination". They cost:
-- 16 bytes vs 8 for bigint, and random ones destroy btree insert locality
-- (every insert lands on a random leaf page). Know both sides.
-- ============================================================================

\set ON_ERROR_STOP on
DROP SCHEMA IF EXISTS m02_uuid CASCADE;
CREATE SCHEMA m02_uuid;
-- NOTE: we keep `public` in the search_path — extension functions (here:
-- uuid-ossp) are installed in public. Replacing search_path entirely is a
-- classic way to "lose" your extensions with a confusing "function does not
-- exist" error.
SET search_path TO m02_uuid, public;

-- Random (v4): built into PG13+ — no extension needed (uuid-ossp is legacy):
SELECT gen_random_uuid() AS v4_a, gen_random_uuid() AS v4_b;

-- Deterministic (v5, namespace + name -> same input, same UUID; needs
-- uuid-ossp). Use cases: stable synthetic ids for dedup/idempotency:
SELECT uuid_generate_v5(uuid_ns_url(), 'https://example.com/users/ada') AS stable_1,
       uuid_generate_v5(uuid_ns_url(), 'https://example.com/users/ada') AS stable_2;

-- Comparison/ordering is byte-wise; equality is exact. Text form is only
-- display — don't store UUIDs as text (2x size, slower compares):
SELECT 'a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11'::uuid
     = 'A0EEBC99-9C0B-4EF8-BB6D-6BB9BD380A11'::uuid AS case_insensitive_parse;

CREATE TABLE api_keys (
    id    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    name  text NOT NULL
);
INSERT INTO api_keys (name) VALUES ('prod') RETURNING id;

-- ---------------------------------------------------------------------------
-- bigint identity vs random uuid as PK — the locality problem, measured
-- ---------------------------------------------------------------------------
CREATE TABLE t_bigint (id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY, payload text DEFAULT 'x');
CREATE TABLE t_uuid    (id uuid PRIMARY KEY DEFAULT gen_random_uuid(),     payload text DEFAULT 'x');

INSERT INTO t_bigint (payload) SELECT 'x' FROM generate_series(1, 50000);
INSERT INTO t_uuid    (payload) SELECT 'x' FROM generate_series(1, 50000);

-- Index size: 16B keys vs 8B keys.
SELECT relname,
       pg_size_pretty(pg_relation_size(indexrelid)) AS index_size
FROM pg_stat_user_indexes
WHERE relname IN ('t_bigint','t_uuid');

-- Insert locality: with sequential ids all inserts append to the same right-
---most leaf page (hot in cache). With random uuid v4, inserts scatter across
-- the whole tree — more cache misses and page splits as the table grows.
-- Modern answer: time-ordered UUIDs (v7) or v4 from your app; PostgreSQL 18
-- ships uuidv7(); today you can emulate ordering by prefixing a timestamp.

-- When each wins:
--  * bigint identity: single-writer databases, smallest/fastest keys,
--    internal tables. Default choice for plain OLTP.
--  * uuid: ids generated client-side (offline-friendly), merging datasets
--    from multiple sources, exposing ids in URLs without enumerability.
--  * Compromise seen in the wild: internal bigint FKs + external uuid for
--    API addressing.

-- TAKEAWAYS
-- * gen_random_uuid() is built in; uuid-ossp only for deterministic v5.
-- * Store as uuid (16B binary), never as text.
-- * Random UUIDs cost index locality + 8 bytes/key; UUIDv7 mitigates.
-- * Never expose sequential bigint ids where enumeration is a concern.

-- ============================================================================
-- 10-extensions/uuid_ossp.sql — deterministic UUIDs (v5) and legacy context
-- ============================================================================
-- Run:  make sql FILE=10-extensions/uuid_ossp.sql
--
-- Reality check first: since PostgreSQL 13, gen_random_uuid() (v4) is
-- BUILT IN — you don't need any extension for random UUIDs. uuid-ossp
-- remains relevant for exactly two jobs:
--   1. deterministic v5 UUIDs: same (namespace, name) -> same UUID forever
--   2. time-ordered v1 UUIDs (leaky and collision-prone; prefer app-side
--      UUIDv7 or PG18's uuidv7())
-- ============================================================================

\set ON_ERROR_STOP on
DROP SCHEMA IF EXISTS m10_uuid CASCADE;
CREATE SCHEMA m10_uuid;
SET search_path TO m10_uuid, public;   -- extension objects live in public!

-- The four standard namespaces:
SELECT uuid_nil()  AS nil_uuid,
       uuid_ns_dns() AS ns_dns,
       uuid_ns_url() AS ns_url,
       uuid_ns_oid() AS ns_oid,
       uuid_ns_x500() AS ns_x500;

-- v5 (SHA-1 of namespace+name): DETERMINISTIC across databases, servers,
-- languages (any RFC-4122 v5 implementation produces the same value):
SELECT uuid_generate_v5(uuid_ns_url(), 'https://learndb.dev/users/ada')  AS run1,
       uuid_generate_v5(uuid_ns_url(), 'https://learndb.dev/users/ada')  AS run2;
-- Identical. Compare with gen_random_uuid() (v4): different every call.

-- The deduplication superpower: turn ANY natural key into a stable UUID:
CREATE TABLE external_refs (
    ref uuid PRIMARY KEY,
    url text NOT NULL
);
INSERT INTO external_refs (ref, url)
VALUES (uuid_generate_v5(uuid_ns_url(), 'https://api.github.com/repos/postgres/postgres'),
        'https://api.github.com/repos/postgres/postgres')
ON CONFLICT (ref) DO NOTHING;      -- re-imports are no-ops by construction
SELECT count(*) FROM external_refs;   -- still 1 no matter how often you run this

-- v1 (time + MAC): sortable by creation time but leaks the host MAC and
-- clock — historical curiosity; know it when you see it in old schemas:
SELECT uuid_generate_v1() AS legacy_v1;

-- TAKEAWAYS
-- * gen_random_uuid() (v4): built in, no extension.
-- * v5: deterministic id-from-name — idempotent imports, cross-system keys.
-- * v1: leaky legacy; avoid in new designs (use UUIDv7 for time-order).
-- * Extension functions live in public — keep it in search_path (02/uuid).

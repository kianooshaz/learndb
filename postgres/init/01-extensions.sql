-- Runs automatically on FIRST container boot only (fresh volume).
-- Loaded via /docker-entrypoint-initdb.d (see docker-compose.yml).

\set ON_ERROR_STOP on

-- pg_stat_statements MUST be preloaded at server start (shared_preload_libraries,
-- set in docker-compose.yml). CREATE EXTENSION only installs its SQL objects.
-- It records per-query statistics: the first tool you reach for in production
-- when asked "which queries are slow?".
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;

-- Cryptographic functions: digest/hmac, and crypt()/gen_salt() for password
-- hashing (10-pextensions/pgcrypto.sql).
CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- uuid-ossp: legacy UUID generators (v1, v5). Modern PostgreSQL (13+) has
-- gen_random_uuid() built in, so this is mostly for the deterministic v5 demo.
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- pg_trgm: trigram matching -> fuzzy text search AND index-accelerated
-- LIKE '%foo%' / ILIKE '%foo%' (10-extensions/pg_trgm.sql).
CREATE EXTENSION IF NOT EXISTS pg_trgm;

-- citext: case-insensitive text type (10-extensions/citext.sql).
CREATE EXTENSION IF NOT EXISTS citext;

-- Let scalar types (int, text, ...) participate in GIN / GiST indexes, so you
-- can build composite indexes like GIN (tenant_id, jsonb_col) or GiST
-- exclusion constraints mixing btree-able and range columns.
CREATE EXTENSION IF NOT EXISTS btree_gin;
CREATE EXTENSION IF NOT EXISTS btree_gist;

-- Inspect physical table/index layout and bloat (07-performance/bloat.sql).
CREATE EXTENSION IF NOT EXISTS pgstattuple;
CREATE EXTENSION IF NOT EXISTS pageinspect;

-- What's resident in shared_buffers (10-extensions tour).
CREATE EXTENSION IF NOT EXISTS pg_buffercache;

-- postgres_fdw: query another PostgreSQL server as if it were a local table
-- (11-advanced/foreign_data_wrapper/).
CREATE EXTENSION IF NOT EXISTS postgres_fdw;

-- Misc utilities used across labs.
CREATE EXTENSION IF NOT EXISTS file_fdw;
CREATE EXTENSION IF NOT EXISTS tablefunc;
CREATE EXTENSION IF NOT EXISTS unaccent;
CREATE EXTENSION IF NOT EXISTS fuzzystrmatch;

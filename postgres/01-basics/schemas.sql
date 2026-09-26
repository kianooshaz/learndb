-- ============================================================================
-- 01-basics/schemas.sql — namespaces inside a database
-- ============================================================================
-- Run:  make sql FILE=01-basics/schemas.sql
--
-- WHY SCHEMAS EXIST
-- Inside a database, every object (table, function, type, sequence) lives in
-- a schema. Without them, one flat namespace means multi-team databases
-- collide (two teams, one `users` table). A common production layout:
--   app_public  — tables the API role may touch
--   app_private — internal bookkeeping (tokens, audit internals)
--   analytics   — BI-owned objects
-- Schemas are namespaces, NOT isolation walls: cross-schema queries are
-- trivial. (Walls are databases; row-level security comes in 11-advanced.)
-- ============================================================================

\set ON_ERROR_STOP on

-- Unqualified names resolve through search_path. Default: "$user", public
SHOW search_path;

DROP SCHEMA IF EXISTS app_private CASCADE;
DROP SCHEMA IF EXISTS app_public CASCADE;

CREATE SCHEMA app_public;
CREATE SCHEMA app_private;

-- Unqualified CREATE lands in the FIRST *existing* schema in search_path
-- (usually public). In migrations, qualify everything — it survives
-- search_path surprises.
CREATE TABLE app_private.stripe_keys (id int primary key, key text);
CREATE TABLE app_public.customers (
    id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    email       text NOT NULL UNIQUE,
    created_at  timestamptz NOT NULL DEFAULT now()
);

-- The collision problem schemas solve — same name, two schemas, no conflict:
CREATE TABLE app_public.events (id bigint);
CREATE TABLE app_private.events (id bigint);

-- Cross-schema query: just qualify names.
SELECT p.id AS customer_id, k.id AS key_id
FROM app_public.customers p
CROSS JOIN app_private.stripe_keys k
WHERE false;   -- zero rows, but proves it parses and plans

-- search_path in action for this session:
SET search_path TO app_public, public;
INSERT INTO customers (email) VALUES ('a@example.com'), ('b@example.com');
SELECT id, email FROM customers ORDER BY id;

-- Persist for a ROLE (survives reconnects — handy for service accounts):
--   ALTER ROLE my_service SET search_path = app_public;
-- OPERATIONAL WARNING: changing search_path under a live connection pool is
-- risky — a cached prepared statement can silently resolve to a DIFFERENT
-- object after the path changes. Keep it stable per pool, or fully qualify.

-- What information_schema shows (per-database, only objects you may see):
SELECT table_schema, table_name
FROM information_schema.tables
WHERE table_schema IN ('app_public', 'app_private')
ORDER BY 1, 2;

-- CASCADE drops contained objects too. Honest for lab teardown; in prod it
-- hides what died — list dependents first (pg_depend) before cascading.
DROP SCHEMA IF EXISTS app_public CASCADE;
DROP SCHEMA IF EXISTS app_private CASCADE;

-- TAKEAWAYS
-- * Databases = walls, schemas = namespaces inside one wall.
-- * search_path resolves unqualified names: keep it stable, or qualify.
-- * app_public/app_private layout = a scannable security surface for GRANTs.

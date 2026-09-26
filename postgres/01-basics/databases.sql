-- ============================================================================
-- 01-basics/databases.sql — databases are the outermost container
-- ============================================================================
-- Run:  make sql FILE=01-basics/databases.sql
--
-- WHY THIS FILE EXISTS
-- A PostgreSQL *instance* (one running postgres server) contains databases.
-- Databases are strict isolation boundaries:
--   * you cannot JOIN across databases (that's what postgres_fdw is for),
--   * roles and tablespaces are cluster-wide, NOT per-database,
--   * each connection is bound to exactly one database for its lifetime.
-- ============================================================================

\set ON_ERROR_STOP on

-- Which database/user am I? psql here connects to `learndb`.
SELECT current_database(), current_user, version();

-- List databases. datistemplate marks templates; datallowconn=false means
-- connections are refused (used to freeze a template).
SELECT datname, datallowconn, datistemplate
FROM pg_database
ORDER BY datname;

-- Postgres ships three databases:
--   postgres  — default landing spot for psql
--   template1 — cookie-cutter that CREATE DATABASE clones
--   template0 — pristine fallback, needed to change encoding/collation

-- CREATE DATABASE physically CLONES a template's files. That's also how you
-- get your extensions into every new database: install into template1.
CREATE DATABASE lab_billing;

DROP DATABASE IF EXISTS lab_billing;   -- IF EXISTS keeps re-runs green

-- You CANNOT drop a database while connections exist. Try it live:
--   1. second terminal:  make psql   (holds a connection)
--   2. here: DROP DATABASE learndb;
--      -> ERROR: database "learndb" is being accessed by other users
-- Production tooling either refuses or first terminates backends with
-- pg_terminate_backend(pid).

-- Per-database defaults: applied to every NEW session, without touching any
-- client code. Classic uses: timezone, statement_timeout, work_mem.
ALTER DATABASE learndb SET timezone TO 'UTC';

-- CONNECT privilege is granted to PUBLIC (all roles) by default:
SELECT has_database_privilege(current_user, current_database(), 'CONNECT') AS can_connect;

-- TAKEAWAYS
-- * Instance -> databases -> schemas -> tables. Cross-database queries: none.
-- * CREATE DATABASE = clone a template (template1 by default).
-- * DROP DATABASE needs zero open connections.
-- * ALTER DATABASE SET ... persists session defaults server-side.

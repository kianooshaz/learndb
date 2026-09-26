-- ============================================================================
-- 01-basics/tables.sql — heaps, identity columns, sequences, table anatomy
-- ============================================================================
-- Run:  make sql FILE=01-basics/tables.sql
--
-- A Postgres table is a HEAP: an unordered pile of 8KB pages holding row
-- versions (tuples). There is no "clustered index" concept like MySQL
-- InnoDB's PRIMARY KEY — rows live wherever free space allows, and every
-- index is a separate structure pointing into the heap (by ctid = physical
-- location). This one fact explains most of PostgreSQL's behavior later:
-- MVCC (06), vacuum (07), index-only scans needing a visibility map (05).
-- ============================================================================

\set ON_ERROR_STOP on

DROP SCHEMA IF EXISTS m01_tables CASCADE;
CREATE SCHEMA m01_tables;
SET search_path TO m01_tables;

-- ---------------------------------------------------------------------------
-- The three ways to get auto-incrementing ids — and which to choose
-- ---------------------------------------------------------------------------

-- (1) LEGACY: serial. Still everywhere in old schemas. It is NOT a real
-- type: it creates a sequence and wires up the default.
CREATE TABLE t_serial (
    id   serial PRIMARY KEY,     -- expands to: integer + nextval(default)
    name text
);

-- (2) MODERN: identity columns (SQL standard, since PG10).
CREATE TABLE t_identity (
    id   bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name text
);
-- ALWAYS = inserting an explicit id is an ERROR (unless OVERRIDING SYSTEM
-- VALUE) — protects against apps minting duplicate ids. BY DEFAULT allows it.

-- (3) Sometimes you want NO surrogate key at all: natural keys are fine when
-- truly stable and unique (e.g. ISO currency codes).
CREATE TABLE currencies (code char(3) PRIMARY KEY, name text);

-- Sequences under the hood — both serial and identity use one:
SELECT sequencename FROM pg_sequences WHERE schemaname = 'm01_tables';

-- A sequence is a tiny dedicated object that hands out numbers; each
-- nextval() is logged so it survives crashes. Costs: one extra round trip
-- per INSERT *unless* you use RETURNING (below), and sequences have
-- DOCUMENTED gaps (caches, rollbacks consume values — gaps are normal).
SELECT nextval('t_identity_id_seq') AS manual_pull,
       currval('t_identity_id_seq') AS this_sessions_last;

-- Sequence exhaustion: integer tops out at 2,147,483,647. bigint is the safe
-- default for new tables; the industry is full of midnight pager alerts from
-- `nextval: reached maximum value of sequence`.

-- ---------------------------------------------------------------------------
-- Ways to create tables from queries
-- ---------------------------------------------------------------------------
CREATE TABLE signups (day date, source text, n int);
INSERT INTO signups VALUES
    ('2026-09-20', 'organic', 41),
    ('2026-09-21', 'ads',     17),
    ('2026-09-21', 'organic', 38);

-- CTAS: create + fill in one statement. No constraints are copied except
-- NOT NULL (in newer versions even those semantics are explicit via
-- `CREATE TABLE ... (LIKE ... INCLUDING ALL)`).
CREATE TABLE signups_copy AS TABLE signups;

-- LIKE with options copies the *shape* precisely:
CREATE TABLE signups_like (LIKE signups INCLUDING DEFAULTS INCLUDING CONSTRAINTS);

-- Inspect what a table really is:
\d t_identity

-- Physical anatomy from the catalogs: pages on disk and live-tuple ESTIMATES
-- (reltuples/relpages are refreshed by ANALYZE — they are statistics, not
-- counters; exact counts come from count(*), see 03-queries/aggregates.sql).
SELECT relname, relpages, reltuples
FROM pg_class
WHERE relnamespace = 'm01_tables'::regnamespace AND relkind = 'r'
ORDER BY relname;

-- ctid: the physical (page, slot) address of a row version. Proof the table
-- is a heap with no inherent order:
SELECT ctid, id FROM t_identity;   -- insertion order here, but NOT guaranteed

-- ALTER on the fly — adding a nullable column is metadata-only (fast);
-- adding NOT NULL DEFAULT rewrites... since PG11 it doesn't for constant
-- defaults (stored as a "missing" value). Still avoid volatile defaults
-- like now() on giant tables without care.
ALTER TABLE t_identity ADD COLUMN notes text;
ALTER TABLE t_identity ADD COLUMN created_at timestamptz DEFAULT now();

-- TAKEAWAYS
-- * Tables are heaps of 8KB pages; indexes point into them via ctid.
-- * Use GENERATED ALWAYS AS IDENTITY for new surrogate keys (not serial).
-- * bigint ids cost nothing extra and prevent integer-overflow migrations.
-- * reltuples/relpages are planner statistics — the planner's map, not truth.

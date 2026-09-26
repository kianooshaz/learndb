-- ============================================================================
-- 10-extensions/other_useful_extensions.sql — the toolbox tour
-- ============================================================================
-- Run:  make sql FILE=10-extensions/other_useful_extensions.sql
--
-- Survey of extensions you'll meet in real deployments (most already
-- installed in this lab via init/01-extensions.sql). For each: what it's
-- for, a live demo, and when you reach for it.
-- ============================================================================

\set ON_ERROR_STOP on
\timing on

-- What's available in this server at all (PGXN/OS packages add more):
SELECT name, default_version, installed_version
FROM pg_available_extensions
WHERE name IN ('hypopg','pg_repack','pgaudit','postgis','pg_stat_statements',
               'pgstattuple','pageinspect','tablefunc','unaccent','fuzzystrmatch',
               'pg_buffercache','postgres_fdw','file_fdw','pgcrypto','citext')
ORDER BY name;

-- ---------------------------------------------------------------------------
-- pgstattuple / pageinspect — physical forensics (07-performance/bloat)
-- ---------------------------------------------------------------------------
SELECT pgstattuple('pg_class'::regclass) IS NOT NULL AS pgstattuple_works;
-- pageinspect lets you read RAW PAGES — the MVCC lab's "see it yourself":
DROP TABLE IF EXISTS m10_pi_t CASCADE;
CREATE TABLE m10_pi_t (id int PRIMARY KEY, v text);
INSERT INTO m10_pi_t VALUES (1, 'a');
-- HeapTuple header of a live row: t_xmin/t_xmax literally on disk (06):
SELECT t_xmin, t_xmax, t_field3 AS cid, t_ctid
FROM heap_page_items(get_raw_page('m10_pi_t', 0))
LIMIT 3;

-- ---------------------------------------------------------------------------
-- pg_buffercache — what is actually in shared_buffers right now
-- ---------------------------------------------------------------------------
SELECT count(*) AS pages_in_buffercache FROM pg_buffercache;

-- ---------------------------------------------------------------------------
-- tablefunc — crosstab(): pivot rows into columns in SQL
-- ---------------------------------------------------------------------------
SELECT * FROM crosstab(
    $$SELECT g % 3 AS bucket, g % 2 AS flag, count(*)
      FROM generate_series(1, 100) g GROUP BY 1, 2 ORDER BY 1, 2$$)
AS ct(bucket int, flag0 bigint, flag1 bigint);

-- ---------------------------------------------------------------------------
-- fuzzystrmatch + unaccent — soundex/metaphone fuzzy matching, diacritics
-- ---------------------------------------------------------------------------
SELECT soundex('Postgres') = soundex('Postgres') AS soundex_same,
       difference('Postgres', 'Pastgres')         AS difference_score,  -- 0-4
       unaccent('José')                            AS diacritics_stripped;

-- ---------------------------------------------------------------------------
-- postgres_fdw / file_fdw — cross-server and file-backed tables
-- (Full labs: 11-advanced/foreign_data_wrapper/)
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- The ones NOT pre-installed here (and how they'd arrive):
--
-- hypopg  — HYPOTHETICAL indexes: "would the planner use an index if it
--   existed?" WITHOUT building it. The teaching machine for 04-indexes:
--   SELECT * FROM hypopg_create_index('CREATE INDEX ON t (col)');
--   then EXPLAIN your query — plan shows the phantom index. Install:
--   needs a custom image (apt install postgresql-16-hypopg / PGXN build).
--
-- pg_repack — online table/index rebuild (VACUUM FULL without the lock).
--   apt install postgresql-16-repack; run via the CLI, not SQL.
--
-- pgaudit — audit logging to the standard log stream (compliance).
-- pg_partman — automated partition management (11-advanced/partitioning
--   does it natively first; partman automates the calendar).
-- pgcrypto/citext/pg_trgm — covered by their own files in this module.
-- ============================================================================

-- Security note before installing anything: extensions run with elevated
-- privileges at CREATE EXTENSION time. Allow-list them in your migration
-- policy; never install ad-hoc on production.
SELECT extname, extversion FROM pg_extension ORDER BY 1;

-- TAKEAWAYS
-- * pgstattuple/pageinspect: physical truth; pg_buffercache: memory truth.
-- * crosstab/unaccent/fuzzystrmatch: reporting & matching conveniences.
-- * hypopg (when available) = test indexes without building them.
-- * Treat CREATE EXTENSION as a privileged migration step.

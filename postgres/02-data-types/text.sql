-- ============================================================================
-- 02-data-types/text.sql — char / varchar / text (+ bytea)
-- ============================================================================
-- Run:  make sql FILE=02-data-types/text.sql
--
-- Punchline first: in PostgreSQL, varchar and text are THE SAME ENGINE.
-- Unlike other databases there is NO performance difference. varchar(n)
-- adds only a length CHECK. char(n) pads — almost never what you want.
-- ============================================================================

\set ON_ERROR_STOP on
DROP SCHEMA IF EXISTS m02_text CASCADE;
CREATE SCHEMA m02_text;
SET search_path TO m02_text;

-- Storage is identical for all three: varlena — a length prefix + bytes,
-- compressed (TOAST) when a value gets big. Nothing is "fixed-width".
SELECT typname, typlen FROM pg_type WHERE typname IN ('bpchar','varchar','text');
-- -1 = variable length.

-- char(n): pads with spaces to n. And comparisons SILENTLY strip trailing
-- spaces — so 'ab   ' = 'ab' under char semantics:
SELECT 'ab'::char(5) AS padded,
       length('ab'::char(5))            AS length_padded,
       'ab'::char(5) = 'ab'::char(5)    AS equal_obviously,
       'ab   '::char(5) = 'ab'::char(5) AS trailing_spaces_ignored;

-- varchar(n): no padding; exceeding n is an ERROR:
--   SELECT 'abcdef'::varchar(5);
--   ERROR: value too long for type character varying(5)
SELECT 'abc'::varchar(5) AS stored_as_is, length('abc'::varchar(5)) AS len3;

-- text: unlimited. Same speed, same indexes. The community default.
-- Recommendation: text everywhere + CHECK (char_length(x) <= n) only when a
-- business rule demands a limit. varchar(n) changes are painful migrations
-- later (ALTER TYPE ... ALTER COLUMN is fine widening, but why manage it).

-- ---------------------------------------------------------------------------
-- NULL-poisoning in concatenation — bites everyone once
-- ---------------------------------------------------------------------------
SELECT 'Hello, ' || NULL AS concat_with_null;          -- NULL, not 'Hello, '
SELECT concat('Hello, ', NULL) AS concat_skips_nulls;  -- 'Hello, '
SELECT coalesce(NULL, '') || 'x' AS coalesce_pattern;
-- In Go: pgx scans NULL into your pointer; make sure your string builders
-- handle it (sql.Null[string] / *string).

-- ---------------------------------------------------------------------------
-- Comparison, pattern matching, and indexes (preview of 04-indexes)
-- ---------------------------------------------------------------------------
CREATE TABLE users_text (id serial PRIMARY KEY, email text);
INSERT INTO users_text (email) VALUES
    ('Ada@Example.com'), ('bob@example.com'), ('carol@EXAMPLE.com');

-- = is case-SENSITIVE (per collation). Real emails: normalize on write
-- (lower(email)) or use citext (10-extensions/citext.sql):
SELECT email FROM users_text WHERE email = 'ada@example.com';   -- 0 rows!

-- LIKE: % any run, _ single char. Anchored-prefix LIKE can use a btree
-- index; leading-wildcard cannot (until pg_trgm — 10-extensions/pg_trgm.sql):
SELECT email FROM users_text WHERE email LIKE 'a%';
SELECT email FROM users_text WHERE email ILIKE '%example%';  -- case-insensitive

-- Ordering follows the database COLLATION (lc_collate was removed as a
-- server GUC in PG16 — it's per-database metadata now):
SELECT datcollate, datctype FROM pg_database WHERE datname = current_database();

-- ---------------------------------------------------------------------------
-- bytea — binary blobs (images, serialized protobufs)
-- ---------------------------------------------------------------------------
-- Hex format input \x... , stored as varlena + TOAST like text.
SELECT '\xDEADBEEF'::bytea AS raw_bytes, octet_length('\xDEADBEEF'::bytea) AS n_bytes;
-- Escape/encode helpers you'll actually use from Go (pgx maps []byte <-> bytea
-- automatically — no escaping in your code):
SELECT encode('\xDEADBEEF'::bytea, 'base64') AS b64,
       decode('DEADBEEF', 'hex') AS from_hex;
-- Large blobs in the row -> TOAST compressed/out-of-line; multi-MB blobs per
-- row hurt badly (every SELECT * detoasts them). Store big objects outside
-- the DB (S3) and keep bytea for small payloads (keys, signatures, hashes).

-- TAKEAWAYS
-- * Use text; varchar(n) only as a business-rule check; never char(n).
-- * 'x' || NULL = NULL — coalesce or concat().
-- * = is case-sensitive: normalize emails, or use citext/lower() index.
-- * bytea is fine for small binary; object storage for big blobs.

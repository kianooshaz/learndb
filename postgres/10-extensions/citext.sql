-- ============================================================================
-- 10-extensions/citext.sql — case-insensitive text as a type
-- ============================================================================
-- Run:  make sql FILE=10-extensions/citext.sql
--
-- citext ("case-insensitive text") compares via lower() under the hood:
-- 'Ada@X.com' = 'ada@x.com' is TRUE, and UNIQUE constraints treat them as
-- duplicates. The alternative is a plain text column with lower() enforced
-- at the boundary + an expression index. Both are correct; they differ in
-- where the discipline lives (the TYPE vs the CODE).
-- ============================================================================

\set ON_ERROR_STOP on
DROP SCHEMA IF EXISTS m10_citext CASCADE;
CREATE SCHEMA m10_citext;
SET search_path TO m10_citext, public;

CREATE TABLE users_citext (
    id    int PRIMARY KEY,
    email citext NOT NULL UNIQUE          -- case-insensitive uniqueness
);
INSERT INTO users_citext VALUES (1, 'Ada@Example.com');

-- Equality is case-insensitive — including in UNIQUE enforcement:
SELECT 'ada@example.com' = 'ADA@EXAMPLE.COM' AS text_compare,
       'ada@example.com'::citext = 'ADA@EXAMPLE.COM'::citext AS citext_compare;
--   INSERT INTO users_citext VALUES (2, 'aDA@example.COM');
--   ERROR: duplicate key value violates unique constraint (impossible with text)

-- Regular index on citext serves case-insensitive lookups directly:
EXPLAIN (COSTS OFF) SELECT * FROM users_citext WHERE email = 'ada@example.com';

-- ---------------------------------------------------------------------------
-- The sharp edges (why many teams prefer text + lower() instead)
-- ---------------------------------------------------------------------------
-- 1. Pattern operators are NOT case-insensitive (LIKE still matches exactly
--    as written — the type only fixes = and UNIQUE):
SELECT 'Ada@Example.com'::citext LIKE 'ada%' AS like_still_case_sensitive;

-- 2. It's still TEXT inside: length, storage, everything else identical:
SELECT pg_typeof('x'::citext), octet_length('Ada'::citext);

-- 3. citext quietly lowercases for COMPARISON but STORES the original —
--    display keeps what the user typed (feature or trap, depending):
SELECT email FROM users_citext;

-- The disciplined alternative (no extension):
CREATE TABLE users_text (
    id    int PRIMARY KEY,
    email text NOT NULL UNIQUE          -- with app-side normalization
);
CREATE INDEX users_text_email_lower ON users_text (lower(email));
INSERT INTO users_text VALUES (1, lower('Ada@Example.com'));
EXPLAIN (COSTS OFF) SELECT * FROM users_text WHERE lower(email) = 'ada@example.com';

-- Decision:
--   emails, usernames, slugs   -> citext is genuinely ergonomic
--   mixed-case-significant     -> text (+ lower() expression index where needed)
--   codes / ids                -> text, normalize at write time, always

-- TAKEAWAYS
-- * citext = case-insensitive = and UNIQUE; stores original casing.
-- * LIKE/patterns stay case-sensitive; use ILIKE or trigram for that.
-- * Same bytes as text; only comparison semantics change.
-- * The lower() expression index is the extension-free equivalent.

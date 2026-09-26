-- ============================================================================
-- 02-data-types/domains.sql — reusable constraints over a base type
-- ============================================================================
-- Run:  make sql FILE=02-data-types/domains.sql
--
-- A domain is a base type + constraints + a default, with a name. It's the
-- "don't repeat CHECK (col ~ '^...$') in twelve tables" tool. Subtler than
-- it looks: domains CAN be bypassed in some NULL contexts, so treat them as
-- convenience, not armor.
-- ============================================================================

\set ON_ERROR_STOP on
DROP SCHEMA IF EXISTS m02_domain CASCADE;
CREATE SCHEMA m02_domain;
SET search_path TO m02_domain;

DROP DOMAIN IF EXISTS email_address CASCADE;
CREATE DOMAIN email_address AS text
    NOT NULL
    CHECK (value ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$');

DROP DOMAIN IF EXISTS us_zip CASCADE;
CREATE DOMAIN us_zip AS text CHECK (value ~ '^[0-9]{5}(-[0-9]{4})?$');

-- Usage reads exactly like a built-in type:
CREATE TABLE customers (id int PRIMARY KEY, email email_address, zip us_zip);
INSERT INTO customers VALUES (1, 'ada@example.com', '94107');
--   INSERT INTO customers VALUES (2, 'not-an-email', '94107');
--   ERROR: value for domain email_address violates check constraint

-- Changing ONE rule updates every column using the domain —
-- that's the maintenance win over copy-pasted CHECK constraints:
ALTER DOMAIN email_address ADD CONSTRAINT no_plus_tag
    CHECK (position('+' IN value) = 0);
--   INSERT INTO customers VALUES (3, 'ada+tag@example.com', '94107');  -- now rejected

-- Casting: explicit ::email_address runs the checks; assignments to domain
-- columns check implicitly.

-- ---------------------------------------------------------------------------
-- The sharp edges you must know
-- ---------------------------------------------------------------------------
-- 1. Domain CHECK runs BEFORE NOT NULL in some contexts historically; more
--    practically: "CHECK (value ...)" sees NULL pass silently (like all
--    CHECKs — 01-basics/constraints.sql). If NULL must be forbidden, keep
--    NOT NULL on the DOMAIN but remember columns can still be NULL via
--    ALTER of the domain later.

-- 2. Domains are bypassed in CAST and in some coercion paths in older
--    versions — never the SOLE guard for security-relevant values.

-- 3. Coercion surprise: text values inserted via parameterized queries are
--    validated; but a domain OVER another domain or used inside arrays
--    validates only on element access patterns you'd expect.

-- Domain vs CHECK vs generated column vs citext (10-extensions):
--   repeated simple validation -> domain (one definition, many columns)
--   one-table validation       -> CHECK
--   values needing normalization -> generated column or trigger
--   case-insensitive identity  -> citext or lower() expression index

-- Where domains shine in real services: shared "public identifier" formats
-- (SKU, slug) across many tables; team-wide conventions without an ORM.

SELECT d.typname, pg_get_constraintdef(c.oid)
FROM pg_constraint c JOIN pg_type d ON d.oid = c.contypid
WHERE d.typnamespace = 'm02_domain'::regnamespace;

-- TAKEAWAYS
-- * Domain = named type + checks (+ NOT NULL/default), reusable per column.
-- * ALTER DOMAIN propagates one rule change everywhere — the real payoff.
-- * CHECK semantics apply (NULL passes); don't rely on domains alone for
--   security; keep hard invariants on constraints/NOT NULL at the table.

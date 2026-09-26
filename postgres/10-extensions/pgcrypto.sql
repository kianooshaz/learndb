-- ============================================================================
-- 10-extensions/pgcrypto.sql — hashing and password storage done right
-- ============================================================================
-- Run:  make sql FILE=10-extensions/pgcrypto.sql
--
-- pgcrypto gives the database cryptographic primitives. Two honest rules:
--   1. Application-layer crypto (Go's crypto/*, bcrypt/argon2 libs) is the
--      default answer — keys live with the app, algorithms upgrade with the
--      binary, and crypto code is testable.
--   2. The legit DB-side uses: digest/hmac for in-query integrity checks,
--      and crypt()/gen_salt() when the DATABASE owns credential storage
--      (ops tooling, legacy apps) — bcrypt-style adaptive hashing, not
--      password encryption.
-- ============================================================================

\set ON_ERROR_STOP on
DROP SCHEMA IF EXISTS m10_crypto CASCADE;
CREATE SCHEMA m10_crypto;
SET search_path TO m10_crypto, public;

-- ---------------------------------------------------------------------------
-- 1. digest / hmac — deterministic integrity primitives
-- ---------------------------------------------------------------------------
SELECT digest('hello', 'sha256')                     AS raw_bytes,
       encode(digest('hello', 'sha256'), 'hex')      AS hex_string,
       encode(hmac('hello', 'secret-key', 'sha256'), 'hex') AS keyed_hmac;
-- Deterministic: same input -> same output (that's the point — it is NOT
-- encryption; you cannot get 'hello' back).
-- Uses: content-addressed storage keys, tamper checks, ETL row fingerprints:
SELECT md5('same input') AS legacy_md5;   -- built-in, but broken for security

-- Row fingerprint for change detection (vs IS DISTINCT FROM comparisons):
CREATE TABLE IF NOT EXISTS rowsnap (id int PRIMARY KEY, v text);
INSERT INTO rowsnap VALUES (1, 'a'), (2, 'b');
SELECT id, encode(hmac(v, 'pepper', 'sha256'), 'hex') AS row_hash FROM rowsnap;

-- ---------------------------------------------------------------------------
-- 2. Password storage: crypt + gen_salt (adaptive, salted)
-- ---------------------------------------------------------------------------
-- gen_salt('bf', cost): bcrypt with work factor — SLOW on purpose, and the
-- salt is embedded in the output string:
SELECT crypt('hunter2', gen_salt('bf', 8)) AS stored_hash_1,
       crypt('hunter2', gen_salt('bf', 8)) AS stored_hash_2;
-- Same password, different hashes (different salts) — comparing stored
-- hashes for equality is WRONG. Verification RE-CRYPTS with the stored salt:
SELECT crypt('hunter2', stored_hash_1) = stored_hash_1 AS verify_ok_1,
       crypt('wrongpw', stored_hash_1) = stored_hash_1 AS verify_ok_2
FROM (SELECT crypt('hunter2', gen_salt('bf', 8)) AS stored_hash_1) s;

-- The login flow shape (users table + verify query):
CREATE TABLE app_users (
    id       int PRIMARY KEY,
    username text UNIQUE NOT NULL,
    pwhash   text NOT NULL
);
INSERT INTO app_users VALUES (1, 'ada', crypt('correct horse', gen_salt('bf', 10)));

-- ONE query verifies credentials without ever SELECTing the hash into the
-- app (nothing leaks over the wire):
SELECT id FROM app_users
WHERE username = 'ada'
  AND pwhash = crypt('correct horse', pwhash);       -- the canonical form
SELECT id FROM app_users
WHERE username = 'ada'
  AND pwhash = crypt('tr0ub4dor', pwhash);           -- no rows

-- Cost tuning: each +1 doubles work. Time it:
\timing on
SELECT crypt('bench', gen_salt('bf', 10));
SELECT crypt('bench', gen_salt('bf', 12));
-- Target ~100-300ms per verification for credential storage.

-- ---------------------------------------------------------------------------
-- 3. PGP symmetric encryption — when a column truly must be encrypted
-- ---------------------------------------------------------------------------
SELECT encode(pgp_sym_encrypt('card data demo', 'pa55w0rd'), 'hex') AS ciphertext,
       pgp_sym_decrypt(pgp_sym_encrypt('card data demo', 'pa55w0rd'), 'pa55w0rd') AS roundtrip;
-- Randomized encryption (different ciphertext per call — proper for data at
-- rest). BUT: the key sits in your SQL/logs when used like this. In real
-- systems: app-layer envelope encryption (KMS), and never log the key.

-- What NOT to do, ever:
--   * store passwords with digest()/md5 (fast = brute-forceable)
--   * build your own crypto composition
--   * put encryption keys in SQL files

-- TAKEAWAYS
-- * digest/hmac: deterministic fingerprints and keyed integrity.
-- * crypt+gen_salt('bf'): salted adaptive hashing; verify with
--   pwhash = crypt(input, pwhash) IN THE DATABASE, one query, no hash on wire.
-- * pgp_sym_* for genuinely encrypted columns — keys app-side, ideally.
-- * Default to Go-side crypto; use pgcrypto where the DB owns the data.

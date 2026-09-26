-- ============================================================================
-- 02-data-types/date_time.sql — timestamps, time zones, intervals
-- ============================================================================
-- Run:  make sql FILE=02-data-types/date_time.sql
--
-- The single most misunderstood area of PostgreSQL. Core facts:
--   * timestamptz stores a UTC instant. It does NOT store a time zone.
--     The session's TimeZone setting only affects DISPLAY.
--   * timestamp ("without time zone") stores wall-clock digits with no
--     zone meaning at all. Use it only for future-local-time scheduling
--     (e.g. "9am in whatever timezone applies then") or abstract clock times.
--   * now() is the TRANSACTION start time and is constant inside a tx;
--     clock_timestamp() advances for real.
-- ============================================================================

\set ON_ERROR_STOP on
DROP SCHEMA IF EXISTS m02_time CASCADE;
CREATE SCHEMA m02_time;
SET search_path TO m02_time;

-- What zone are we in? (compose default: container UTC; we set DB default UTC)
SHOW timezone;

-- ---------------------------------------------------------------------------
-- timestamptz: an instant; display depends on the session
-- ---------------------------------------------------------------------------
SELECT '2026-09-25 14:00:00+02'::timestamptz AS same_instant_shown_in_utc;

SET timezone = 'Europe/Berlin';
SELECT '2026-09-25 14:00:00+02'::timestamptz AS shown_in_berlin;
SET timezone = 'America/New_York';
SELECT '2026-09-25 14:00:00+02'::timestamptz AS shown_in_new_york;
-- Identical underlying value (microseconds since 2000-01-01 UTC). Only the
-- rendering changed. This is why storing "the zone" is impossible in
-- timestamptz — it never existed.

-- The classic corruption: casting a zoneless string to timestamptz applies
-- the SESSION zone. Same string, different sessions, different instants:
SET timezone = 'UTC';
SELECT '2026-09-25 12:00:00'::timestamptz AS assumed_utc;
SET timezone = 'Asia/Tokyo';
SELECT '2026-09-25 12:00:00'::timestamptz AS assumed_tokyo;
SET timezone = 'UTC';

-- timestamp (no tz): literal digits, no interpretation. Comparing the two
-- families silently strips zone info — a bug factory. Stick to timestamptz
-- for every "when did this happen" column.
SELECT '2026-09-25 12:00:00+02'::timestamptz AT TIME ZONE 'UTC' AS stripped_to_naive;

-- ---------------------------------------------------------------------------
-- now() vs clock_timestamp() — transactional time vs wall clock
-- ---------------------------------------------------------------------------
BEGIN;
SELECT now() AS t1, clock_timestamp() AS real1;
SELECT pg_sleep(0.05);
SELECT now() AS t2_still_same, clock_timestamp() AS real2_moved;
COMMIT;
-- now() frozen at tx start makes sense: a transaction should see a
-- consistent "current time" (it's part of the snapshot). For durations,
-- use clock_timestamp(). Note pg_sleep exists for DEMOS only — never in prod.

-- Related, same family: transaction_timestamp() = now();
-- statement_timestamp() = per statement; current_timestamp = SQL spelling.

-- ---------------------------------------------------------------------------
-- date, time, interval
-- ---------------------------------------------------------------------------
SELECT current_date,
       current_time AT TIME ZONE 'UTC' AS utc_wall_time;

-- Interval: human-unit duration (months/days/seconds) — DST-aware when
-- added to timestamps:
SELECT '2026-03-29 01:30'::timestamptz AT TIME ZONE 'Europe/Berlin' + interval '1 hour' AS across_dst_spring;
-- (02:30 does not exist that night in Berlin; PG resolves it forward)
SELECT interval '1 mon 2 days 3:04:05.6' AS pretty,
       justify_interval(interval '45 days') AS grouped,
       extract(epoch FROM interval '90 minutes') AS total_seconds;

-- Index-friendly range predicates on timestamptz:
CREATE TABLE events (id bigint GENERATED ALWAYS AS IDENTITY, at timestamptz NOT NULL);
INSERT INTO events (at)
SELECT now() - (g || ' minutes')::interval
FROM generate_series(1, 1000) g;

SELECT count(*) FROM events WHERE at >= now() - interval '1 hour';

-- Interval arithmetic + generate_series = time buckets (gap filling):
SELECT date_trunc('hour', at) AS hour, count(*)
FROM events
WHERE at >= now() - interval '5 hours'
GROUP BY 1 ORDER BY 1;

-- date_trunc on timestamptz truncates in the SESSION zone — set the zone
-- first when business hours matter:
SELECT date_trunc('day', now()) AS utc_midnight;

-- Overlap operator — scheduling in one predicate:
SELECT tstzrange('2026-09-25 10:00+00', '2026-09-25 11:00+00')
       && tstzrange('2026-09-25 10:30+00', '2026-09-25 12:00+00') AS overlaps;

-- ---------------------------------------------------------------------------
-- Common mistakes checklist
-- ---------------------------------------------------------------------------
-- 1. column type timestamp storing UTC-converted values -> use timestamptz.
-- 2. Sending '2026-09-25 12:00:00' (no offset) from the app -> the session
--    zone silently interprets it. Always send an offset, or an ISO instant.
-- 3. extract(month ...) on interval vs date — know which you're holding.
-- 4. Comparing timestamp with timestamptz — implicit conversions lie.

-- TAKEAWAYS
-- * timestamptz = instant (store these); timestamp = naive wall clock.
-- * Sessions render instants in their zone; data never changes.
-- * now() frozen per transaction; clock_timestamp() for real time.
-- * Intervals carry calendar units; ranges (02-data-types/ranges.sql) are
--   the indexed way to express spans.

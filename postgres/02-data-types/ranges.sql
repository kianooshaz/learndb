-- ============================================================================
-- 02-data-types/ranges.sql — ranges, exclusion constraints, multiranges
-- ============================================================================
-- Run:  make sql FILE=02-data-types/ranges.sql
--
-- A range type stores [lower, upper) in ONE value — the difference between
-- writing scheduling logic in application code vs one DB constraint.
-- Ranges are GiST-indexable, which enables EXCLUSION constraints:
-- "no two rows may overlap" — the single most underused feature in
-- PostgreSQL for booking/scheduling systems.
-- ============================================================================

\set ON_ERROR_STOP on
DROP SCHEMA IF EXISTS m02_range CASCADE;
CREATE SCHEMA m02_range;
SET search_path TO m02_range;

-- Construction. Note '[...)' — inclusive lower, exclusive upper, by design
-- adjacent ranges then abut without overlap or gaps:
SELECT '[2026-09-25 09:00, 2026-09-25 10:00)'::tstzrange AS meeting;
SELECT '[3,7)'::int4range AS canonical_int,   -- int ranges normalize: [3,6]
       '[3,7)'::int4range = '[3,6]'::int4range AS same_range;

SELECT numrange(1.5, 3.0), daterange('2026-01-01','2026-02-01');

-- Bounds vocabulary: '[a,b]' inclusive, '(a,b)' exclusive, 'empty', and
-- unbounded ends '[a,)' / '(,b]':
SELECT '[5,)'::int4range AS open_ended, 'empty'::int4range AS empty_range,
       lower_inf('[5,)'::int4range) AS lower_is_infinite;

-- The operator set you'll use (all GiST-indexable):
SELECT int4range(5,10) @> 7                       AS contains_element,
       int4range(5,10) @> int4range(6,8)           AS contains_range,
       int4range(5,10) && int4range(8,20)         AS overlaps,
       int4range(5,10) << int4range(20,30)        AS strictly_left_of,
       int4range(5,10) -|- int4range(10,20)       AS adjacent;

-- ---------------------------------------------------------------------------
-- THE killer feature: exclusion constraints (no-overlap booking)
-- ---------------------------------------------------------------------------
CREATE TABLE room_bookings (
    id     bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    room   int NOT NULL,
    during tstzrange NOT NULL
);

-- This is the entire anti-double-booking logic. btree_gist lets the plain
-- int column and the range share ONE GiST index. EXCLUDE means: reject a
-- new row if it CONFLICTS with an existing row on the listed dimensions.
ALTER TABLE room_bookings ADD CONSTRAINT no_overlap
    EXCLUDE USING gist (room WITH =, during WITH &&);

INSERT INTO room_bookings (room, during) VALUES
    (1, tstzrange('2026-09-25 09:00+00','2026-09-25 10:30+00'));
-- A conflicting second booking is impossible, regardless of application bugs:
--   INSERT INTO room_bookings (room, during) VALUES
--       (1, tstzrange('2026-09-25 10:00+00','2026-09-25 11:00+00'));
--   ERROR: conflicting key value violates exclusion constraint "no_overlap"
INSERT INTO room_bookings (room, during) VALUES
    (1, tstzrange('2026-09-25 10:30+00','2026-09-25 11:00+00')),  -- abuts: OK
    (2, tstzrange('2026-09-25 09:00+00','2026-09-25 10:00+00'));  -- other room: OK

-- Compare the alternatives: UNIQUE(room, start_time) doesn't stop overlaps;
-- application-level locking needs advisory locks + retries and STILL races
-- (08-concurrency). The constraint is the only race-free home.

-- The pattern extends: shift calendars (daterange), subscription windows
-- (no two overlapping active plans per user), availability calendars.

-- ---------------------------------------------------------------------------
-- Gap detection and multiranges (PG14+)
-- ---------------------------------------------------------------------------
-- "Is room 1 free at noon?" — EXISTS + && beats any application-side check:
SELECT NOT EXISTS (
    SELECT 1 FROM room_bookings
    WHERE room = 1
      AND during && tstzrange('2026-09-25 12:00+00', '2026-09-25 13:00+00')
) AS room1_free_at_noon;

-- Multiranges: a set of ranges as ONE value (PG14+), with the same operators:
SELECT int4multirange(int4range(1,5), int4range(8,10)) AS multi,
       int4multirange(int4range(1,5), int4range(8,10)) @> 9 AS contains_9;
-- Real use: "user's working hours this week" as one value; aggregate with
-- range_agg / range_merge:
SELECT range_agg(during) AS combined
FROM room_bookings WHERE room = 1;

-- TAKEAWAYS
-- * Ranges = one value for [from, to); canonical [lower, upper).
-- * && / @> / << / -|- are GiST-indexable operators.
-- * EXCLUDE USING gist = declarative no-overlap; beats app locks.
-- * Multiranges aggregate sets of ranges; range_agg is their array_agg.

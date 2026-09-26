// ============================================================================
// 08-concurrency/race_conditions — check-then-act races and their fixes
// ============================================================================
// Run:
//   make up
//   go run ./08-concurrency/race_conditions
//
// Three production-shaped races, each with the wrong and the right version:
//   1. insert-if-not-exists:  SELECT-then-INSERT  vs  ON CONFLICT
//   2. claim-if-available:    SELECT-then-UPDATE  vs  atomic claim (SKIP LOCKED)
//   3. "at most N" invariant: count-then-insert   vs  atomic sequence cap
// ============================================================================
package main

import (
	"context"
	"fmt"
	"sync"
	"sync/atomic"

	"github.com/jackc/pgx/v5/pgxpool"

	"learndb/postgres/internal/db"
)

func main() {
	ctx := context.Background()
	pool := db.MustConnect(ctx)
	defer pool.Close()

	// race runs fn on n connections concurrently.
	race := func(n int, fn func(ctx context.Context, c *pgxpool.Conn, i int)) {
		var wg sync.WaitGroup
		for i := 0; i < n; i++ {
			wg.Add(1)
			go func(i int) {
				defer wg.Done()
				c, err := pool.Acquire(ctx)
				must(err)
				defer c.Release()
				fn(ctx, c, i)
			}(i)
		}
		wg.Wait()
	}

	mustExec(ctx, pool, `DROP SCHEMA IF EXISTS m08_race CASCADE; CREATE SCHEMA m08_race;`)

	// ------------------------------------------------------------------------
	// 1. Insert-if-not-exists (username registration)
	// ------------------------------------------------------------------------
	fmt.Println("1. insert-if-not-exists: 20 workers race to register username 'ada'")
	mustExec(ctx, pool, `CREATE TABLE m08_race.users (id int PRIMARY KEY, name text UNIQUE)`)

	// WRONG: SELECT, then INSERT if absent. The gap between check and act is
	// exactly where two workers both see "absent" and both insert — the
	// unique constraint then errors mid-flight, surprising the app.
	// (Barrier below makes ALL 20 workers complete their EXISTS check before
	// any of them inserts, so the race fires every run, not just sometimes —
	// in production it's exactly this "sometimes" quality that makes
	// check-then-act bugs survive test suites.)
	var dupeViolations atomic.Int64
	var checked atomic.Int64
	release := make(chan struct{})
	race(20, func(ctx context.Context, c *pgxpool.Conn, i int) {
		var exists bool
		must(c.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM m08_race.users WHERE name = 'ada')`).Scan(&exists))
		if checked.Add(1) == 20 {
			close(release) // all checks done — now everyone inserts at once
		}
		<-release
		if exists {
			return
		}
		_, err := c.Exec(ctx, `INSERT INTO m08_race.users (id, name) VALUES ($1, 'ada')`, i)
		if err != nil {
			dupeViolations.Add(1) // 23505 unique_violation: the race surfacing
		}
	})
	fmt.Printf("   check-then-insert: %d of 19 racing workers hit 23505 errors — fragile handling\n",
		dupeViolations.Load())

	mustExec(ctx, pool, `TRUNCATE m08_race.users`)
	// RIGHT: one atomic statement; the unique constraint is the guard and
	// ON CONFLICT is the graceful path around it:
	race(20, func(ctx context.Context, c *pgxpool.Conn, i int) {
		_, err := c.Exec(ctx, `
			INSERT INTO m08_race.users (id, name) VALUES ($1, 'ada')
			ON CONFLICT (name) DO NOTHING`, i)
		must(err)
	})
	var n int
	must(pool.QueryRow(ctx, `SELECT count(*) FROM m08_race.users WHERE name='ada'`).Scan(&n))
	fmt.Printf("   ON CONFLICT DO NOTHING: exactly %d row, zero errors, zero retry logic\n", n)

	// ------------------------------------------------------------------------
	// 2. Claim-if-available (inventory / seats / slots)
	// ------------------------------------------------------------------------
	fmt.Println("2. claim-if-available: 20 workers, 5 free items, first-come-first-served")
	mustExec(ctx, pool, `CREATE TABLE m08_race.items (id int PRIMARY KEY, owner text)`)
	mustExec(ctx, pool, `INSERT INTO m08_race.items SELECT g, NULL FROM generate_series(1,5) g`)

	// WRONG: SELECT a free item, then UPDATE it. Two workers select the SAME
	// free item; with a plain UPDATE one owner silently overwrites the other.
	// (We add "AND owner IS NULL" just to DETECT; naive code skips it.)
	var lostClaims atomic.Int64
	race(20, func(ctx context.Context, c *pgxpool.Conn, i int) {
		var itemID int
		err := c.QueryRow(ctx, `SELECT id FROM m08_race.items WHERE owner IS NULL ORDER BY id LIMIT 1`).Scan(&itemID)
		if err != nil {
			return
		}
		tag, err := c.Exec(ctx, `UPDATE m08_race.items SET owner = $1 WHERE id = $2 AND owner IS NULL`,
			"w"+fmt.Sprint(i), itemID)
		must(err)
		if tag.RowsAffected() == 0 {
			lostClaims.Add(1) // lost the gap race; WITHOUT "AND owner IS NULL"
			// this would be a silent overwrite of another worker's claim.
		}
	})
	var claimed int
	must(pool.QueryRow(ctx, `SELECT count(*) FROM m08_race.items WHERE owner IS NOT NULL`).Scan(&claimed))
	fmt.Printf("   select-then-update: %d gap-race losers, %d items claimed, silent-overwrite risk\n",
		lostClaims.Load(), claimed)

	// RIGHT: the claim and the pick are ONE statement. FOR UPDATE SKIP LOCKED
	// means concurrent claimers can never pick the same row, and never wait:
	mustExec(ctx, pool, `TRUNCATE m08_race.items; INSERT INTO m08_race.items SELECT g, NULL FROM generate_series(1,5) g`)
	race(20, func(ctx context.Context, c *pgxpool.Conn, i int) {
		_, err := c.Exec(ctx, `
			UPDATE m08_race.items SET owner = $1
			WHERE id = (SELECT id FROM m08_race.items
			            WHERE owner IS NULL
			            ORDER BY id
			            FOR UPDATE SKIP LOCKED
			            LIMIT 1)`, "w"+fmt.Sprint(i))
		must(err)
	})
	must(pool.QueryRow(ctx, `SELECT count(DISTINCT owner) FROM m08_race.items WHERE owner IS NOT NULL`).Scan(&claimed))
	fmt.Printf("   atomic SKIP LOCKED claim: %d items, all owned by distinct workers\n", claimed)

	// ------------------------------------------------------------------------
	// 3. "At most N" invariant (first 10 signups get the bonus)
	// ------------------------------------------------------------------------
	fmt.Println("3. \"at most 10\": count-then-insert races; atomic cap cannot")
	mustExec(ctx, pool, `CREATE TABLE m08_race.bonus (user_id int, seq int)`)

	// WRONG (skipped deliberately): SELECT count(*) ... INSERT if < 10 —
	// counts race, everyone reads 9, you end up with 30 bonus rows.
	//
	// RIGHT: nextval() is atomic — a sequence hands each caller a distinct
	// number, so "first 10" is decided by the sequence, not by a count:
	mustExec(ctx, pool, `CREATE SEQUENCE m08_race.bonus_seq MAXVALUE 10 NO CYCLE`)

	var overflowed int64 // unused by the sequence design; kept for symmetry
	_ = overflowed
	var seqErrs atomic.Int64
	race(30, func(ctx context.Context, c *pgxpool.Conn, i int) {
		var seq int
		err := c.QueryRow(ctx, `SELECT nextval('m08_race.bonus_seq')`).Scan(&seq)
		if err != nil {
			seqErrs.Add(1) // 2200H sequence out of range: the atomic rejection
			return
		}
		_, err = c.Exec(ctx, `INSERT INTO m08_race.bonus VALUES ($1, $2)`, i, seq)
		must(err)
	})
	must(pool.QueryRow(ctx, `SELECT count(*) FROM m08_race.bonus`).Scan(&n))
	fmt.Printf("   sequence cap: exactly %d bonus rows; %d workers atomically rejected (%d seq errors)\n",
		n, seqErrs.Load(), seqErrs.Load())
	// In production you'd usually catch 2200H and treat it as "not among the
	// first N". The invariant lives in the database, not in app logic.

	fmt.Println("\npattern: move check-and-act INSIDE one statement; constraints are the last line of defense.")
}

func mustExec(ctx context.Context, pool *pgxpool.Pool, sql string) {
	_, err := pool.Exec(ctx, sql)
	must(err)
}

func must(err error) {
	if err != nil {
		panic(err)
	}
}

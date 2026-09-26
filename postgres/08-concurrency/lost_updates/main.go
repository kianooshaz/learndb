// ============================================================================
// 08-concurrency/lost_updates — the classic bug, and its three correct fixes
// ============================================================================
// Run:
//   make up
//   go run ./08-concurrency/lost_updates
//
// THE BUG: read a value into Go, compute, write a constant back. Two racing
// transactions both read 100, both write (100+100)=200 — one update silently
// VANISHES. No error, no log: data gone. Expected final balance below is
// 300 (start 100, two deposits of 100).
//
// Variants:
//   A. naive read-modify-write in Go   -> deterministic LOST UPDATE
//   B. atomic UPDATE balance+100       -> correct (in-server read+write)
//   C. SELECT ... FOR UPDATE           -> correct (second waits, re-reads)
//   D. optimistic version column       -> correct (conflict DETECTED)
// ============================================================================
package main

import (
	"context"
	"fmt"
	"sync"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"

	"learndb/postgres/internal/db"
)

// connLike lets helpers accept either the pool or a single acquired conn.
type connLike interface {
	Exec(ctx context.Context, sql string, args ...any) (pgconn.CommandTag, error)
	Query(ctx context.Context, sql string, args ...any) (pgx.Rows, error)
	QueryRow(ctx context.Context, sql string, args ...any) pgx.Row
}

// stepGate forces a deterministic interleaving: both goroutines reach the
// barrier before either continues. That's how we make the race GUARANTEED
// instead of timing-lucky. (Note the send/receive ordering: A sends then
// waits; B waits for A then sends — a naive "both send first" handshake
// deadlocks, which is exactly the kind of bug this lab exists to teach.)
type stepGate struct{ a, b chan struct{} }

func (g *stepGate) sync(isA bool) {
	if isA {
		g.a <- struct{}{} // A signals presence
		<-g.b             // ...and waits for B
	} else {
		<-g.a             // B waits for A's signal
		g.b <- struct{}{} // ...then signals back
	}
}

func main() {
	ctx := context.Background()
	pool := db.MustConnect(ctx)
	defer pool.Close()

	setup := func(withVersion bool) {
		mustExec(ctx, pool, `DROP SCHEMA IF EXISTS m08_lost CASCADE; CREATE SCHEMA m08_lost;`)
		mustExec(ctx, pool, `CREATE TABLE m08_lost.accounts (
			id int PRIMARY KEY, balance int NOT NULL`+
			map[bool]string{true: ", version int NOT NULL DEFAULT 1", false: ""}[withVersion]+`)`)
		mustExec(ctx, pool, `INSERT INTO m08_lost.accounts (id, balance) VALUES (1, 100)`)
	}

	// runPair spins up two connections and runs worker(isA) on each.
	runPair := func(worker func(ctx context.Context, c connLike, gate *stepGate, isA bool)) {
		gate := &stepGate{a: make(chan struct{}), b: make(chan struct{})}
		var wg sync.WaitGroup
		for _, isA := range []bool{true, false} {
			wg.Add(1)
			go func(isA bool) {
				defer wg.Done()
				c, err := pool.Acquire(ctx)
				must(err)
				defer c.Release()
				worker(ctx, c, gate, isA)
			}(isA)
		}
		wg.Wait()
	}

	report := func(label string, expected int) {
		var balance int
		must(pool.QueryRow(ctx, `SELECT balance FROM m08_lost.accounts WHERE id = 1`).Scan(&balance))
		verdict := "correct"
		if balance != expected {
			verdict = fmt.Sprintf("<<< WRONG (expected %d)", expected)
		}
		fmt.Printf("  %-34s final=%3d  %s\n", label, balance, verdict)
	}

	// ------------------------------------------------------------------------
	// A. NAIVE — the bug, deterministic thanks to the gate.
	// ------------------------------------------------------------------------
	fmt.Println("A. naive Go-side read-modify-write (gated so the race is certain):")
	setup(false)
	runPair(func(ctx context.Context, c connLike, gate *stepGate, isA bool) {
		mustExec(ctx, c, `BEGIN`)
		var b int
		must(c.QueryRow(ctx, `SELECT balance FROM m08_lost.accounts WHERE id = 1`).Scan(&b))
		gate.sync(isA) // <- both workers have read 100 before either writes
		_, err := c.Exec(ctx, `UPDATE m08_lost.accounts SET balance = $1 WHERE id = 1`, b+100)
		must(err)
		mustExec(ctx, c, `COMMIT`)
	})
	report("both deposit 100 from stale reads", 300)

	// ------------------------------------------------------------------------
	// B. ATOMIC — one statement does the read-modify-write inside the server.
	// ------------------------------------------------------------------------
	fmt.Println("B. atomic in-server UPDATE (EvalPlanQual re-checks on wait):")
	setup(false)
	runPair(func(ctx context.Context, c connLike, gate *stepGate, isA bool) {
		_ = gate
		mustExec(ctx, c, `BEGIN`)
		_, err := c.Exec(ctx, `UPDATE m08_lost.accounts SET balance = balance + 100 WHERE id = 1`)
		must(err)
		mustExec(ctx, c, `COMMIT`)
	})
	report("both: balance = balance + 100", 300)

	// ------------------------------------------------------------------------
	// C. PESSIMISTIC — take the row lock BEFORE reading.
	// ------------------------------------------------------------------------
	fmt.Println("C. SELECT ... FOR UPDATE (second writer waits + re-reads):")
	setup(false)
	runPair(func(ctx context.Context, c connLike, gate *stepGate, isA bool) {
		_ = gate
		mustExec(ctx, c, `BEGIN`)
		var b int
		// FOR UPDATE blocks the second worker here until the first commits;
		// after acquiring, the read is guaranteed current.
		must(c.QueryRow(ctx, `SELECT balance FROM m08_lost.accounts WHERE id = 1 FOR UPDATE`).Scan(&b))
		_, err := c.Exec(ctx, `UPDATE m08_lost.accounts SET balance = $1 WHERE id = 1`, b+100)
		must(err)
		mustExec(ctx, c, `COMMIT`)
	})
	report("lock row, then compute in Go", 300)

	// ------------------------------------------------------------------------
	// D. OPTIMISTIC — version column; CAS-style UPDATE; detect the loser.
	// ------------------------------------------------------------------------
	fmt.Println("D. optimistic version check (compare-and-swap UPDATE):")
	setup(true)
	var winner, loser string
	runPair(func(ctx context.Context, c connLike, gate *stepGate, isA bool) {
		name := map[bool]string{true: "A", false: "B"}[isA]
		mustExec(ctx, c, `BEGIN`)
		var b, v int
		must(c.QueryRow(ctx, `SELECT balance, version FROM m08_lost.accounts WHERE id = 1`).Scan(&b, &v))
		gate.sync(isA) // both hold the same (balance, version) snapshot
		tag, err := c.Exec(ctx, `
			UPDATE m08_lost.accounts
			SET balance = $1, version = version + 1
			WHERE id = 1 AND version = $2`, b+100, v)
		must(err)
		if tag.RowsAffected() == 1 {
			winner = name // first commit wins the CAS
			mustExec(ctx, c, `COMMIT`)
		} else {
			loser = name // zero rows: someone bumped the version under us
			mustExec(ctx, c, `ROLLBACK`)
			// A production service would RETRY from the top with fresh reads
			// (optimistic_locking/ implements the retry loop).
		}
	})
	// 200 is CORRECT here WITHOUT a retry: one deposit applied, the other
	// conflict DETECTED and rolled back. Nothing silently vanished — the
	// loser knows and would retry (see optimistic_locking).
	report("CAS update, loser rolled back", 200)
	fmt.Printf("  winner=%s loser=%s (loser would retry in a real service)\n", winner, loser)
}

func mustExec(ctx context.Context, c connLike, sql string) {
	_, err := c.Exec(ctx, sql)
	must(err)
}

func must(err error) {
	if err != nil {
		panic(err)
	}
}

var _ = pgxpool.Pool{} // keep import for the connLike implementors

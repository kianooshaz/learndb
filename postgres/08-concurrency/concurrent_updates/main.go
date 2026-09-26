// ============================================================================
// 08-concurrency/concurrent_updates — what two writers see when they race
// ============================================================================
// Run:
//   make up
//   go run ./08-concurrency/concurrent_updates
//
// Automates the experiments from 06-transactions:
//   1. reader vs uncommitted writer: concurrent SELECT sails through
//      (MVCC: readers never block, no dirty reads).
//   2. writer vs writer on the same row: the second waits for the first
//      to commit — measured.
//   3. who is blocking whom: pg_blocking_pids() while a wait is live.
// ============================================================================
package main

import (
	"context"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5/pgconn"

	"learndb/postgres/internal/db"
)

func main() {
	ctx := context.Background()
	pool := db.MustConnect(ctx)
	defer pool.Close()

	mustExec(ctx, pool, `DROP SCHEMA IF EXISTS m08_concurrent CASCADE; CREATE SCHEMA m08_concurrent;`)
	mustExec(ctx, pool, `CREATE TABLE m08_concurrent.accounts (id int PRIMARY KEY, balance int NOT NULL)`)
	mustExec(ctx, pool, `INSERT INTO m08_concurrent.accounts VALUES (1, 100)`)

	// -----------------------------------------------------------------------
	// 1. Reader during an uncommitted write — MVCC means no blocking
	// -----------------------------------------------------------------------
	w1, err := pool.Acquire(ctx) // dedicated connection for the writer tx
	must(err)
	defer w1.Release()

	_, err = w1.Exec(ctx, `BEGIN`)
	must(err)
	_, err = w1.Exec(ctx, `UPDATE m08_concurrent.accounts SET balance = 0 WHERE id = 1`)
	must(err)
	fmt.Println("[writer ] UPDATE applied inside tx (NOT committed yet)")

	var balance int
	must(pool.QueryRow(ctx, `SELECT balance FROM m08_concurrent.accounts WHERE id = 1`).Scan(&balance))
	fmt.Printf("[reader ] concurrent SELECT returns immediately: balance=%d\n", balance)
	fmt.Println("           (reader saw the last COMMITTED version — no dirty read, no wait)")

	// -----------------------------------------------------------------------
	// 2. Second writer on the same row — it must WAIT
	// -----------------------------------------------------------------------
	start := time.Now()
	go func() {
		time.Sleep(500 * time.Millisecond) // writer 1 hesitates before COMMIT
		_, err := w1.Exec(ctx, `COMMIT`)
		must(err)
	}()

	tag, err := pool.Exec(ctx, `UPDATE m08_concurrent.accounts SET balance = balance + 50 WHERE id = 1`)
	must(err)
	waited := time.Since(start)
	fmt.Printf("[writer2] UPDATE blocked %dms on writer1's row lock, then COMMITTED-visibility\n",
		waited.Milliseconds())
	fmt.Printf("           rows affected: %d, final balance: read below\n", tag.RowsAffected())

	var final int
	must(pool.QueryRow(ctx, `SELECT balance FROM m08_concurrent.accounts`).Scan(&final))
	fmt.Printf("[result ] balance=%d (0 from writer1 + 50 from writer2, applied in commit order)\n", final)

	// Note writer2 did NOT re-read 0 in Go and write a constant — it executed
	// `balance = balance + 50` INSIDE the server, which at READ COMMITTED
	// re-evaluates against the NEW committed version (EvalPlanQual). Atomic
	// in-statement read-modify-write is safe; the LOST UPDATE happens when
	// apps read into Go, compute, and write a constant — next program.

	fmt.Println("\nnext: 08-concurrency/lost_updates — where naive app-side writes lose data")
}

func mustExec(ctx context.Context, pool interface {
	Exec(context.Context, string, ...any) (pgconn.CommandTag, error)
}, sql string) {
	_, err := pool.Exec(ctx, sql)
	must(err)
}

func must(err error) {
	if err != nil {
		panic(err)
	}
}

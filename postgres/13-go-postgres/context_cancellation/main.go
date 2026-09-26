// ============================================================================
// 13-go-postgres/context_cancellation — canceling queries the right way
// ============================================================================
// Run:
//   make up
//   go run ./13-go-postgres/context_cancellation
//
// Two ways to stop a long query:
//   1. context.Context deadline — pgx sends a CANCEL REQUEST to the server,
//      which aborts the query. The connection returns to the pool healthy.
//   2. statement_timeout (server-side) — the server kills it itself; the
//      error is 57014 query_canceled either way.
//
// Best practice: per-request ctx deadline at the HANDLER layer (e.g. 5s) +
// statement_timeout as a server-side seatbelt for everything else.
// ============================================================================
package main

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5/pgconn"

	"learndb/postgres/internal/db"
)

func main() {
	ctx := context.Background()
	pool := db.MustConnect(ctx)
	defer pool.Close()

	// -----------------------------------------------------------------------
	// 1. ctx deadline cancels the running query ON THE SERVER
	// -----------------------------------------------------------------------
	qctx, cancel := context.WithTimeout(ctx, 300*time.Millisecond)
	defer cancel()

	start := time.Now()
	_, err := pool.Exec(qctx, `SELECT pg_sleep(10)`) // 10s server-side sleep
	dur := time.Since(start)

	var pgErr *pgconn.PgError
	switch {
	case errors.Is(err, context.DeadlineExceeded):
		fmt.Printf("ctx cancel after %dms: %v\n", dur.Milliseconds(), err)
	case errors.As(err, &pgErr) && pgErr.Code == "57014":
		fmt.Printf("server canceled (57014) after %dms\n", dur.Milliseconds())
	case err == nil:
		fmt.Println("query finished (unexpectedly fast!)")
	default:
		fmt.Printf("other error after %dms: %v\n", dur.Milliseconds(), err)
	}
	// KEY FACT: pgx does NOT just hang up. It sends the out-of-band cancel
	// request, so the server stops BURNING CPU on that query. A naive
	// "close the socket" would leave the query running until it finishes!

	// Prove the query is really gone from the server. (EXCLUDE our own pid —
	// this very check's query text contains "pg_sleep(10)" and would
	// otherwise match itself: a classic pg_stat_activity gotcha.)
	var n int
	must(pool.QueryRow(ctx, `
		SELECT count(*) FROM pg_stat_activity
		WHERE query LIKE '%pg_sleep(10)%'
		  AND state <> 'idle'
		  AND pid <> pg_backend_pid()`).Scan(&n))
	fmt.Println("pg_sleep(10) still running on server:", n, "(0 = cancel reached it)")

	// -----------------------------------------------------------------------
	// 2. The connection survived and is reusable
	// -----------------------------------------------------------------------
	var one int
	must(pool.QueryRow(ctx, `SELECT 1`).Scan(&one))
	fmt.Println("connection healthy after cancel:", one == 1)

	// -----------------------------------------------------------------------
	// 3. Server-side seatbelt: statement_timeout
	// -----------------------------------------------------------------------
	// Set per ROLE/database (persistent) or per tx; here per-statement tx scope:
	tx, err := pool.Begin(ctx)
	must(err)
	defer tx.Rollback(ctx)
	_, err = tx.Exec(ctx, `SET LOCAL statement_timeout = '200ms'`)
	must(err)
	start = time.Now()
	_, err = tx.Exec(ctx, `SELECT pg_sleep(10)`)
	dur = time.Since(start)
	if errors.As(err, &pgErr) && pgErr.Code == "57014" {
		fmt.Printf("statement_timeout killed it after %dms (SQLSTATE 57014)\n",
			dur.Milliseconds())
	} else {
		fmt.Println("statement_timeout test:", err)
	}
	_ = tx.Rollback(ctx)

	// ctx deadline vs statement_timeout — use BOTH:
	//   ctx                -> bounds the whole handler (client-gone, upstream
	//                         timeout, user abort)
	//   statement_timeout  -> bounds any query even if the app forgot ctx
	// A third guard for fleets: idle_in_transaction_session_timeout, which
	// kills connections that began a tx and vanished (12-production).

	fmt.Println("\nnext: error_handling — turning SQLSTATEs into decisions")
}

func must(err error) {
	if err != nil {
		panic(err)
	}
}

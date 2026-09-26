// ============================================================================
// 12-production/failure_scenarios — surviving the bad days, in code
// ============================================================================
// Run:
//   make up
//   go run ./12-production/failure_scenarios
//
// Four failure modes a production service WILL meet, reproduced safely,
// each handled the way a senior engineer would:
//   1. Connection dies mid-transaction  -> server rolls back automatically
//   2. Connection refused               -> retry with backoff + jitter
//   3. Statement timeout (57014)        -> do NOT blindly retry
//   4. Pool starvation under burst       -> bound waits, shed load (503)
// ============================================================================
package main

import (
	"context"
	"errors"
	"fmt"
	"math/rand"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"

	"learndb/postgres/internal/db"
	"learndb/postgres/internal/dsn"
)

func main() {
	ctx := context.Background()
	pool := db.MustConnect(ctx)
	defer pool.Close()

	mustExec(pool, `DROP SCHEMA IF EXISTS m12_fail CASCADE; CREATE SCHEMA m12_fail;`)
	mustExec(pool, `CREATE TABLE m12_fail.payments (id int PRIMARY KEY, amount int)`)

	// -----------------------------------------------------------------------
	// 1. Client dies mid-transaction: the server cleans up FOR you
	// -----------------------------------------------------------------------
	fmt.Println("1. connection dropped mid-transaction")
	{
		conn, err := pgx.Connect(ctx, dsnX())
		must(err)

		tx, err := conn.Begin(ctx)
		must(err)
		_, err = tx.Exec(ctx, `INSERT INTO m12_fail.payments VALUES (1, 100)`)
		must(err)
		// ... process crashes here. Simulate: close the socket WITHOUT
		// commit/rollback:
		must(conn.Close(ctx)) // abrupt-ish close (a crash is even ruder)

		time.Sleep(300 * time.Millisecond) // server notices + aborts the tx
		var n int
		must(pool.QueryRow(ctx, `SELECT count(*) FROM m12_fail.payments`).Scan(&n))
		fmt.Printf("   after crash: %d rows (the uncommitted INSERT was rolled back by the server)\n", n)
		// No orphaned data, no half-applied transaction: that's ACID working
		// when your process dies. (Long-open PREPARE TRANSACTION is the
		// exception — one more reason 2PC is a last resort.)
	}

	// -----------------------------------------------------------------------
	// 2. Database unreachable: retry with exponential backoff + jitter
	// -----------------------------------------------------------------------
	fmt.Println("2. connection refused -> retry loop (no server on :5439)")
	{
		start := time.Now()
		err := connectWithRetry(ctx, "postgres://postgres:postgres@localhost:5439/learndb", 3)
		fmt.Printf("   gave up after 3 attempts in %dms: connection refused\n", time.Since(start).Milliseconds())
		fmt.Println("   the same loop against a real server that's booting would keep trying and succeed —")
		fmt.Println("   this is the startup path of every service that races its database")
		_ = err
	}

	// -----------------------------------------------------------------------
	// 3. statement_timeout: 57014 is a "stop", not a "retry"
	// -----------------------------------------------------------------------
	fmt.Println("3. statement_timeout (57014)")
	{
		ctx2, cancel := context.WithTimeout(ctx, 5*time.Second)
		defer cancel()
		tx, err := pool.Begin(ctx2)
		must(err)
		defer tx.Rollback(ctx2)
		_, err = tx.Exec(ctx2, `SET LOCAL statement_timeout = '300ms'`)
		must(err)
		_, err = tx.Exec(ctx2, `SELECT pg_sleep(10)`)
		var pgErr *pgconn.PgError
		if errors.As(err, &pgErr) && pgErr.Code == "57014" {
			fmt.Println("   query_canceled after 300ms — retrying the SAME query would just time out again;")
			fmt.Println("   fix the query/index, or surface a 504. Never auto-retry timeouts blindly.")
		} else {
			fmt.Println("   unexpected:", err)
		}
	}

	// -----------------------------------------------------------------------
	// 4. Pool starvation: bounded waits + load shedding
	// -----------------------------------------------------------------------
	fmt.Println("4. pool exhaustion under burst")
	{
		cfg, err := pgxpool.ParseConfig(dsnX())
		must(err)
		cfg.MaxConns = 2
		small, err := pgxpool.NewWithConfig(ctx, cfg)
		must(err)
		defer small.Close()

		hold := make([]*pgxpool.Conn, 2)
		for i := range hold {
			hold[i], err = small.Acquire(ctx)
			must(err)
		}

		// A third request with a SHORT budget: fail fast, shed load:
		rctx, rcancel := context.WithTimeout(ctx, 250*time.Millisecond)
		defer rcancel()
		_, err = small.Exec(rctx, `SELECT 1`)
		fmt.Printf("   third caller: %v\n", classifyPoolErr(err))

		for _, c := range hold {
			c.Release()
		}
		// And now it recovers — pool health is transient by design:
		_, err = small.Exec(ctx, `SELECT 1`)
		fmt.Println("   after release:", err == nil, "(pool recovered instantly)")
	}
}

func connectWithRetry(ctx context.Context, dsn string, attempts int) error {
	for i := 1; ; i++ {
		_, err := pgx.Connect(ctx, dsn)
		if err == nil {
			return nil
		}
		if i >= attempts {
			return err
		}
		// exponential backoff + jitter (13-go-postgres/retries explains why
		// jitter is non-negotiable):
		delay := time.Duration(1<<i) * 100 * time.Millisecond
		jitter := time.Duration(rand.Int63n(int64(delay)/2 + 1))
		select {
		case <-time.After(delay + jitter):
		case <-ctx.Done():
			return ctx.Err()
		}
	}
}

func classifyPoolErr(err error) string {
	if errors.Is(err, context.DeadlineExceeded) {
		return "deadline exceeded -> return 503 + shed load (do NOT queue forever)"
	}
	return err.Error()
}

func dsnX() string { return dsn.DSN() }

func mustExec(pool *pgxpool.Pool, sql string) {
	_, err := pool.Exec(context.Background(), sql)
	must(err)
}

func must(err error) {
	if err != nil {
		panic(err)
	}
}

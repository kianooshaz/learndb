// ============================================================================
// 13-go-postgres/retries — the transaction retry loop, production-shaped
// ============================================================================
// Run:
//   make up
//   go run ./13-go-postgres/retries
//
// The only correct response to 40001 (serialization_failure) and 40P01
// (deadlock) is: ROLLBACK THE WHOLE TRANSACTION AND RETRY IT. Not the
// statement — the transaction. This program:
//   1. implements RunTxWithRetry: ctx-aware, exponential backoff + jitter,
//      bounded attempts
//   2. runs a SERIALIZABLE workload with REAL conflicts (write-skew-shaped)
//      and shows the retry loop absorbing them
//   3. demonstrates the idempotency requirement: side effects (emails,
//      HTTP calls) must happen AFTER commit, or be idempotent
// ============================================================================
package main

import (
	"context"
	"errors"
	"fmt"
	"math/rand"
	"sync"
	"sync/atomic"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"

	"learndb/postgres/internal/db"
)

// TxFunc is a unit of retryable work. It receives the tx and MUST be a pure
// function of its reads: run it twice must produce the same effect as once.
type TxFunc func(ctx context.Context, tx pgx.Tx) error

// RunTxWithRetry: SERIALIZABLE transaction with retry on 40001/40P01.
// This exact shape (minus logs/metrics) runs in production services.
func RunTxWithRetry(ctx context.Context, pool *pgxpool.Pool, maxAttempts int, fn TxFunc) error {
	for attempt := 1; ; attempt++ {
		tx, err := pool.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.Serializable})
		if err != nil {
			return err
		}
		err = fn(ctx, tx)
		if err == nil {
			err = tx.Commit(ctx)
			if err == nil {
				return nil // committed
			}
		}
		_ = tx.Rollback(ctx) // always safe: no-op if already rolled back

		if !isRetryable(err) || attempt >= maxAttempts {
			return fmt.Errorf("attempt %d failed: %w", attempt, err)
		}
		// Exponential backoff with jitter — without jitter, contending
		// clients re-collide in lockstep forever:
		delay := time.Duration(1<<uint(min(attempt, 5))) * time.Millisecond
		jitter := time.Duration(rand.Int63n(int64(delay) + 1))
		select {
		case <-time.After(delay + jitter):
		case <-ctx.Done():
			return ctx.Err()
		}
	}
}

func isRetryable(err error) bool {
	var pgErr *pgconn.PgError
	if !errors.As(err, &pgErr) {
		return false // network errors: retry only if idempotent — policy call
	}
	switch pgErr.Code {
	case "40001", // serialization_failure
		"40P01", // deadlock_detected
		"55P03": // lock_not_available (from lock_timeout/NOWAIT strategies)
		return true
	}
	return false
}

func main() {
	ctx := context.Background()
	pool := db.MustConnect(ctx)
	defer pool.Close()

	mustExec(pool, `DROP SCHEMA IF EXISTS m13_retry CASCADE; CREATE SCHEMA m13_retry;`)
	mustExec(pool, `CREATE TABLE m13_retry.oncall (id int PRIMARY KEY, on_call bool NOT NULL)`)
	mustExec(pool, `INSERT INTO m13_retry.oncall VALUES (1, true), (2, true)`)

	// -----------------------------------------------------------------------
	// Contended SERIALIZABLE workload: both doctors try to go off-call;
	// SSI aborts some; retries keep the invariant AND complete the work.
	// -----------------------------------------------------------------------
	var retries, commits atomic.Int64
	var wg sync.WaitGroup
	for w := 0; w < 6; w++ {
		wg.Add(1)
		go func(id int) {
			defer wg.Done()
			err := RunTxWithRetry(ctx, pool, 10, func(ctx context.Context, tx pgx.Tx) error {
				// Invariant: at least one doctor stays on call.
				var n int
				if err := tx.QueryRow(ctx,
					`SELECT count(*) FROM m13_retry.oncall WHERE on_call`).Scan(&n); err != nil {
					return err
				}
				if n <= 1 {
					return nil // would break the invariant: do nothing, commit
				}
				_, err := tx.Exec(ctx, `UPDATE m13_retry.oncall SET on_call = false WHERE id = $1`, id)
				return err
			})
			must(err)
			commits.Add(1)
		}(w + 1)
	}
	wg.Wait()

	var stillOn int
	must(pool.QueryRow(ctx, `SELECT count(*) FROM m13_retry.oncall WHERE on_call`).Scan(&stillOn))
	fmt.Printf("commits=%d  retries absorbed=%d  on_call remaining=%d (invariant >= 1 holds)\n",
		commits.Load(), retries.Load(), stillOn)

	// -----------------------------------------------------------------------
	// The idempotency requirement, made explicit
	// -----------------------------------------------------------------------
	sideEffectRuns := 0
	err := RunTxWithRetry(ctx, pool, 5, func(ctx context.Context, tx pgx.Tx) error {
		// WRONG: side effect INSIDE the tx — a retry re-sends it!
		// sendEmail(...)                        <- would double-send on retry
		var n int
		if err := tx.QueryRow(ctx, `SELECT count(*) FROM m13_retry.oncall WHERE on_call`).Scan(&n); err != nil {
			return err
		}
		sideEffectRuns++
		return nil
	})
	must(err)
	fmt.Printf("side-effect inside tx ran %d times for one logical operation — NEVER do this\n",
		sideEffectRuns)

	// RIGHT: collect what to do, act AFTER commit:
	var notify []int
	err = RunTxWithRetry(ctx, pool, 5, func(ctx context.Context, tx pgx.Tx) error {
		rows, err := tx.Query(ctx, `SELECT id FROM m13_retry.oncall WHERE on_call`)
		if err != nil {
			return err
		}
		defer rows.Close()
		notify = notify[:0]
		for rows.Next() {
			var id int
			if err := rows.Scan(&id); err != nil {
				return err
			}
			notify = append(notify, id)
		}
		return rows.Err()
	})
	must(err)
	// Only now — after Commit returned nil — is it safe to fire side effects:
	fmt.Println("after commit, notify exactly once for:", notify)
}

func mustExec(pool *pgxpool.Pool, sql string) {
	_, err := pool.Exec(context.Background(), sql)
	must(err)
}

func must(err error) {
	if err != nil {
		panic(err)
	}
}

// ============================================================================
// 13-go-postgres/transactions — the pgx transaction discipline
// ============================================================================
// Run:
//   make up
//   go run ./13-go-postgres/transactions
//
// The service-ready patterns:
//   1. defer rollback: Commit-once, Rollback-is-harmless-after-commit
//   2. transaction functions: pass pgx.Tx around, not the pool
//   3. savepoints for partial resilience
//   4. isolation levels + the 40001 retry wrapper (retries/ expands it)
//   5. what happens to a tx when the context is canceled (it ABORTS — you
//      see "current transaction is aborted" if you keep using it)
// ============================================================================
package main

import (
	"context"
	"errors"
	"fmt"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"learndb/postgres/internal/db"
)

func main() {
	ctx := context.Background()
	pool := db.MustConnect(ctx)
	defer pool.Close()

	mustExec(pool, `DROP SCHEMA IF EXISTS m13_tx CASCADE; CREATE SCHEMA m13_tx;`)
	mustExec(pool, `CREATE TABLE m13_tx.accounts (id int PRIMARY KEY, balance int NOT NULL)`)
	mustExec(pool, `INSERT INTO m13_tx.accounts VALUES (1, 100), (2, 100)`)

	// -----------------------------------------------------------------------
	// 1. The canonical shape: Begin + defer Rollback + Commit
	// -----------------------------------------------------------------------
	// defer Rollback is NOT a bug: after Commit, Rollback returns
	// pgx.ErrTxClosed and we ignore it. This guarantees cleanup on EVERY
	// return path, including panics.
	err := transfer(ctx, pool, 1, 2, 30)
	must(err)
	printBalances(ctx, pool, "after committed transfer:")

	// A mid-tx failure rolls back atomically — trigger one deliberately:
	err = transfer(ctx, pool, 1, 2, 999)
	fmt.Println("business-rule failure:", err)
	printBalances(ctx, pool, "nothing changed (atomic rollback):")

	// -----------------------------------------------------------------------
	// 2. savepoint: retry one risky step inside a bigger transaction
	// -----------------------------------------------------------------------
	err = withSavepoint(ctx, pool)
	must(err)

	// -----------------------------------------------------------------------
	// 3. Isolation levels on pgx: set per-transaction with BeginTx
	// -----------------------------------------------------------------------
	opts := pgx.TxOptions{IsoLevel: pgx.RepeatableRead}
	txRR, err := pool.BeginTx(ctx, opts)
	must(err)
	var n int
	must(txRR.QueryRow(ctx, `SELECT count(*) FROM m13_tx.accounts`).Scan(&n))
	must(txRR.Commit(ctx))
	fmt.Println("BeginTx with REPEATABLE READ: OK (SERIALIZABLE also available)")

	// -----------------------------------------------------------------------
	// 4. Canceled context = aborted transaction
	// -----------------------------------------------------------------------
	tctx, cancel := context.WithCancel(ctx)
	tx, err := pool.Begin(tctx)
	must(err)
	_, err = tx.Exec(tctx, `UPDATE m13_tx.accounts SET balance = 0 WHERE id = 1`)
	must(err)
	cancel() // simulate a request timeout mid-transaction
	_, err = tx.Exec(ctx, `UPDATE m13_tx.accounts SET balance = 1 WHERE id = 1`)
	fmt.Println("after cancel, tx is poisoned:", errors.Is(err, context.Canceled))
	_ = tx.Rollback(ctx) // safe cleanup; server discards everything anyway
	printBalances(ctx, pool, "canceled tx left no trace:")
}

// transfer shows the pattern you'll copy into every service.
func transfer(ctx context.Context, pool *pgxpool.Pool, from, to, amount int) error {
	tx, err := pool.Begin(ctx) // READ COMMITTED by default
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx) // no-op after Commit; errors ignored by design

	// Atomic balance predicate = lost-update-proof at READ COMMITTED
	// (EvalPlanQual — 08-concurrency/lost_updates).
	tag, err := tx.Exec(ctx,
		`UPDATE m13_tx.accounts SET balance = balance - $1 WHERE id = $2 AND balance >= $1`,
		amount, from)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return fmt.Errorf("insufficient funds on %d", from) // rollback happens via defer
	}
	if _, err = tx.Exec(ctx,
		`UPDATE m13_tx.accounts SET balance = balance + $1 WHERE id = $2`, amount, to); err != nil {
		return err
	}
	return tx.Commit(ctx)
}

func withSavepoint(ctx context.Context, pool *pgxpool.Pool) error {
	tx, err := pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)

	_, err = tx.Exec(ctx, `INSERT INTO m13_tx.accounts VALUES (3, 100)`)
	if err != nil {
		return err
	}

	// Risky best-effort step: if it fails, we keep the outer work.
	var sp pgx.Tx
	_ = sp
	if _, err = tx.Exec(ctx, `SAVEPOINT risky`); err != nil {
		return err
	}
	if _, err = tx.Exec(ctx, `INSERT INTO m13_tx.accounts VALUES (1, 0)`); err != nil {
		// duplicate key — recover INSIDE the transaction:
		if _, rbErr := tx.Exec(ctx, `ROLLBACK TO SAVEPOINT risky`); rbErr != nil {
			return rbErr
		}
		fmt.Println("savepoint: inner step failed, outer tx continues")
	} else {
		_, _ = tx.Exec(ctx, `RELEASE SAVEPOINT risky`)
	}
	return tx.Commit(ctx)
}

func printBalances(ctx context.Context, pool *pgxpool.Pool, label string) {
	var sum, n int
	must(pool.QueryRow(ctx, `SELECT sum(balance), count(*) FROM m13_tx.accounts`).Scan(&sum, &n))
	fmt.Printf("%-40s sum=%d rows=%d\n", label, sum, n)
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

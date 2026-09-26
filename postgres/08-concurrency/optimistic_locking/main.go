// ============================================================================
// 08-concurrency/optimistic_locking — version columns + retry, under load
// ============================================================================
// Run:
//   make up
//   go run ./08-concurrency/optimistic_locking
//
// Optimistic locking: NO locks while reading. Every row carries a version;
// writers must match the version they read (compare-and-swap). Losers get
// zero affected rows (or 40001 under SERIALIZABLE) and RETRY with backoff.
//
//   + readers never block, no lock waits, scales with low contention
//   - retries under contention; work must be re-doable (pure function of
//     fresh reads; side effects only AFTER commit)
//
// This program hammers one hot row with N concurrent increment attempts,
// each with a bounded retry loop and exponential backoff + jitter — the
// exact pattern you'd ship for cart/session/document updates.
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
	"github.com/jackc/pgx/v5/pgxpool"

	"learndb/postgres/internal/db"
)

const workers = 8
const perWorker = 25

func main() {
	ctx := context.Background()
	pool := db.MustConnect(ctx)
	defer pool.Close()

	mustExec(ctx, pool, `DROP SCHEMA IF EXISTS m08_opt CASCADE; CREATE SCHEMA m08_opt;`)
	mustExec(ctx, pool, `CREATE TABLE m08_opt.carts (
		id       int PRIMARY KEY,
		items    jsonb NOT NULL DEFAULT '[]',
		version  int  NOT NULL DEFAULT 1
	)`)
	mustExec(ctx, pool, `INSERT INTO m08_opt.carts (id) VALUES (1)`)

	var retries, conflicts atomic.Int64
	var wg sync.WaitGroup
	start := time.Now()

	for w := 0; w < workers; w++ {
		wg.Add(1)
		go func(w int) {
			defer wg.Done()
			c, err := pool.Acquire(ctx)
			must(err)
			defer c.Release()

			for i := 0; i < perWorker; i++ {
				must(incrementWithRetry(ctx, c, &retries, &conflicts))
			}
		}(w)
	}
	wg.Wait()
	elapsed := time.Since(start)

	var version, jsonLen int
	must(pool.QueryRow(ctx, `SELECT version, jsonb_array_length(items) FROM m08_opt.carts WHERE id = 1`).
		Scan(&version, &jsonLen))

	fmt.Printf("workers=%d attempts=%d  committed=%d (version, starts at 1) in %.1fs\n",
		workers, workers*perWorker, version, elapsed.Seconds())
	fmt.Printf("conflicts detected=%d  retries performed=%d — nothing lost, all eventually committed\n",
		conflicts.Load(), retries.Load())
	if jsonLen != workers*perWorker { // count of appended items = real success count
		fmt.Printf("BUG: expected %d items, got %d!\n", workers*perWorker, jsonLen)
	}
}

// incrementWithRetry appends one item to the cart using optimistic locking.
// This is the production pattern: read version -> CAS write -> retry loop.
func incrementWithRetry(ctx context.Context, c *pgxpool.Conn, retries, conflicts *atomic.Int64) error {
	for attempt := 0; ; attempt++ {
		if attempt > 0 {
			retries.Add(1)
			// Exponential backoff + jitter: without jitter, retriers
			// re-collide in lockstep (thundering herd).
			delay := time.Duration(1<<uint(min(attempt, 6))) * time.Millisecond // min builtin (Go 1.21+)
			jitter := time.Duration(rand.Int63n(int64(delay) + 1))
			select {
			case <-time.After(delay + jitter):
			case <-ctx.Done():
				return ctx.Err()
			}
		}

		// READ phase — no locks taken, always fresh at READ COMMITTED:
		var version int
		err := c.QueryRow(ctx, `SELECT version FROM m08_opt.carts WHERE id = 1`).Scan(&version)
		if err != nil {
			return err
		}

		// WRITE phase — the CAS. If another worker committed since our read,
		// version no longer matches and this affects 0 rows:
		tag, err := c.Exec(ctx, `
			UPDATE m08_opt.carts
			SET items = items || jsonb_build_object('sku', 'SKU-' || $1, 'qty', 1),
			    version = version + 1
			WHERE id = 1 AND version = $2`,
			fmt.Sprintf("w%d-i%d", attempt, version), version)
		if err != nil {
			return err
		}
		if tag.RowsAffected() == 1 {
			return nil // won the CAS
		}
		conflicts.Add(1) // lost — loop and retry with a fresh read
	}
}

func mustExec(ctx context.Context, pool *pgxpool.Pool, sql string) {
	_, err := pool.Exec(ctx, sql)
	must(err)
}

func must(err error) {
	if err != nil && !errors.Is(err, pgx.ErrNoRows) {
		panic(err)
	}
}

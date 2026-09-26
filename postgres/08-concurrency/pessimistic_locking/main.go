// ============================================================================
// 08-concurrency/pessimistic_locking — FOR UPDATE workers + a real deadlock
// ============================================================================
// Run:
//   make up
//   go run ./08-concurrency/pessimistic_locking
//
// Pessimistic locking: take the lock BEFORE computing. Nobody retries, nobody
// races — workers QUEUE. Best under heavy contention or when holding locks
// briefly and doing follow-up reads in the same transaction.
//
// This program:
//   1. Runs a SKIP LOCKED job queue with 5 workers (the shipping pattern).
//   2. Reproduces the AB-BA deadlock from 06-transactions/deadlocks.sql —
//      deterministically — and catches 40P01 like production code must.
//   3. Runs the SAME transfer with consistent lock ORDER: zero deadlocks.
// ============================================================================
package main

import (
	"context"
	"errors"
	"fmt"
	"sync"
	"sync/atomic"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"

	"learndb/postgres/internal/db"
)

func main() {
	ctx := context.Background()
	pool := db.MustConnect(ctx)
	defer pool.Close()

	mustExec(ctx, pool, `DROP SCHEMA IF EXISTS m08_pess CASCADE; CREATE SCHEMA m08_pess;`)
	jobQueueDemo(ctx, pool)
	deadlockDemo(ctx, pool)
	orderedDemo(ctx, pool)
}

// ----------------------------------------------------------------------------
// 1. SKIP LOCKED job queue — N workers drain disjoint jobs, no coordination
// ----------------------------------------------------------------------------
func jobQueueDemo(ctx context.Context, pool *pgxpool.Pool) {
	fmt.Println("1. job queue: 50 jobs, 5 workers, SELECT ... FOR UPDATE SKIP LOCKED")
	mustExec(ctx, pool, `CREATE TABLE m08_pess.jobs (
		id int PRIMARY KEY, payload text, status text NOT NULL DEFAULT 'pending', worker text)`)
	mustExec(ctx, pool, `INSERT INTO m08_pess.jobs SELECT g, 'job-'||g, 'pending', NULL FROM generate_series(1,50) g`)

	var processed atomic.Int64
	var wg sync.WaitGroup
	start := time.Now()
	for w := 0; w < 5; w++ {
		wg.Add(1)
		go func(w int) {
			defer wg.Done()
			c, err := pool.Acquire(ctx)
			must(err)
			defer c.Release()
			for {
				// The whole claim is one statement (see race_conditions):
				// rows locked by other workers are INVISIBLE to us, so every
				// claim either returns a free job or nothing. No waits, no
				// double-processing, no retries.
				var id int
				err := c.QueryRow(ctx, `
					UPDATE m08_pess.jobs SET status = 'done', worker = $1
					WHERE id = (SELECT id FROM m08_pess.jobs
					            WHERE status = 'pending'
					            ORDER BY id
					            FOR UPDATE SKIP LOCKED
					            LIMIT 1)
					RETURNING id`, fmt.Sprintf("w%d", w)).Scan(&id)
				if errors.Is(err, pgx.ErrNoRows) {
					return // queue empty
				}
				must(err)
				processed.Add(1)
				time.Sleep(2 * time.Millisecond) // simulate work
			}
		}(w)
	}
	wg.Wait()

	var nullWorkers int
	must(pool.QueryRow(ctx, `SELECT count(*) FROM m08_pess.jobs WHERE worker IS NULL`).Scan(&nullWorkers))
	fmt.Printf("   %d jobs done in %dms, %d unclaimed. Each job processed exactly once.\n",
		processed.Load(), time.Since(start).Milliseconds(), nullWorkers)
}

// ----------------------------------------------------------------------------
// 2. The AB-BA deadlock — deterministic, caught as 40P01
// ----------------------------------------------------------------------------
func deadlockDemo(ctx context.Context, pool *pgxpool.Pool) {
	fmt.Println("2. deadlock: two transfers in OPPOSITE lock orders")

	// A: 1 -> 2 then 2 -> 1... transfer(a,b) locks a then b.
	// transfer(b,a) locks b then a. Interleave -> cycle -> 40P01 for one.
	mustExec(ctx, pool, `CREATE TABLE m08_pess.accounts (id int PRIMARY KEY, balance int NOT NULL)`)
	mustExec(ctx, pool, `INSERT INTO m08_pess.accounts VALUES (1, 100), (2, 100)`)

	// gate forces the deterministic interleave (see lost_updates for the
	// handshake's send/receive ordering rules):
	type gate struct{ a, b chan struct{} }
	g := gate{a: make(chan struct{}), b: make(chan struct{})}
	sync1 := func(isA bool) {
		if isA {
			g.a <- struct{}{}
			<-g.b
		} else {
			<-g.a
			g.b <- struct{}{}
		}
	}

	deadlocked := make(chan error, 1)
	var wg sync.WaitGroup

	transfer := func(c *pgxpool.Conn, from, to, amount int, isA bool) (err error) {
		tx, err := c.Begin(ctx)
		if err != nil {
			return err
		}
		defer tx.Rollback(ctx)
		lock := func(id int) error {
			_, err := tx.Exec(ctx, `SELECT 1 FROM m08_pess.accounts WHERE id = $1 FOR UPDATE`, id)
			return err // the deadlock victim errors HERE; propagate, don't panic
		}
		if err = lock(from); err != nil {
			return err
		}
		sync1(isA) // <- both workers hold their FIRST row here; each wants the other's
		if err = lock(to); err != nil {
			return err
		}
		if _, err = tx.Exec(ctx, `
			UPDATE m08_pess.accounts SET balance = balance - $1 WHERE id = $2`, amount, from); err != nil {
			return err
		}
		if _, err = tx.Exec(ctx, `
			UPDATE m08_pess.accounts SET balance = balance + $1 WHERE id = $2`, amount, to); err != nil {
			return err
		}
		return tx.Commit(ctx)
	}

	wg.Add(1)
	go func() { // worker A: transfer 1 -> 2
		defer wg.Done()
		c, err := pool.Acquire(ctx)
		must(err)
		defer c.Release()
		deadlocked <- transfer(c, 1, 2, 10, true)
	}()
	wg.Add(1)
	go func() { // worker B: transfer 2 -> 1 (opposite order!)
		defer wg.Done()
		c, err := pool.Acquire(ctx)
		must(err)
		defer c.Release()
		err = transfer(c, 2, 1, 10, false)
		if err != nil {
			reportDeadlock("worker B (or A)", err)
		}
	}()
	wg.Wait()
	close(deadlocked)
	if err := <-deadlocked; err != nil {
		reportDeadlock("worker A", err)
	}

	var sum int
	must(pool.QueryRow(ctx, `SELECT sum(balance) FROM m08_pess.accounts`).Scan(&sum))
	fmt.Printf("   invariants intact: sum(balances)=%d (no partial transfer; victim fully rolled back)\n", sum)
}

func reportDeadlock(who string, err error) {
	var pgErr *pgconn.PgError
	if errors.As(err, &pgErr) && pgErr.Code == "40P01" {
		fmt.Printf("   %s aborted: SQLSTATE 40P01 deadlock detected (retryable in prod)\n", who)
	} else {
		fmt.Printf("   %s failed unexpectedly: %v\n", who, err)
	}
}

// ----------------------------------------------------------------------------
// 3. Same transfer, CONSISTENT ORDER: always lock min(id) first
// ----------------------------------------------------------------------------
func orderedDemo(ctx context.Context, pool *pgxpool.Pool) {
	fmt.Println("3. fix: always lock rows in ascending id order")

	orderedTransfer := func(c *pgxpool.Conn, from, to, amount int) error {
		tx, err := c.Begin(ctx)
		if err != nil {
			return err
		}
		defer tx.Rollback(ctx)
		lo, hi := from, to
		if lo > hi {
			lo, hi = hi, lo
		}
		// ONE statement locks both rows IN ORDER — cycles are impossible
		// because every transaction queues on the same global order:
		_, err = tx.Exec(ctx, `
			SELECT 1 FROM m08_pess.accounts WHERE id IN ($1, $2) ORDER BY id FOR UPDATE`, lo, hi)
		if err != nil {
			return err
		}
		_, err = tx.Exec(ctx, `UPDATE m08_pess.accounts SET balance = balance - $1 WHERE id = $2`, amount, from)
		if err != nil {
			return err
		}
		_, err = tx.Exec(ctx, `UPDATE m08_pess.accounts SET balance = balance + $1 WHERE id = $2`, amount, to)
		if err != nil {
			return err
		}
		return tx.Commit(ctx)
	}

	var deadlocks atomic.Int64
	var wg sync.WaitGroup
	for i := 0; i < 50; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			c, err := pool.Acquire(ctx)
			must(err)
			defer c.Release()
			from, to := 1, 2
			if i%2 == 1 {
				from, to = 2, 1 // opposite directions, racing
			}
			err = orderedTransfer(c, from, to, 1)
			if err != nil {
				var pgErr *pgconn.PgError
				if errors.As(err, &pgErr) && pgErr.Code == "40P01" {
					deadlocks.Add(1)
				} else {
					must(err)
				}
			}
		}(i)
	}
	wg.Wait()

	var sum int
	must(pool.QueryRow(ctx, `SELECT sum(balance) FROM m08_pess.accounts`).Scan(&sum))
	fmt.Printf("   50 racing transfers, %d deadlocks, sum(balances)=%d (200 = all applied)\n",
		deadlocks.Load(), sum)
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

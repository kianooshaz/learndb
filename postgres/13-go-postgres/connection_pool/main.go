// ============================================================================
// 13-go-postgres/connection_pool — pgxpool configuration and observability
// ============================================================================
// Run:
//   make up
//   go run ./13-go-postgres/connection_pool
//
// Connection-per-process vs connection-per-request: PostgreSQL backends are
// real PROCESSES (~1-10MB each); max_connections is a hard wall (default
// 100). The pool's job: many goroutines share few connections.
//
// Sizing (the classic formula):
//   pool_size ≈ cores * 2 (+ effective_spindles) — I/O-bound can go higher,
//   but > 2-4x cores often just adds lock contention. Your TOTAL across all
//   pods must stay under the server's max_connections (minus admin margin).
// ============================================================================
package main

import (
	"context"
	"fmt"
	"sync"
	"sync/atomic"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"

	"learndb/postgres/internal/dsn"
)

func main() {
	ctx := context.Background()

	// -----------------------------------------------------------------------
	// 1. Explicit configuration (vs pgxpool.New's defaults)
	// -----------------------------------------------------------------------
	cfg, err := pgxpool.ParseConfig(dsn.DSN())
	must(err)
	// The knobs that matter, with sane values and why:
	cfg.MaxConns = 8                     // ceiling (default = max(4, cpus)) — keep modest
	cfg.MinConns = 2                    // warm connections: no fork-on-burst
	cfg.MaxConnLifetime = time.Hour     // recycle: kills slow leaks, DNS changes
	cfg.MaxConnLifetimeJitter = time.Minute // stagger recycles — avoid thundering re-fork
	cfg.MaxConnIdleTime = 5 * time.Minute   // release idle capacity
	cfg.HealthCheckPeriod = time.Minute     // background ping: evicts dead conns

	// Per-CONNECTION (session) settings belong on the conn config, not SETs:
	cfg.ConnConfig.RuntimeParams["application_name"] = "lab-pool-demo"
	cfg.ConnConfig.RuntimeParams["statement_timeout"] = "10s" // server-side safety net
	cfg.ConnConfig.RuntimeParams["timezone"] = "UTC"

	pool, err := pgxpool.NewWithConfig(ctx, cfg)
	must(err)
	defer pool.Close()
	fmt.Printf("pool: MinConns=%d MaxConns=%d\n", cfg.MinConns, cfg.MaxConns)

	// -----------------------------------------------------------------------
	// 2. Stat() — what your pool is doing right now (export these metrics!)
	// -----------------------------------------------------------------------
	s := pool.Stat()
	fmt.Printf("stat: total=%d idle=%d acquired=%d max=%d\n",
		s.TotalConns(), s.IdleConns(), s.AcquiredConns(), s.MaxConns())

	// -----------------------------------------------------------------------
	// 3. Contention: 50 concurrent Acquires against MaxConns=8
	// -----------------------------------------------------------------------
	var waited atomic.Int64
	var wg sync.WaitGroup
	start := time.Now()
	for i := 0; i < 50; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			acqStart := time.Now()
			c, err := pool.Acquire(ctx) // waits if all conns are busy
			must(err)
			if wait := time.Since(acqStart); wait > 10*time.Millisecond {
				waited.Add(1) // meaningfully queued behind other goroutines
			}
			time.Sleep(50 * time.Millisecond) // simulate a query
			c.Release()
		}()
	}
	wg.Wait()
	fmt.Printf("50 goroutines through an 8-conn pool: %dms total, %d had to wait\n",
		time.Since(start).Milliseconds(), waited.Load())
	fmt.Println("stat after:", pool.Stat().AcquiredConns(), "acquired (all released)")

	// -----------------------------------------------------------------------
	// 4. Acquire timeout: pool waits are ctx-cancellable — bound them!
	// -----------------------------------------------------------------------
	// Fill the pool:
	var conns = make([]*pgxpool.Conn, 0)
	for i := 0; i < int(cfg.MaxConns); i++ {
		c, err := pool.Acquire(ctx)
		must(err)
		conns = append(conns, c)
	}
	// A 9th acquire with a 200ms budget fails fast instead of hanging:
	{
		tctx, cancel := context.WithTimeout(ctx, 200*time.Millisecond)
		defer cancel()
		_, err := pool.Acquire(tctx)
		fmt.Println("pool exhaustion with ctx deadline:", err != nil, "(context.DeadlineExceeded — return 503, don't retry-storm)")
	}
	for _, c := range conns {
		c.Release()
	}

	// -----------------------------------------------------------------------
	// 5. The anti-patterns that page you at 3am
	// -----------------------------------------------------------------------
	//  * Opening a pool per request/handler: fork storm + max_connections.
	//  * Holding an Acquired conn across a slow external call (HTTP to a 3rd
	//    party!): the pool starves while you hold a conn doing NOTHING.
	//  * Release() forgotten on an error path: leaks conns until MaxConns
	//    then the service wedges. (Use defer c.Release() immediately.)
	//  * One shared pool per pod x 50 pods x MaxConns=20 = 1000 conns into a
	//    server with max_connections=100: coordinate the math fleet-wide.
}

func must(err error) {
	if err != nil {
		panic(err)
	}
}

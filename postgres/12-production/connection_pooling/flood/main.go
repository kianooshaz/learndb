// ============================================================================
// 12-production/connection_pooling/flood — 100 clients through PgBouncer
// ============================================================================
// Run:
//   make pgbouncer
//   go run ./12-production/connection_pooling/flood
//
// Opens 100 concurrent client connections through PgBouncer (port 6432)
// with a pgxpool sized at MaxConns=100 to force them all live, runs a
// trivial query on each, and reports: total wall time + what PgBouncer's
// pools view saw. Compare with the same flood DIRECT (flag -direct): same
// clients, 100 real PostgreSQL backends.
// ============================================================================
package main

import (
	"context"
	"flag"
	"fmt"
	"sync"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"

	"learndb/postgres/internal/dsn"
)

func main() {
	direct := flag.Bool("direct", false, "bypass PgBouncer (port 5432)")
	clients := flag.Int("clients", 100, "concurrent client connections")
	flag.Parse()

	target := "postgres://postgres:postgres@localhost:6432/learndb"
	if *direct {
		target = dsn.DSN() // 5432 straight to PostgreSQL
	}
	fmt.Printf("flooding %s with %d concurrent clients...\n", target, *clients)

	cfg, err := pgxpool.ParseConfig(target)
	must(err)
	cfg.MaxConns = int32(*clients) // let every client hold a connection
	pool, err := pgxpool.NewWithConfig(context.Background(), cfg)
	must(err)
	defer pool.Close()

	start := time.Now()
	var wg sync.WaitGroup
	errs := make(chan error, *clients)
	for i := 0; i < *clients; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
			defer cancel()
			var one int
			if err := pool.QueryRow(ctx, `SELECT 1`).Scan(&one); err != nil {
				errs <- err
			}
		}()
	}
	wg.Wait()
	close(errs)

	nerr := 0
	for err := range errs {
		nerr++
		if nerr == 1 {
			fmt.Println("first error:", err)
		}
	}
	fmt.Printf("done: %d clients in %dms, %d errors\n",
		*clients, time.Since(start).Milliseconds(), nerr)

	if !*direct {
		fmt.Println("\nnow check the pool view (see README):")
		fmt.Println(`  PGPASSWORD=postgres psql -p 6432 -U postgres -d pgbouncer -c "SHOW POOLS"`)
		fmt.Println("cl_active peaked near 100 while sv_active stayed ~20: the whole point.")
	}
}

func must(err error) {
	if err != nil {
		panic(err)
	}
}

// ============================================================================
// 12-production/migrations/migrator — a 100-line migration runner
// ============================================================================
// Run:
//   make up
//   go run ./12-production/migrations/migrator -dir 12-production/migrations/example
//
// What a real tool (golang-migrate, goose, atlas, dbmate) does, minus the
// features — so you know what your tool is doing FOR you:
//   1. version tracking in a schema_migrations table
//   2. advisory lock so two deploys can't migrate simultaneously
//   3. each migration in ONE transaction (DDL is transactional! — except
//      the CONCURRENTLY family, which tools run outside a tx)
//   4. checksum verification (a modified applied migration is an incident)
// ============================================================================
package main

import (
	"context"
	"crypto/sha256"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"sort"

	"learndb/postgres/internal/db"
)

const lockKey = 90210 // namespace for this runner's advisory lock

func main() {
	dir := flag.String("dir", "12-production/migrations/example", "migrations directory")
	flag.Parse()

	ctx := context.Background()
	pool := db.MustConnect(ctx)
	defer pool.Close()

	// One dedicated connection for the whole run: the advisory lock and the
	// version bookkeeping must live on ONE session:
	conn, err := pool.Acquire(ctx)
	must(err)
	defer conn.Release()

	// 1) serialize runners (session-scoped: dies with the connection —
	//    a crashed deploy can't leave it stuck forever):
	var gotLock bool
	must(conn.QueryRow(ctx, `SELECT pg_try_advisory_lock($1)`, lockKey).Scan(&gotLock))
	if !gotLock {
		fmt.Println("another migrator holds the lock — exiting")
		os.Exit(0)
	}

	// 2) version table (in its own tx so a crash below can't lose it):
	tx, err := conn.Begin(ctx)
	must(err)
	_, err = tx.Exec(ctx, `CREATE SCHEMA IF NOT EXISTS migrate`)
	must(err)
	_, err = tx.Exec(ctx, `CREATE TABLE IF NOT EXISTS migrate.schema_migrations (
		version bigint PRIMARY KEY,
		checksum text NOT NULL,
		applied_at timestamptz NOT NULL DEFAULT now())`)
	must(err)
	must(tx.Commit(ctx))

	// 3) discover + order migrations by leading number:
	files, err := filepath.Glob(filepath.Join(*dir, "*.sql"))
	must(err)
	sort.Strings(files)

	for _, f := range files {
		version := int64(0)
		_, err := fmt.Sscanf(filepath.Base(f), "%d_", &version)
		must(err)

		var applied bool
		must(conn.QueryRow(ctx,
			`SELECT EXISTS (SELECT 1 FROM migrate.schema_migrations WHERE version = $1)`,
			version).Scan(&applied))
		if applied { // 4) checksum guard:
			var want string
			must(conn.QueryRow(ctx,
				`SELECT checksum FROM migrate.schema_migrations WHERE version=$1`, version).Scan(&want))
			if want != checksum(f) {
				fmt.Printf("FATAL: %s was modified after being applied\n", f)
				os.Exit(1)
			}
			continue
		}

		sqlBytes, err := os.ReadFile(f)
		must(err)
		fmt.Printf("applying %s ... ", filepath.Base(f))

		tx, err := conn.Begin(ctx)
		must(err)
		_, err = tx.Exec(ctx, string(sqlBytes))
		if err != nil {
			_ = tx.Rollback(ctx) // DDL rolls back cleanly (01-basics!)
			fmt.Printf("FAILED, rolled back: %v\n", err)
			os.Exit(1)
		}
		_, err = tx.Exec(ctx,
			`INSERT INTO migrate.schema_migrations (version, checksum) VALUES ($1, $2)`,
			version, checksum(f))
		must(err)
		must(tx.Commit(ctx))
		fmt.Println("ok")
	}

	var n int
	must(conn.QueryRow(ctx, `SELECT count(*) FROM migrate.schema_migrations`).Scan(&n))
	fmt.Printf("done: %d migration(s) at latest state\n", n)
}

func checksum(path string) string {
	b, err := os.ReadFile(path)
	must(err)
	return fmt.Sprintf("%x", sha256.Sum256(b))
}

func must(err error) {
	if err != nil {
		panic(err)
	}
}

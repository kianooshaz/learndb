// ============================================================================
// 13-go-postgres/prepared_queries — pgx's statement cache and plan caching
// ============================================================================
// Run:
//   make up
//   go run ./13-go-postgres/prepared_queries
//
// pgx automatically PREPARES statements you run repeatedly (default cache:
// 512 per connection, keyed by the exact SQL string). Consequences:
//   * fewer round trips (parse once, bind/execute per call)
//   * server-side generic plans after 5 executions (see the skew trap!)
//   * PgBouncer in transaction mode historically broke named prepared
//     statements — modern PgBouncer (1.21+) can track them; still the #1
//     "prepared statement does not exist" cause in the wild.
//
// The skew trap (SQL-side demo: 07-performance/prepared_statements.sql):
//   a custom plan indexes the rare value; after 5 runs the planner may
//   switch to a GENERIC plan and pick a seq scan for your skewed rare value.
//   plan_cache_mode=auto|force_generic_plan|force_custom_plan is the knob.
// ============================================================================
package main

import (
	"context"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"

	"learndb/postgres/internal/db"
)

func main() {
	ctx := context.Background()
	pool := db.MustConnect(ctx)
	defer pool.Close()

	mustExec(pool, `DROP SCHEMA IF EXISTS m13_prep CASCADE; CREATE SCHEMA m13_prep;`)
	mustExec(pool, `CREATE TABLE m13_prep.events (id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY, kind text NOT NULL)`)
	// skew: 'rare' is 1% of rows:
	mustExec(pool, `INSERT INTO m13_prep.events (kind)
		SELECT CASE WHEN g % 100 = 0 THEN 'rare' ELSE 'common' END
		FROM generate_series(1, 200000) g`)
	mustExec(pool, `CREATE INDEX m13_prep_events_kind_idx ON m13_prep.events (kind)`)
	mustExec(pool, `ANALYZE m13_prep.events`)

	// -----------------------------------------------------------------------
	// 1. The automatic statement cache (on a dedicated conn)
	// -----------------------------------------------------------------------
	conn, err := pool.Acquire(ctx)
	must(err)
	defer conn.Release()

	// Named, MANUAL prepare — when you want control (or need the described
	// row format). NOTE: Prepare lives on the raw *pgx.Conn (conn.Conn()),
	// not on the pool wrapper:
	desc, err := conn.Conn().Prepare(ctx, "fetch_rare", `SELECT id FROM m13_prep.events WHERE kind = $1`)
	must(err)
	_ = desc // StatementDescription: name, parameter OIDs, result fields

	// Time the SAME statement 6 times and watch the plan flip at #5:
	for i := 1; i <= 6; i++ {
		start := time.Now()
		rows, err := conn.Query(ctx, "fetch_rare", "rare")
		must(err)
		n := 0
		for rows.Next() {
			n++
		}
		rows.Close()
		fmt.Printf("run %d: %d rows in %6.2fms\n", i, n, float64(time.Since(start).Microseconds())/1000)
	}
	// Runs 1-4: custom plan -> index scan (fast). Run 5+ may switch to a
	// GENERIC plan for ALL parameter values; for the rare value that can be
	// a seq scan (slow). The classic signature: "the 5th call got slower".

	// -----------------------------------------------------------------------
	// 2. Inspect what the server holds
	// -----------------------------------------------------------------------
	var n int
	must(pool.QueryRow(ctx, `SELECT count(*) FROM pg_prepared_statements`).Scan(&n))
	fmt.Println("server-side prepared statements on this conn:", n)

	// -----------------------------------------------------------------------
	// 3. Control knobs
	// -----------------------------------------------------------------------
	// Per-statement escape hatch: keep a skewed query OUT of the cache with
	// the simple protocol (parameters interpolated by pgx, no PREPARE):
	//   cfg.ConnConfig.DefaultQueryExecMode = QueryExecModeSimpleProtocol
	// Or globally server-side: plan_cache_mode = force_custom_plan
	// (see 07-performance/prepared_statements.sql for the pure-SQL demo).
	fmt.Println("\nsee 07-performance/prepared_statements.sql for the plan-flip SQL demo")
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

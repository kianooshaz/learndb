// ============================================================================
// 13-go-postgres/batch_queries — pgx.Batch: pipeline many statements
// ============================================================================
// Run:
//   make up
//   go run ./13-go-postgres/batch_queries
//
// A Batch pipelines N statements over ONE round trip (extended protocol
// pipeline mode): the server executes them in order without waiting for the
// client between statements. This is the fix for chatty loops — "INSERT in a
// for-loop" is often 100x slower than a batch for no semantic reason.
//
// Compared:
//   N x Exec        — N round trips (each pays network latency)
//   Batch           — 1 round trip, N statements, ANY statements
//   multi-VALUES    — 1 statement, 1 plan (single INSERT ... VALUES (...),(...))
//   CopyFrom        — bulk loading king (copy/ next)
// ============================================================================
package main

import (
	"context"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"learndb/postgres/internal/db"
)

const rowsN = 2000

func main() {
	ctx := context.Background()
	pool := db.MustConnect(ctx)
	defer pool.Close()

	mustExec(pool, `DROP SCHEMA IF EXISTS m13_batch CASCADE; CREATE SCHEMA m13_batch;`)
	mustExec(pool, `CREATE TABLE m13_batch.metrics (
		id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
		src text NOT NULL, val numeric NOT NULL, at timestamptz NOT NULL DEFAULT now())`)

	// -----------------------------------------------------------------------
	// 1. The chatty loop (the anti-pattern, measured)
	// -----------------------------------------------------------------------
	start := time.Now()
	for i := 0; i < rowsN; i++ {
		_, err := pool.Exec(ctx,
			`INSERT INTO m13_batch.metrics (src, val) VALUES ($1, $2)`,
			"loop", float64(i))
		must(err)
	}
	loopDur := time.Since(start)
	fmt.Printf("loop  : %4d INSERTs, one round trip each: %8.1fms\n", rowsN, float64(loopDur.Microseconds())/1000)

	// -----------------------------------------------------------------------
	// 2. Batch — same statements, pipelined
	// -----------------------------------------------------------------------
	mustExec(pool, `TRUNCATE m13_batch.metrics`)
	start = time.Now()
	b := &pgx.Batch{}
	for i := 0; i < rowsN; i++ {
		b.Queue(`INSERT INTO m13_batch.metrics (src, val) VALUES ($1, $2)`,
			"batch", float64(i))
	}
	br := pool.SendBatch(ctx, b)
	for i := 0; i < rowsN; i++ {
		_, err := br.Exec() // MUST consume every result
		must(err)
	}
	must(br.Close())
	batchDur := time.Since(start)
	fmt.Printf("batch : %4d INSERTs, ONE round trip       : %8.1fms  (%.0fx faster)\n",
		rowsN, float64(batchDur.Microseconds())/1000, float64(loopDur)/float64(batchDur))

	// -----------------------------------------------------------------------
	// 3. Multi-VALUES single statement — when the rows are homogeneous
	// -----------------------------------------------------------------------
	mustExec(pool, `TRUNCATE m13_batch.metrics`)
	start = time.Now()
	const chunk = 500 // parameter-count sanity: 65535 is the protocol max
	inserted := 0
	for inserted < rowsN {
		sql := `INSERT INTO m13_batch.metrics (src, val) VALUES `
		args := make([]any, 0, chunk*2)
		n := min(chunk, rowsN-inserted)
		for j := 0; j < n; j++ {
			if j > 0 {
				sql += ","
			}
			sql += fmt.Sprintf("($%d, $%d)", j*2+1, j*2+2)
			args = append(args, "multival", float64(inserted+j))
		}
		_, err := pool.Exec(ctx, sql, args...)
		must(err)
		inserted += n
	}
	mvDur := time.Since(start)
	fmt.Printf("values: %4d INSERTs, %d statements       : %8.1fms\n",
		rowsN, (rowsN+chunk-1)/chunk, float64(mvDur.Microseconds())/1000)

	// -----------------------------------------------------------------------
	// 4. Batch is not just INSERTs — heterogeneous pipelines
	// -----------------------------------------------------------------------
	b2 := &pgx.Batch{}
	b2.Queue(`INSERT INTO m13_batch.metrics (src, val) VALUES ($1, $2)`, "mixed", 1)
	b2.Queue(`UPDATE m13_batch.metrics SET val = val * 10 WHERE src = $1`, "mixed")
	b2.Queue(`SELECT count(*) FROM m13_batch.metrics`)
	br2 := pool.SendBatch(ctx, b2)
	_, err := br2.Exec() // INSERT result
	must(err)
	_, err = br2.Exec() // UPDATE result
	must(err)
	var n int64
	must(br2.QueryRow().Scan(&n)) // SELECT result — QueryRow on a batch result
	must(br2.Close())
	fmt.Println("mixed batch (insert+update+select) final count:", n)

	// Error semantics: a failure mid-batch aborts the REMAINING queued
	// statements but ones already executed stay executed — wrap in a
	// transaction if you need all-or-nothing (batch + tx = the full pattern).

	var _ = pgx.Batch{}
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

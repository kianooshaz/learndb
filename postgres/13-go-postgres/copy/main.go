// ============================================================================
// 13-go-postgres/copy — COPY: bulk loading at wire speed
// ============================================================================
// Run:
//   make up
//   go run ./13-go-postgres/copy
//
// COPY is PostgreSQL's bulk path: a dedicated protocol message that streams
// rows in a compact binary/text format. It skips most per-row overhead
// (no per-row round trips, no per-row WAL record decisions beyond needed,
// no statement machinery). For 10k+ row loads it's typically 5-50x faster
// than INSERTs, and pgx's CopyFrom wraps it in an interface you already
// understand: an iterator over []any column values.
//
// When NOT to COPY: tiny batches (setup cost dominates), when you need
// per-row ON CONFLICT handling (COPY has none), or when target columns have
// volatile defaults you must read back.
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

const rowsN = 100_000

type sampleRow struct{ id, val int }

// sampleSource implements pgx.CopyFromSource — the streaming interface.
// (For in-memory data, pgx.CopyFromRows is a ready-made wrapper.)
type sampleSource struct {
	rows  []sampleRow
	i     int
	err   error
}

func (s *sampleSource) Next() bool {
	s.i++
	return s.i <= len(s.rows)
}
func (s *sampleSource) Values() ([]any, error) {
	r := s.rows[s.i-1]
	return []any{r.id, r.val}, nil
}
func (s *sampleSource) Err() error { return s.err }

func main() {
	ctx := context.Background()
	pool := db.MustConnect(ctx)
	defer pool.Close()

	mustExec(pool, `DROP SCHEMA IF EXISTS m13_copy CASCADE; CREATE SCHEMA m13_copy;`)
	mustExec(pool, `CREATE TABLE m13_copy.readings (sensor int NOT NULL, val int NOT NULL)`)

	rows := make([]sampleRow, rowsN)
	for i := range rows {
		rows[i] = sampleRow{i % 100, i}
	}

	// -----------------------------------------------------------------------
	// 1. Insert loop baseline (chatty — see batch_queries for the middle rung)
	// -----------------------------------------------------------------------
	start := time.Now()
	for i := 0; i < 5000; i++ { // only 5k — a full loop of 100k would be cruel
		_, err := pool.Exec(ctx, `INSERT INTO m13_copy.readings VALUES ($1, $2)`,
			rows[i].id, rows[i].val)
		must(err)
	}
	loopDur := time.Since(start)
	fmt.Printf("insert loop : %5d rows              : %8.1fms\n",
		5000, float64(loopDur.Microseconds())/1000)

	// -----------------------------------------------------------------------
	// 2. CopyFrom — all 100k rows in one COPY
	// -----------------------------------------------------------------------
	mustExec(pool, `TRUNCATE m13_copy.readings`)
	start = time.Now()
	n, err := pool.CopyFrom(
		ctx,
		pgx.Identifier{"m13_copy", "readings"}, // table
		[]string{"sensor", "val"},              // target columns
		&sampleSource{rows: rows},
	)
	must(err)
	copyDur := time.Since(start)
	fmt.Printf("CopyFrom    : %5d rows              : %8.1fms  (that's the difference)\n",
		n, float64(copyDur.Microseconds())/1000)

	// -----------------------------------------------------------------------
	// 3. Column list matters: identity/default/generated columns must be OMITTED
	// -----------------------------------------------------------------------
	mustExec(pool, `CREATE TABLE m13_copy.events (
		id     bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
		kind   text NOT NULL,
		at     timestamptz NOT NULL DEFAULT now())`)
	n2, err := pool.CopyFrom(ctx,
		pgx.Identifier{"m13_copy", "events"},
		[]string{"kind"}, // only real columns — id and at are server-generated
		pgx.CopyFromSlice(3, func(i int) ([]any, error) {
			return []any{fmt.Sprintf("k%d", i)}, nil
		}),
	)
	must(err)
	fmt.Println("CopyFrom with defaults/generated skipped:", n2, "rows")

	// -----------------------------------------------------------------------
	// 4. COPY error handling — the connection is POISONED after a failure
	// -----------------------------------------------------------------------
	c, err := pool.Acquire(ctx)
	must(err)
	bad := &sampleSource{rows: []sampleRow{{1, 1}, {2, 0}}} // schema: val NOT NULL ok;
	// simulate failure with a type mismatch instead:
	_, err = c.Conn().CopyFrom(ctx, pgx.Identifier{"m13_copy", "readings"},
		[]string{"sensor", "val"}, &failingSource{})
	fmt.Println("COPY failed mid-stream:", err != nil)
	// After a failed COPY the connection's protocol state is undefined:
	// the safe move is to DISCARD the connection, not Release it back:
	c.Hijack() // takes ownership so the pool won't reuse it
	_ = bad
	_ = c.Conn().Close(ctx)

	// -----------------------------------------------------------------------
	// 5. Bulk-load hygiene (the difference between COPY feeling amazing or
	//    wrecking your table):
	//    * DROP indexes, COPY, recreate -> often faster for >million rows
	//    * ANALYZE after (stats lag behind bulk loads — planner_statistics!)
	//    * COPY into a fresh table then swap, for ETL-style loads
	// =====================================================================
	fmt.Println("\nnext: context_cancellation — killing queries politely")
}

type failingSource struct{ sent bool }

func (f *failingSource) Next() bool { return !f.sent }
func (f *failingSource) Values() ([]any, error) {
	f.sent = true
	return []any{"not-an-int", "also-not"}, nil // type error mid-stream
}
func (f *failingSource) Err() error { return nil }

func mustExec(pool *pgxpool.Pool, sql string) {
	_, err := pool.Exec(context.Background(), sql)
	must(err)
}

func must(err error) {
	if err != nil {
		panic(err)
	}
}

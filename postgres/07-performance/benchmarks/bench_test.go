// ============================================================================
// 07-performance/benchmarks — query-shape comparisons at realistic scale
// ============================================================================
// Run:
//   make up
//   go test ./07-performance/benchmarks -bench . -benchtime 1s
//
// Complements 13-go-postgres/benchmarks (driver mechanics) with QUERY-SHAPE
// comparisons every backend engineer should have seen once:
//   BenchmarkPaginationOffset   — OFFSET pagination: O(offset)
//   BenchmarkPaginationKeyset   — keyset (WHERE id > cursor): O(page)
//   BenchmarkPointLookupIndexed — btree point lookup
//   BenchmarkRangeScanBrin      — BRIN on a correlated time column
//   BenchmarkCountAsterisk      — count(*) on 500k rows (no free counters)
// ============================================================================
package benchmarks

import (
	"context"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"learndb/postgres/internal/db"
)

const rowsN = 500_000

var pool *pgxpool.Pool

// lab lazily builds the schema + data ONCE per test binary run.
// (id ascending, at ascending with id: perfect BRIN correlation.)
func lab(t testing.TB) *pgxpool.Pool {
	if pool != nil {
		return pool
	}
	p, err := db.Connect(context.Background())
	if err != nil {
		t.Skipf("database not reachable: %v", err)
	}
	pool = p
	ctx := context.Background()

	if _, err := p.Exec(ctx, `DROP SCHEMA IF EXISTS m07_bench CASCADE; CREATE SCHEMA m07_bench;`); err != nil {
		t.Fatal(err)
	}
	if _, err := p.Exec(ctx, `CREATE TABLE m07_bench.events (
		id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
		v  text NOT NULL,
		at timestamptz NOT NULL)`); err != nil {
		t.Fatal(err)
	}

	// CopyFrom in chunks (see 13-go-postgres/copy for why chunks):
	base := time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)
	const chunk = 50_000
	for offset := 0; offset < rowsN; offset += chunk {
		n := chunk
		if offset+n > rowsN {
			n = rowsN - offset
		}
		batch := make([][]any, n)
		for j := 0; j < n; j++ {
			batch[j] = []any{"x", base.Add(time.Duration(offset+j) * time.Second)}
		}
		if _, err := p.CopyFrom(ctx, pgx.Identifier{"m07_bench", "events"},
			[]string{"v", "at"}, pgx.CopyFromRows(batch)); err != nil {
			t.Fatal(err)
		}
	}
	for _, s := range []string{
		`CREATE INDEX m07_bench_events_at_brin ON m07_bench.events USING brin (at)`,
		`ANALYZE m07_bench.events`,
	} {
		if _, err := p.Exec(ctx, s); err != nil {
			t.Fatal(err)
		}
	}
	return p
}

func BenchmarkPaginationOffset(b *testing.B) {
	p := lab(b)
	ctx := context.Background()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		// page ~400 of 25-row pages: the server produces and throws away
		// 10,000 rows EVERY call — O(offset):
		var n int
		if err := p.QueryRow(ctx, `
			SELECT count(*) FROM (
				SELECT id FROM m07_bench.events ORDER BY id
				LIMIT 25 OFFSET 10000
			) page`).Scan(&n); err != nil {
			b.Fatal(err)
		}
	}
}

func BenchmarkPaginationKeyset(b *testing.B) {
	p := lab(b)
	ctx := context.Background()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		// Same logical page via cursor: the pkey index jumps STRAIGHT to
		// row 10001 — O(page):
		var n int
		if err := p.QueryRow(ctx, `
			SELECT count(*) FROM (
				SELECT id FROM m07_bench.events WHERE id > 10000
				ORDER BY id LIMIT 25
			) page`).Scan(&n); err != nil {
			b.Fatal(err)
		}
	}
}

func BenchmarkPointLookupIndexed(b *testing.B) {
	p := lab(b)
	ctx := context.Background()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		var v string
		if err := p.QueryRow(ctx,
			`SELECT v FROM m07_bench.events WHERE id = $1`, i%rowsN+1).Scan(&v); err != nil {
			b.Fatal(err)
		}
	}
}

func BenchmarkRangeScanBrin(b *testing.B) {
	p := lab(b)
	ctx := context.Background()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		// one 1000-second window = 1000 rows via the tiny BRIN index:
		var n int
		if err := p.QueryRow(ctx, `
			SELECT count(*) FROM m07_bench.events
			WHERE at >= '2026-01-01 00:10:00+00'
			  AND at <  '2026-01-01 00:26:40+00'`).Scan(&n); err != nil {
			b.Fatal(err)
		}
	}
}

func BenchmarkCountAsterisk(b *testing.B) {
	p := lab(b)
	ctx := context.Background()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		// MVCC means every count(*) is a real count over visible versions:
		var n int
		if err := p.QueryRow(ctx, `SELECT count(*) FROM m07_bench.events`).Scan(&n); err != nil {
			b.Fatal(err)
		}
	}
}

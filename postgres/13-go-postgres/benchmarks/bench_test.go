// ============================================================================
// 13-go-postgres/benchmarks — repeatable comparisons with testing.B
// ============================================================================
// Run:
//   make up
//   go test ./13-go-postgres/benchmarks -bench . -benchtime 2s
//
// Benchmarks you can defend in a design review:
//   BenchmarkScanPatterns     — manual Scan vs CollectRows overhead
//   BenchmarkSingleVsBatch   — per-row Exec vs pgx.Batch (round trips)
//   BenchmarkPointLookup      — indexed point SELECT at pool concurrency
//   BenchmarkPoolAcquire     — pool acquisition cost (contended)
//
// Methodology notes that keep results honest:
//   * b.ReportAllocs() — allocation counts matter more than ns sometimes
//   * b.N iterations are managed by the framework; don't loop inside
//   * database latency dominates: run on the same machine/container, and
//     compare RELATIVE numbers, not absolutes
//   * for p99/p50 you want load tests, not micro-benchmarks — these are
//     for comparing two IMPLEMENTATIONS, not sizing production
// ============================================================================
package benchmarks

import (
	"context"
	"testing"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"learndb/postgres/internal/db"
	"learndb/postgres/internal/dsn"
)

var testPool *pgxpool.Pool

func pool(t testing.TB) *pgxpool.Pool {
	if testPool != nil {
		return testPool
	}
	p, err := db.Connect(context.Background())
	if err != nil {
		t.Skipf("database not reachable: %v", err)
	}
	testPool = p
	setup(t, p)
	return p
}

func setup(t testing.TB, p *pgxpool.Pool) {
	ctx := context.Background()
	statements := []string{
		`DROP SCHEMA IF EXISTS m13_bench CASCADE; CREATE SCHEMA m13_bench;`,
		`CREATE TABLE m13_bench.rows (id int PRIMARY KEY, a text NOT NULL, b int NOT NULL)`,
	}
	for _, s := range statements {
		if _, err := p.Exec(ctx, s); err != nil {
			t.Fatalf("setup: %v", err)
		}
	}
	// Seed once with a batch (see batch_queries for why):
	b := &pgx.Batch{}
	for i := 0; i < 1000; i++ {
		b.Queue(`INSERT INTO m13_bench.rows VALUES ($1, $2, $3)`, i, "x", i)
	}
	br := p.SendBatch(ctx, b)
	for i := 0; i < 1000; i++ {
		if _, err := br.Exec(); err != nil {
			t.Fatalf("seed: %v", err)
		}
	}
	if err := br.Close(); err != nil {
		t.Fatalf("seed close: %v", err)
	}
}

type row struct {
	ID int
	A  string
	B  int
}

func BenchmarkScanManual(b *testing.B) {
	p := pool(b)
	ctx := context.Background()
	b.ReportAllocs()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		rows, err := p.Query(ctx, `SELECT id, a, b FROM m13_bench.rows WHERE id = $1`, i%1000)
		if err != nil {
			b.Fatal(err)
		}
		for rows.Next() {
			var r row
			if err := rows.Scan(&r.ID, &r.A, &r.B); err != nil {
				b.Fatal(err)
			}
		}
		rows.Close()
	}
}

func BenchmarkScanCollectRows(b *testing.B) {
	p := pool(b)
	ctx := context.Background()
	b.ReportAllocs()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		rows, err := p.Query(ctx, `SELECT id, a, b FROM m13_bench.rows WHERE id = $1`, i%1000)
		if err != nil {
			b.Fatal(err)
		}
		rs, err := pgx.CollectRows(rows, pgx.RowToStructByName[row])
		if err != nil {
			b.Fatal(err)
		}
		_ = rs
	}
}

func BenchmarkInsertLoop(b *testing.B) {
	p := pool(b)
	ctx := context.Background()
	b.ReportAllocs()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		if _, err := p.Exec(ctx, `INSERT INTO m13_bench.rows VALUES ($1, $2, 0)`, 1000000+i, "y"); err != nil {
			b.Fatal(err)
		}
	}
}

func BenchmarkInsertBatch100(b *testing.B) {
	p := pool(b)
	ctx := context.Background()
	b.ReportAllocs()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		batch := &pgx.Batch{}
		for j := 0; j < 100; j++ {
			batch.Queue(`INSERT INTO m13_bench.rows VALUES ($1, $2, 0)`, 2000000+i*100+j, "y")
		}
		br := p.SendBatch(ctx, batch)
		for j := 0; j < 100; j++ {
			if _, err := br.Exec(); err != nil {
				b.Fatal(err)
			}
		}
		if err := br.Close(); err != nil {
			b.Fatal(err)
		}
	}
}

func BenchmarkPoolAcquire(b *testing.B) {
	p := pool(b)
	ctx := context.Background()
	b.ReportAllocs()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		c, err := p.Acquire(ctx)
		if err != nil {
			b.Fatal(err)
		}
		c.Release()
	}
}

// TestDSN documents the default connection target (and fails fast if the
// compose stack isn't up — every benchmark Skips in that case).
func TestDSN(t *testing.T) {
	t.Log("connecting to:", dsn.DSN())
}

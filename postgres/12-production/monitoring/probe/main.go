// ============================================================================
// 12-production/monitoring/probe — a 100-line observability agent
// ============================================================================
// Run:
//   make up
//   go run ./12-production/monitoring/probe -interval 2s -once
//
// Polls the monitoring pack (monitoring.sql) and prints a compact health
// line each tick — the skeleton of what Prometheus exporters (postgres_
// exporter) do, minus the metrics format. Watch it while running any other
// lab (e.g. 08-concurrency) to see state changes live.
// ============================================================================
package main

import (
	"context"
	"flag"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"

	"learndb/postgres/internal/db"
)

type snapshot struct {
	Active, Idle, IdleInTx          int
	Blocked                         int
	OldestTx                        time.Duration
	CacheHit                        float64
	TopQuery                        string
	TopTotalMs                      float64
	ReplayLagBytes                  int64
	Replicas                        int
}

func main() {
	once := flag.Bool("once", false, "single snapshot then exit")
	interval := flag.Duration("interval", 2*time.Second, "poll interval")
	flag.Parse()

	ctx := context.Background()
	pool := db.MustConnect(ctx)
	defer pool.Close()

	for {
		s, err := snap(ctx, pool)
		if err != nil {
			fmt.Printf("probe error: %v\n", err)
		} else {
			printSnap(s)
		}
		if *once {
			return
		}
		time.Sleep(*interval)
	}
}

func snap(ctx context.Context, pool *pgxpool.Pool) (*snapshot, error) {
	s := &snapshot{}
	err := pool.QueryRow(ctx, `
		SELECT
		  count(*) FILTER (WHERE state = 'active'),
		  count(*) FILTER (WHERE state = 'idle'),
		  count(*) FILTER (WHERE state = 'idle in transaction'),
		  count(*) FILTER (WHERE cardinality(pg_blocking_pids(pid)) > 0),
		  coalesce(extract(epoch FROM max(now() - xact_start)
		    FILTER (WHERE state <> 'idle'))::float8, 0)
		FROM pg_stat_activity
		WHERE datname = current_database()`).
		Scan(&s.Active, &s.Idle, &s.IdleInTx, &s.Blocked, (*durationSec)(&s.OldestTx))
	if err != nil {
		return nil, err
	}

	// cache hit ratio (guarded: fresh databases divide by zero)
	_ = pool.QueryRow(ctx, `
		SELECT round(100.0 * sum(blks_hit) / nullif(sum(blks_hit) + sum(blks_read), 0), 1)
		FROM pg_stat_database WHERE datname = current_database()`).
		Scan(&s.CacheHit)

	// top statement by total time (best effort — extension may be absent)
	_ = pool.QueryRow(ctx, `
		SELECT left(query, 44), round(total_exec_time)::bigint
		FROM pg_stat_statements
		WHERE query NOT ILIKE '%pg_stat_statements%'
		ORDER BY total_exec_time DESC LIMIT 1`).Scan(&s.TopQuery, &s.TopTotalMs)

	// replication lag (primary side; zero rows when no replica)
	rows, err := pool.Query(ctx, `
		SELECT coalesce(pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn), 0)
		FROM pg_stat_replication`)
	if err == nil {
		for rows.Next() {
			var b int64
			_ = rows.Scan(&b)
			s.Replicas++
			if b > s.ReplayLagBytes {
				s.ReplayLagBytes = b
			}
		}
		rows.Close()
	}
	return s, nil
}

func printSnap(s *snapshot) {
	fmt.Printf("active=%-3d idle=%-3d idleInTx=%-2d blocked=%-2d oldestTx=%-8v cacheHit=%4.1f%%",
		s.Active, s.Idle, s.IdleInTx, s.Blocked, s.OldestTx.Round(time.Millisecond), s.CacheHit)
	if s.Replicas > 0 {
		fmt.Printf(" replicas=%d lag=%dB", s.Replicas, s.ReplayLagBytes)
	}
	if s.TopQuery != "" {
		fmt.Printf("\n  top: %-44s %vms total", s.TopQuery, s.TopTotalMs)
	}
	fmt.Println()
}

// durationSec scans an epoch-seconds float into time.Duration.
type durationSec time.Duration

func (d *durationSec) Scan(src any) error {
	if f, ok := src.(float64); ok {
		*d = durationSec(time.Duration(f * float64(time.Second)))
	}
	return nil
}

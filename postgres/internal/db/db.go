// Package db holds the tiny bit of boilerplate every lab program needs:
// open a pgx pool and wait for the server to accept connections.
//
// It is deliberately ~30 lines. Nothing important about PostgreSQL is hidden
// here — real connection handling is taught in 13-go-postgres/connection_pool.
package db

import (
	"context"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"

	"learndb/postgres/internal/dsn"
)

// Connect opens a pgx connection pool, pinging with retries so it also works
// in the first seconds after `docker compose up` while Postgres is still
// booting. A Ping is a real round trip — it proves the server answered, not
// just that a TCP socket opened.
func Connect(ctx context.Context) (*pgxpool.Pool, error) {
	pool, err := pgxpool.New(ctx, dsn.DSN())
	if err != nil {
		return nil, fmt.Errorf("parse config / create pool: %w", err)
	}

	deadline := time.Now().Add(30 * time.Second)
	for {
		pingCtx, cancel := context.WithTimeout(ctx, 2*time.Second)
		err = pool.Ping(pingCtx)
		cancel()
		if err == nil {
			return pool, nil
		}
		if time.Now().After(deadline) {
			pool.Close()
			return nil, fmt.Errorf("database not reachable within 30s: %w", err)
		}
		time.Sleep(500 * time.Millisecond)
	}
}

// MustConnect is Connect but fatal on error — fine for lab programs, and a
// teaching point: in a real service you'd return the error instead.
func MustConnect(ctx context.Context) *pgxpool.Pool {
	pool, err := Connect(ctx)
	if err != nil {
		panic(err)
	}
	return pool
}

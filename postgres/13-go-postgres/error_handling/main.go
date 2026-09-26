// ============================================================================
// 13-go-postgres/error_handling — SQLSTATE-driven decisions
// ============================================================================
// Run:
//   make up
//   go run ./13-go-postgres/error_handling
//
// pgconn.PgError carries the server's structured error: Code (SQLSTATE),
// Severity, Message, Detail, Hint, ConstraintName, TableName, SchemaName.
// The codes you will actually ship on:
//
//   23505 unique_violation      -> 409 conflict / ON CONFLICT path
//   23503 foreign_key_violation -> 409/400 (bad reference)
//   23502 not_null_violation    -> 400 (app bug or missing input)
//   23514 check_violation       -> 400 (validation)
//   40001 serialization_failure -> RETRY (SERIALIZABLE)
//   40P01 deadlock_detected     -> RETRY
//   55P03 lock_not_available    -> RETRY or backoff (NOWAIT/lock_timeout)
//   57014 query_canceled        -> timeout: do NOT retry blindly
//   57014 statement_timeout     -> same code
//   08003/08006 connection ex.  -> reconnect/retry once (idempotency!)
//   53300 too_many_connections  -> back off, alert
// ============================================================================
package main

import (
	"context"
	"errors"
	"fmt"

	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"

	"learndb/postgres/internal/db"
)

func main() {
	ctx := context.Background()
	pool := db.MustConnect(ctx)
	defer pool.Close()

	mustExec(pool, `DROP SCHEMA IF EXISTS m13_err CASCADE; CREATE SCHEMA m13_err;`)
	mustExec(pool, `CREATE TABLE m13_err.users (
		id int PRIMARY KEY,
		email text NOT NULL UNIQUE,
		age int CHECK (age >= 18))`)

	// -----------------------------------------------------------------------
	// 1. Trigger every interesting class and classify it
	// -----------------------------------------------------------------------
	attempts := []struct {
		label string
		sql   string
	}{
		{"valid insert (baseline)", `INSERT INTO m13_err.users VALUES (1, 'a@x.com', 30)`},
		{"unique_violation (23505)", `INSERT INTO m13_err.users VALUES (5, 'a@x.com', 30)`},
		{"check_violation (23514)", `INSERT INTO m13_err.users VALUES (2, 'b@x.com', 15)`},
		{"not_null_violation (23502)", `INSERT INTO m13_err.users VALUES (3, NULL, 30)`},
	}
	for _, a := range attempts {
		_, err := pool.Exec(ctx, a.sql)
		fmt.Printf("%-26s -> %v\n", a.label, classify(err))
	}

	// -----------------------------------------------------------------------
	// 2. The full PgError anatomy — everything the server told you
	// -----------------------------------------------------------------------
	_, err := pool.Exec(ctx, `INSERT INTO m13_err.users VALUES (9, 'a@x.com', 30)`)
	var pgErr *pgconn.PgError
	if errors.As(err, &pgErr) {
		fmt.Println("\nstructured error fields:")
		fmt.Println("  Code      :", pgErr.Code)           // 23505
		fmt.Println("  Severity  :", pgErr.Severity)       // ERROR
		fmt.Println("  Message   :", pgErr.Message)        // duplicate key value ...
		fmt.Println("  Detail    :", pgErr.Detail)         // Key (email)=(a@x.com) already exists.
		fmt.Println("  Constraint:", pgErr.ConstraintName) // users_email_key
		fmt.Println("  Table     :", pgErr.TableName)      // users
		// Message is for logs; Code+Constraint are for LOGIC. Never
		// string-match on "duplicate key" — locales and versions change text.
	}

	// -----------------------------------------------------------------------
	// 3. Mapping to HTTP-ish decisions (the shape of a real handler)
	// -----------------------------------------------------------------------
	fmt.Println("\nhandler-style mapping:")
	_, err = pool.Exec(ctx, `INSERT INTO m13_err.users VALUES (10, 'a@x.com', 30)`)
	fmt.Println("  ->", httpStatusFor(err))

	// -----------------------------------------------------------------------
	// 4. Wrap with %w so errors.As still works through your layers
	// -----------------------------------------------------------------------
	wrapped := fmt.Errorf("creating user: %w", err)
	var pe *pgconn.PgError
	fmt.Println("errors.As through wrapping:", errors.As(wrapped, &pe), pe != nil && pe.Code == "23505")
}

// classify is the retryability switch every service needs.
func classify(err error) string {
	if err == nil {
		return "nil (no error)"
	}
	var pgErr *pgconn.PgError
	if !errors.As(err, &pgErr) {
		return "non-postgres error: " + err.Error()
	}
	switch pgErr.Code {
	case "23505":
		return "unique_violation — map to 409 / take upsert path"
	case "23503":
		return "foreign_key_violation — 409, reference is gone/invalid"
	case "23502":
		return "not_null_violation — 400, app bug or missing input"
	case "23514":
		return "check_violation — 400, input failed validation"
	case "40001":
		return "serialization_failure — RETRY with backoff"
	case "40P01":
		return "deadlock_detected — RETRY with backoff"
	case "55P03":
		return "lock_not_available — retry or shed load"
	case "57014":
		return "query_canceled — do NOT auto-retry (timeout)"
	default:
		return "SQLSTATE " + pgErr.Code + " — " + pgErr.Message
	}
}

func httpStatusFor(err error) string {
	var pgErr *pgconn.PgError
	if !errors.As(err, &pgErr) {
		return "500 (unknown)"
	}
	switch pgErr.Code {
	case "23505", "23503":
		return "409 Conflict"
	case "23502", "23514", "22P02": // + invalid_text_representation
		return "400 Bad Request"
	case "40001", "40P01":
		return "retry internally, then 503"
	case "57014":
		return "504 Gateway Timeout"
	default:
		return "500 Internal Server Error (log full PgError)"
	}
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

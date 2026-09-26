// ============================================================================
// 01-basics/go — application-side fundamentals with pgx
// ============================================================================
// Run:
//   make up
//   go run ./01-basics/go
//
// This program mirrors what the SQL files taught, from Go:
//   1. connecting with a pool
//   2. parameterized queries (and why string-built SQL is a vulnerability)
//   3. NULL handling while scanning
//   4. INSERT ... RETURNING to avoid a second round trip
//   5. mapping SQLSTATE error codes (23505) to application behavior
// ============================================================================
package main

import (
	"context"
	"errors"
	"fmt"
	"log"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"

	"learndb/postgres/internal/db"
)

// User mirrors the table shape. Age is *int because SQL NULL has no zero
// value — a pointer (or sql.Null[T] / pgtype) makes the absence explicit.
// Forgetting this is THE most common first bug with pgx: "cannot scan NULL
// into *int".
type User struct {
	ID    int64
	Email string
	Age   *int64 // NULL-able column
}

func main() {
	ctx := context.Background()
	pool := db.MustConnect(ctx)
	defer pool.Close()

	// Idempotent setup — same discipline as the SQL files.
	mustExec(ctx, pool, `DROP SCHEMA IF EXISTS m01_go CASCADE`)
	mustExec(ctx, pool, `CREATE SCHEMA m01_go`)
	mustExec(ctx, pool, `
		CREATE TABLE m01_go.users (
			id    bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
			email text NOT NULL UNIQUE,
			age    int
		)`)

	// ------------------------------------------------------------------------
	// 1. Parameterized queries — ALWAYS ($1, $2, ...), never fmt.Sprintf.
	// ------------------------------------------------------------------------
	// The server receives SQL and values separately: no parsing of user data,
	// no injection, and pgx can reuse the parsed statement (see
	// 13-go-postgres/prepared_queries). Compare:
	//
	//   UNSAFE:  fmt.Sprintf("... WHERE email = '%s'", email)  // ' OR '1'='1
	//   SAFE:    "... WHERE email = $1", email
	//
	_, err := pool.Exec(ctx,
		`INSERT INTO m01_go.users (email, age) VALUES ($1, $2)`,
		"ada@example.com", nil) // nil -> SQL NULL
	must(err)

	// ------------------------------------------------------------------------
	// 2. Scanning rows, including NULLs
	// ------------------------------------------------------------------------
	var u User
	err = pool.QueryRow(ctx,
		`SELECT id, email, age FROM m01_go.users WHERE email = $1`,
		"ada@example.com",
	).Scan(&u.ID, &u.Email, &u.Age)
	must(err)
	fmt.Printf("scanned: %+v (age is NULL -> nil pointer: %v)\n", u, u.Age == nil)

	// pgx.ErrNoRows is not an "error" in the failure sense — it is the
	// documented "your query matched nothing" signal. Handle it explicitly:
	err = pool.QueryRow(ctx, `SELECT 1 FROM m01_go.users WHERE email = $1`, "nobody@x.com").Scan((*int)(nil))
	switch {
	case errors.Is(err, pgx.ErrNoRows):
		fmt.Println("no rows: got the expected sentinel, not a crash")
	case err != nil:
		log.Fatal(err)
	}

	// ------------------------------------------------------------------------
	// 3. Multi-row reads — always Close rows (releases the connection)
	// ------------------------------------------------------------------------
	rows, err := pool.Query(ctx, `SELECT id, email, age FROM m01_go.users ORDER BY id`)
	must(err)
	defer rows.Close()

	for rows.Next() {
		var u User
		must(rows.Scan(&u.ID, &u.Email, &u.Age))
		fmt.Printf("row: id=%d email=%s age=%v\n", u.ID, u.Email, ageOrNA(u.Age))
	}
	must(rows.Err()) // surface network/decoding failures that abort iteration

	// ------------------------------------------------------------------------
	// 4. INSERT ... RETURNING — one round trip instead of insert + select
	// ------------------------------------------------------------------------
	var newID int64
	err = pool.QueryRow(ctx,
		`INSERT INTO m01_go.users (email) VALUES ($1) RETURNING id`,
		"grace@example.com",
	).Scan(&newID)
	must(err)
	fmt.Println("RETURNING gave us the id without a second query:", newID)

	// ------------------------------------------------------------------------
	// 5. Error handling by SQLSTATE — the production-grade pattern
	// ------------------------------------------------------------------------
	_, err = pool.Exec(ctx,
		`INSERT INTO m01_go.users (email) VALUES ($1)`, "ada@example.com")
	var pgErr *pgconn.PgError
	if errors.As(err, &pgErr) && pgErr.Code == "23505" { // unique_violation
		fmt.Printf("handled in Go: 23505 unique_violation (%s) -> map to HTTP 409\n",
			pgErr.ConstraintName) // users_email_key — tells you WHICH constraint
	} else {
		must(err)
	}

	// The full code table you'll use constantly lives in
	// 13-go-postgres/error_handling — 23503 FK, 23502 null, 23514 check,
	// 40001 serialization, 40P01 deadlock, 57014 canceled, ...

	fmt.Println("\n01-basics/go: all sections OK")
}

func ageOrNA(a *int64) string {
	if a == nil {
		return "N/A (NULL)"
	}
	return fmt.Sprint(*a)
}

func mustExec(ctx context.Context, pool interface {
	Exec(context.Context, string, ...any) (pgconn.CommandTag, error)
}, sql string) {
	_, err := pool.Exec(ctx, sql)
	must(err)
}

func must(err error) {
	if err != nil {
		log.Fatal(err)
	}
}

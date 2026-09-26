// ============================================================================
// 13-go-postgres/pgx — connection types, scanning patterns, custom types
// ============================================================================
// Run:
//   make up
//   go run ./13-go-postgres/pgx
//
// pgx's two faces:
//   * pgxpool.Pool  — connection POOL: Acquire/Release, safe for many
//                     goroutines. Your default for services.
//   * pgx.Conn      — ONE dedicated connection. Needed for LISTEN/NOTIFY,
//                     advisory session locks, COPY with custom sources, or
//                     when you want to hold a session for a while.
//
// Plus the scanning patterns you'll use daily:
//   manual Scan -> struct; pgx.CollectRows + RowToStructByName (pgx v5);
//   custom pgtype handling; and the simple vs extended protocol choice.
// ============================================================================
package main

import (
	"context"
	"errors"
	"fmt"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"learndb/postgres/internal/db"
)

// User mirrors the table. Field names must match column names for
// RowToStructByName (case-insensitive) — or use `db:"..."` struct tags.
type User struct {
	ID    int64  `db:"id"`
	Email string `db:"email"`
	Bio   string `db:"bio"`
}

func main() {
	ctx := context.Background()
	pool := db.MustConnect(ctx)
	defer pool.Close()
	fmt.Println("pool stats:", pool.Stat().TotalConns(), "conns (lazily opened)")

	setup(ctx, pool)

	// -----------------------------------------------------------------------
	// 1. Scanning patterns — manual vs CollectRows
	// -----------------------------------------------------------------------
	// Manual: explicit, no reflection, zero surprises:
	rows, err := pool.Query(ctx, `SELECT id, email, bio FROM m13_pgx.users ORDER BY id`)
	must(err)
	defer rows.Close()
	for rows.Next() {
		var u User
		must(rows.Scan(&u.ID, &u.Email, &u.Bio))
		fmt.Printf("manual:   %+v\n", u)
	}
	must(rows.Err())

	// CollectRows + RowToStructByName: one line per query, maps by name:
	crows, err := pool.Query(ctx, `SELECT id, email, bio FROM m13_pgx.users ORDER BY id`)
	must(err)
	users, err := pgx.CollectRows(crows, pgx.RowToStructByName[User])
	must(err)
	for _, u := range users {
		fmt.Printf("collect:  %+v\n", u)
	}
	// Trade-off: reflection-based convenience vs explicitness. CollectRows
	// also enforces "no rows leaked" for you. Use whichever your team reads
	// better; performance differences are negligible for sane result sets.

	// -----------------------------------------------------------------------
	// 2. QueryRow + ErrNoRows — the sentinel you must handle
	// -----------------------------------------------------------------------
	_, err = one(ctx, pool, `SELECT email FROM m13_pgx.users WHERE id = $1`, 99)
	fmt.Println("missing row:", errors.Is(err, pgx.ErrNoRows), "(handle it — not a crash)")

	// -----------------------------------------------------------------------
	// 3. Custom Go types on both sides (Scanner + Valuer)
	// -----------------------------------------------------------------------
	// The database has a text[] tags column; expose it as []string in Go by
	// teaching pgx with an inline wrapper or pgtype.Text. For plain []string
	// pgx already handles text[] natively:
	var tags []string
	must(pool.QueryRow(ctx, `SELECT tags FROM m13_pgx.users WHERE id = 1`).Scan(&tags))
	fmt.Println("array scan:", tags)
	_, err = pool.Exec(ctx, `UPDATE m13_pgx.users SET tags = $1 WHERE id = 2`,
		[]string{"go", "postgres"})
	must(err)

	// For genuinely custom mappings you implement database/sql interfaces —
	// pgx v5 respects both pgtype and stdlib Scanner/Valuer:
	//   func (t *Tags) Scan(src any) error        // FROM the database
	//   func (t Tags) Value() (driver.Value, error) // TO the database

	// -----------------------------------------------------------------------
	// 4. A dedicated conn (pgx.Conn) — session-bound features
	// -----------------------------------------------------------------------
	// Pools rotate connections; anything tied to ONE session (advisory
	// session locks, LISTEN, SET that must persist) needs a dedicated conn:
	conn, err := pgx.Connect(ctx, pool.Config().ConnString())
	must(err)
	defer conn.Close(ctx)

	// Session GUCs stick on a dedicated conn:
	_, err = conn.Exec(ctx, `SET application_name = 'lab-dedicated-conn'`)
	must(err)
	var who string
	must(conn.QueryRow(ctx, `SHOW application_name`).Scan(&who))
	fmt.Println("dedicated conn SET persists:", who)
	// On a POOL, `SET` lands on whichever conn ran it and follows THAT conn
	// around — a classic source of weird bugs. Pool + session state =
	// SET LOCAL inside a transaction, or conn config, never bare SET.

	// -----------------------------------------------------------------------
	// 5. Protocol choice (affects prepared statements — see prepared_queries)
	// -----------------------------------------------------------------------
	// Default: extended protocol ($n params, auto-prepare, one round trip
	// per statement). simple_protocol=true forces the old-school protocol:
	// no parameters, no prepared statements — occasionally needed for weird
	// proxies/tools. Don't set it unless you know why.

	fmt.Println("\npgx: all sections OK — see error_handling next")
}

func setup(ctx context.Context, pool *pgxpool.Pool) {
	_, err := pool.Exec(ctx, `DROP SCHEMA IF EXISTS m13_pgx CASCADE; CREATE SCHEMA m13_pgx;`)
	must(err)
	_, err = pool.Exec(ctx, `CREATE TABLE m13_pgx.users (
		id int PRIMARY KEY, email text NOT NULL, bio text, tags text[] NOT NULL DEFAULT '{}')`)
	must(err)
	_, err = pool.Exec(ctx, `INSERT INTO m13_pgx.users (id, email, bio, tags) VALUES
		(1, 'ada@example.com', 'first', ARRAY['math']),
		(2, 'grace@example.com', NULL, '{}')`)
	must(err)
}

func one(ctx context.Context, pool *pgxpool.Pool, q string, args ...any) (string, error) {
	var s string
	err := pool.QueryRow(ctx, q, args...).Scan(&s)
	return s, err
}

func must(err error) {
	if err != nil {
		panic(err)
	}
}

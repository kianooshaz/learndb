// Package dsn is the single place lab programs get their connection string.
//
// Why it exists: every example in this lab should run against the docker
// compose database by default, but be pointable anywhere via the de-facto
// standard DATABASE_URL environment variable (the same one Heroku/Render/
// Fly.io hand you). Notice we do NOT hardcode credentials in each program.
package dsn

import "os"

// DSN returns the PostgreSQL connection string for all lab programs.
func DSN() string {
	if v := os.Getenv("DATABASE_URL"); v != "" {
		return v
	}
	return "postgres://postgres:postgres@localhost:5432/learndb"
}

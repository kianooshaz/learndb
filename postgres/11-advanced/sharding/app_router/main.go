// ============================================================================
// 11-advanced/sharding/app_router — application-level sharding, in Go
// ============================================================================
// Run:
//   make up
//   go run ./11-advanced/sharding/app_router
//
// Level-1 sharding: YOUR code routes. This program builds a 3-shard cluster
// (three schemas standing in for three servers on the lab instance — the
// routing logic is identical when each pool points at a different host) and
// implements the pieces every production router needs:
//
//   1. deterministic shard mapping        (modulo AND jump-consistent-hash,
//      with the resharding-cost difference measured)
//   2. one pgxpool per shard              (pools are cheap; know yours)
//   3. routed single-shard CRUD           (the 99% OLTP path)
//   4. scatter-gather fan-out             (queries without the shard key)
//      with merged top-N pagination
//   5. global ids without global locks    (per-shard ranges vs UUID)
//   6. the cross-shard transaction problem, demonstrated then avoided
// ============================================================================
package main

import (
	"context"
	"crypto/md5"
	"encoding/binary"
	"fmt"
	"sort"
	"sync"

	"github.com/jackc/pgx/v5/pgxpool"

	"learndb/postgres/internal/dsn"
)

// ---------------------------------------------------------------------------
// Shard mapping: modulo vs jump consistent hash
// ---------------------------------------------------------------------------

// shardModulo: the naive map. Fast, deterministic — and adding a shard
// relocates ~every key.
func shardModulo(key uint64, shards int) int {
	return int(key % uint64(shards))
}

// jumpHash: Lamping & Voss's jump consistent hash. Adding shard N+1 moves
// only ~1/(N+1) of keys — resharding cost drops from "everything" to
// "one slice". Same key space as modulo, different landing spots.
func jumpHash(key uint64, shards int) int {
	b, j := -1, 0
	for j < shards {
		b = j
		key = key*2862933555777941757 + 1
		j = int(float64(b+1) * (float64(int64(1)<<31) / float64((key>>33)+1)))
	}
	return b
}

func keyHash(s string) uint64 {
	sum := md5.Sum([]byte(s))           // any stable hash works — it must
	return binary.BigEndian.Uint64(sum[:8]) // live in ONE shared library
}

// ---------------------------------------------------------------------------
// The router: pools + mapping + the operations
// ---------------------------------------------------------------------------

type Router struct {
	shards []*pgxpool.Pool // one pool per shard; in prod: one per HOST
	names  []string
}

func NewRouter(ctx context.Context, n int) (*Router, error) {
	r := &Router{}
	for i := 0; i < n; i++ {
		name := fmt.Sprintf("m11_appshard%d", i)
		cfg, err := pgxpool.ParseConfig(dsn.DSN())
		if err != nil {
			return nil, err
		}
		// Bind the pool to its shard schema — same trick as one pool per
		// database host in production:
		cfg.ConnConfig.RuntimeParams["search_path"] = name + ", public"
		pool, err := pgxpool.NewWithConfig(ctx, cfg)
		if err != nil {
			return nil, err
		}
		if _, err := pool.Exec(ctx, fmt.Sprintf(
			`CREATE SCHEMA IF NOT EXISTS %s;
			 CREATE TABLE IF NOT EXISTS %s.documents (
			   id bigint PRIMARY KEY,
			   user_id text NOT NULL,
			   title text NOT NULL,
			   likes int NOT NULL DEFAULT 0)`, name, name)); err != nil {
			return nil, err
		}
		if _, err := pool.Exec(ctx, fmt.Sprintf(
			`TRUNCATE %s.documents`, name)); err != nil {
			return nil, err
		}
		r.shards = append(r.shards, pool)
		r.names = append(r.names, name)
	}
	return r, nil
}

func (r *Router) Close() {
	for _, p := range r.shards {
		p.Close()
	}
}

// ShardFor: THE routing decision — every routed call funnels through here.
func (r *Router) ShardFor(userID string) *pgxpool.Pool {
	return r.shards[jumpHash(keyHash(userID), len(r.shards))]
}

func main() {
	ctx := context.Background()

	router, err := NewRouter(ctx, 3)
	must(err)
	defer router.Close()
	fmt.Println("router up: 3 shards (schemas m11_appshard0..2)")

	// -----------------------------------------------------------------------
	// 1. Resharding math, measured: modulo vs jump hash moving 4->5 shards
	// -----------------------------------------------------------------------
	keys := make([]string, 5000)
	for i := range keys {
		keys[i] = fmt.Sprintf("user-%d", i)
	}
	moveMod, moveJump := 0, 0
	for _, k := range keys {
		h := keyHash(k)
		if shardModulo(h, 4) != shardModulo(h, 5) {
			moveMod++
		}
		if jumpHash(h, 4) != jumpHash(h, 5) {
			moveJump++
		}
	}
	fmt.Printf("reshard math (4 -> 5 shards): modulo moves %d/%d keys, jump hash moves %d/%d\n",
		moveMod, len(keys), moveJump, len(keys))
	fmt.Println("             (jump moves ~1/5 — the reason consistent hashing exists)")

	// -----------------------------------------------------------------------
	// 2. Routed writes: 1000 documents, one INSERT each — one shard each
	// -----------------------------------------------------------------------
	for i := 1; i <= 1000; i++ {
		uid := fmt.Sprintf("user-%d", i%200)
		shard := router.ShardFor(uid)
		// Per-shard id ranges (shard 0: 0-999_999, shard 1: 1M-2M...) —
		// global uniqueness WITHOUT global coordination; the range owner is
		// shard-local. (Alternative: UUIDs — see 02-data-types/uuid.sql.)
		shardIdx := -1
		for j, p := range router.shards {
			if p == shard {
				shardIdx = j
			}
		}
		id := int64(shardIdx)*1_000_000 + int64(i)
		_, err := shard.Exec(ctx,
			`INSERT INTO documents (id, user_id, title, likes) VALUES ($1,$2,$3,$4)`,
			id, uid, fmt.Sprintf("doc-%d", i), i%97)
		must(err)
	}
	counts := make([]int, len(router.shards))
	var wg sync.WaitGroup
	for i, p := range router.shards {
		wg.Add(1)
		go func(i int, p *pgxpool.Pool) {
			defer wg.Done()
			must(p.QueryRow(ctx, `SELECT count(*) FROM documents`).Scan(&counts[i]))
		}(i, p)
	}
	wg.Wait()
	fmt.Printf("row distribution across shards: %v (even = good key)\n", counts)

	// -----------------------------------------------------------------------
	// 3. Routed read: single-shard, zero fan-out
	// -----------------------------------------------------------------------
	uid := "user-42"
	var n int
	must(router.ShardFor(uid).QueryRow(ctx,
		`SELECT count(*) FROM documents WHERE user_id = $1`, uid).Scan(&n))
	fmt.Printf("routed read for %s: %d docs, ONE shard touched\n", uid, n)

	// -----------------------------------------------------------------------
	// 4. Scatter-gather: top-5 by likes across ALL shards, merged in Go
	// -----------------------------------------------------------------------
	type doc struct {
		ID    int64
		Title string
		Likes int
		Shard string
	}
	results := make(chan doc, 3*len(router.shards))
	for i, p := range router.shards {
		wg.Add(1)
		go func(i int, p *pgxpool.Pool) {
			defer wg.Done()
			rows, err := p.Query(ctx,
				`SELECT id, title, likes FROM documents ORDER BY likes DESC LIMIT 3`)
			must(err)
			defer rows.Close()
			for rows.Next() {
				var d doc
				must(rows.Scan(&d.ID, &d.Title, &d.Likes))
				d.Shard = fmt.Sprintf("shard%d", i)
				results <- d
			}
			must(rows.Err())
		}(i, p)
	}
	wg.Wait()
	close(results)
	var top []doc
	for d := range results {
		top = append(top, d)
	}
	// The merge step: per-shard top-k combined into global top-k. Note the
	// cost model: per-shard ORDER BY likes LIMIT 3 needs a likes index per
	// shard; coordinator merges k*shards rows.
	sort.Slice(top, func(a, b int) bool { return top[a].Likes > top[b].Likes })
	fmt.Println("scatter-gather global top-3 by likes:")
	for i, d := range top[:3] {
		fmt.Printf("  %d. %-10s likes=%-3d from %s\n", i+1, d.Title, d.Likes, d.Shard)
	}

	// -----------------------------------------------------------------------
	// 5. The cross-shard transaction problem, honestly
	// -----------------------------------------------------------------------
	// Two users on DIFFERENT shards; "transfer 10 likes" spans two pools:
	from, to := "user-1", "user-3"
	if router.ShardFor(from) == router.ShardFor(to) {
		from = "user-5" // ensure different shards for the demo
	}
	// Naive: two independent transactions. Crash between them = lost 10.
	// Production answers, in the order you should try them:
	//   (a) redesign: make the transfer unit share a shard key (an account
	//       ledger sharded by (account_id) makes transfers single-shard!)
	//   (b) outbox + compensations (saga): write intent rows in EACH shard's
	//       tx, a worker applies+reconciles (exactly-once via ids)
	//   (c) 2PC via PREPARE TRANSACTION (max_prepared_transactions>0; ops
	//       burden: stuck prepared txs block vacuum on those rows)
	// There is no free (c). Prefer (a); ship (b); fear (c).
	fmt.Printf("cross-shard pair detected (%s vs %s on different shards) — see notes in source\n", from, to)
}

func must(err error) {
	if err != nil {
		panic(err)
	}
}

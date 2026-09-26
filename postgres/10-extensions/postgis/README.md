# 10-extensions/postgis

PostGIS needs a different container image (`postgis/postgis:16-3.4`), so it
runs as an opt-in compose profile on port **5433** — separate from the main
lab database on 5432.

```bash
make postgis                                          # start it (pulls image)
make sql-postgis FILE=10-extensions/postgis/basics.sql
docker compose exec postgis psql -U postgres -d learndb   # interactive
```

Files:
- `basics.sql` — geometry vs geography, meters vs degrees, GiST spatial
  indexes, ST_DWithin/nearby queries, KNN ordering, areas/containment.

The lab's `internal/db` helper still defaults to port 5432 (the main
database); for Go experiments against PostGIS set
`DATABASE_URL=postgres://postgres:postgres@localhost:5433/learndb` before
running a program.

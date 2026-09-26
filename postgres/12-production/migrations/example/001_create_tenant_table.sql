-- expand: a new table for an upcoming feature (no backfill needed)
CREATE SCHEMA IF NOT EXISTS app;
CREATE TABLE app.tenants (
    id   bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name text NOT NULL
);

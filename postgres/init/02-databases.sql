-- Runs automatically on first container boot, after 01-extensions.sql.

\set ON_ERROR_STOP on

-- Logical replication (11-advanced/logical_replication/) publishes changes from
-- `learndb` and applies them to `shop` — two databases on the same instance,
-- exactly like two separate servers in real deployments.
CREATE DATABASE shop;

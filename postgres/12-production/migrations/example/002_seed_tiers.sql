-- reference data belongs in migrations too (reproducible environments):
CREATE TABLE app.tiers (code text PRIMARY KEY, rank int NOT NULL);
INSERT INTO app.tiers VALUES ('free', 0), ('pro', 1), ('enterprise', 2);

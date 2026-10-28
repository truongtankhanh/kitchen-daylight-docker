#!/usr/bin/env bash
# Runs once, on the first start of an empty data directory (docs/decisions/0004-postgres-init-design.md).
# Gives kd_app the least it needs on objects that kd_migrator creates later: SELECT, INSERT, UPDATE on
# tables and USAGE on sequences. Anything stricter (REVOKE UPDATE on append-only tables) or wider
# (DELETE) is the job of the monorepo's migrations.
set -euo pipefail

: "${KD_DATABASE:?KD_DATABASE is not set}"

for db in "$KD_DATABASE" kd_scratch; do
  psql -v ON_ERROR_STOP=1 --username "${POSTGRES_USER:-postgres}" --dbname "$db" <<'SQL'
GRANT USAGE ON SCHEMA public TO kd_app;
ALTER DEFAULT PRIVILEGES FOR ROLE kd_migrator GRANT SELECT, INSERT, UPDATE ON TABLES TO kd_app;
ALTER DEFAULT PRIVILEGES FOR ROLE kd_migrator GRANT USAGE ON SEQUENCES TO kd_app;
SQL
done

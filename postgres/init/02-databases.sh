#!/usr/bin/env bash
# Runs once, on the first start of an empty data directory (docs/decisions/0004-postgres-init-design.md).
# Creates the application database (KD_DATABASE: kd_dev or kd_test) and an empty kd_scratch,
# owned by kd_migrator, UTF8, builtin C.UTF-8, time zone UTC, closed to PUBLIC.
set -euo pipefail

: "${KD_DATABASE:?KD_DATABASE is not set}"

pg_user=${POSTGRES_USER:-postgres}

for db in "$KD_DATABASE" kd_scratch; do
  # template0 so the locale is stated here instead of inherited from initdb.
  psql -v ON_ERROR_STOP=1 --username "$pg_user" --dbname postgres -v db="$db" <<'SQL'
CREATE DATABASE :"db" OWNER kd_migrator TEMPLATE template0
  ENCODING 'UTF8' LOCALE_PROVIDER builtin LOCALE 'C.UTF-8';
REVOKE ALL ON DATABASE :"db" FROM PUBLIC;
GRANT CONNECT ON DATABASE :"db" TO kd_migrator, kd_app;
ALTER DATABASE :"db" SET timezone TO 'UTC';
SQL

  psql -v ON_ERROR_STOP=1 --username "$pg_user" --dbname "$db" <<'SQL'
REVOKE CREATE ON SCHEMA public FROM PUBLIC;
SQL
done

#!/usr/bin/env bash
# Runs once, on the first start of an empty data directory (docs/decisions/0004-postgres-init-design.md).
# Creates the four extensions in schema public of both databases. The superuser is needed because
# PostGIS is not a trusted extension; kd_migrator could not create it.
set -euo pipefail

: "${KD_DATABASE:?KD_DATABASE is not set}"

for db in "$KD_DATABASE" kd_scratch; do
  psql -v ON_ERROR_STOP=1 --username "${POSTGRES_USER:-postgres}" --dbname "$db" <<'SQL'
CREATE EXTENSION IF NOT EXISTS postgis WITH SCHEMA public;
CREATE EXTENSION IF NOT EXISTS pg_trgm WITH SCHEMA public;
CREATE EXTENSION IF NOT EXISTS unaccent WITH SCHEMA public;
CREATE EXTENSION IF NOT EXISTS citext WITH SCHEMA public;
SQL
done

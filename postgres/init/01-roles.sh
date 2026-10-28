#!/usr/bin/env bash
# Runs once, on the first start of an empty data directory (docs/decisions/0004-postgres-init-design.md).
# Creates the migration role and the application role. Passwords come from the environment.
set -euo pipefail

: "${KD_MIGRATOR_PASSWORD:?KD_MIGRATOR_PASSWORD is not set}"
: "${KD_APP_PASSWORD:?KD_APP_PASSWORD is not set}"

# SQL goes through stdin: psql does not substitute :'name' in a -c string.
psql -v ON_ERROR_STOP=1 --username "${POSTGRES_USER:-postgres}" --dbname postgres \
  -v migrator_pw="$KD_MIGRATOR_PASSWORD" -v app_pw="$KD_APP_PASSWORD" <<'SQL'
CREATE ROLE kd_migrator LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS
  PASSWORD :'migrator_pw';
CREATE ROLE kd_app LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS
  PASSWORD :'app_pw';
SQL

#!/usr/bin/env bash
# Resets the test database in seconds by cloning a template (docs/5-test-stack-and-ci.md, 5.1; risk K5).
# Contract: docs/4-scripts-contract.md. Exit codes: 0 ok, 1 an SQL step failed, 2 usage error or missing
# prerequisite, 3 refused for safety.
set -euo pipefail

TEST_DB=kd_test
TEMPLATE_DB=kd_test_template

usage() {
  cat <<'EOF'
Usage: scripts/test-reset-db.sh [--create-template]

Without an argument: drops kd_test and recreates it with CREATE DATABASE kd_test TEMPLATE kd_test_template, then
sets again what a clone does not copy (owner kd_migrator, no access for PUBLIC, CONNECT for kd_migrator and
kd_app, time zone UTC). Open connections to kd_test are terminated first, so clients (the API pool, a test
runner) must reconnect.

  --create-template   (re)create kd_test_template from the current kd_test. Run it once, right after the
                      seed, while kd_test holds the fresh seeded data. The template is marked as a template
                      with connections disallowed, so nothing can connect to it. Connections to kd_test are
                      blocked and terminated while it is copied.
  --help              show this text

Only the database kd_test is reset: Mailpit messages and S3 objects are not touched. The stack must be running
(scripts/test-up.sh). It runs psql inside the postgres container as the superuser over the Unix socket, so no
password is used. It refuses to run unless .env.test says APP_ENV=test and KD_DATABASE=kd_test.

Exit codes: 0 ok, 1 an SQL step failed, 2 usage error, no .env.test, Docker not running, stack not running or
(without --create-template) no template yet, 3 refused (APP_ENV or KD_DATABASE is not the test one).
EOF
}

log() { printf '[kd] %s\n' "$*"; }

cd "$(dirname "${BASH_SOURCE[0]}")/.."

create_template=0
for arg in "$@"; do
  case "$arg" in
    -h|--help) usage; exit 0 ;;
  esac
done
for arg in "$@"; do
  case "$arg" in
    --create-template) create_template=1 ;;
    *) log "unknown argument: $arg" >&2; usage >&2; exit 2 ;;
  esac
done

if [ ! -f .env.test ]; then
  log ".env.test not found; run scripts/init-env.sh <slot>" >&2
  exit 2
fi
set -a
# shellcheck source=/dev/null
. ./.env.test
set +a
project=${COMPOSE_PROJECT_NAME:-kd-docker-test}

if [ "${APP_ENV:-}" != test ] || [ "${KD_DATABASE:-}" != "$TEST_DB" ]; then
  log "refused: .env.test must say APP_ENV=test and KD_DATABASE=$TEST_DB (got '${APP_ENV:-}' and '${KD_DATABASE:-}')" >&2
  exit 3
fi
case "$project" in
  *-test) ;;
  *) log "refused: project '$project' does not end in -test; it must not be the dev project" >&2; exit 3 ;;
esac

if ! docker info >/dev/null 2>&1; then
  log "Docker is not running" >&2
  exit 2
fi

compose=(docker compose -p "$project" --env-file .env.test --env-file versions.env -f compose.test.yaml)

running=$("${compose[@]}" ps --status running --services 2>/dev/null) || running=""
case "
$running
" in
  *"
postgres
"*) ;;
  *) log "the test stack is not running (postgres is down); run scripts/test-up.sh" >&2; exit 2 ;;
esac

# psql_su <psql arguments>: psql as the superuser in the postgres container; SQL comes on stdin or with -c.
psql_su() {
  "${compose[@]}" exec -T postgres psql -X -q -v ON_ERROR_STOP=1 -U postgres -d postgres "$@"
}

if [ "$create_template" = 1 ]; then
  log "creating $TEMPLATE_DB from $TEST_DB (connections to $TEST_DB are blocked and terminated meanwhile)"
  rc=0
  psql_su -v db="$TEST_DB" -v tpl="$TEMPLATE_DB" <<'SQL' || rc=$?
ALTER DATABASE :"db" WITH ALLOW_CONNECTIONS false;
SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = :'db' AND pid <> pg_backend_pid();
SELECT format('ALTER DATABASE %I WITH is_template false', :'tpl') WHERE EXISTS (SELECT 1 FROM pg_database WHERE datname = :'tpl') \gexec
DROP DATABASE IF EXISTS :"tpl" WITH (FORCE);
CREATE DATABASE :"tpl" TEMPLATE :"db" OWNER kd_migrator;
ALTER DATABASE :"tpl" WITH is_template true ALLOW_CONNECTIONS false;
SQL
  # Always let clients back in, also when a step above failed.
  psql_su -c "ALTER DATABASE $TEST_DB WITH ALLOW_CONNECTIONS true" </dev/null || rc=1
  if [ "$rc" -ne 0 ]; then
    log "creating the template failed" >&2
    exit 1
  fi
  log "$TEMPLATE_DB is ready"
  exit 0
fi

has_template=$(psql_su -tA -c "SELECT 1 FROM pg_database WHERE datname = '$TEMPLATE_DB'" </dev/null) || {
  log "could not query the database list" >&2
  exit 1
}
if [ -z "$has_template" ]; then
  log "$TEMPLATE_DB does not exist; run scripts/test-reset-db.sh --create-template right after the seed" >&2
  exit 2
fi

log "dropping $TEST_DB and recreating it from $TEMPLATE_DB (open connections are terminated)"
if ! psql_su -v db="$TEST_DB" -v tpl="$TEMPLATE_DB" <<'SQL'
SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = :'db' AND pid <> pg_backend_pid();
DROP DATABASE IF EXISTS :"db" WITH (FORCE);
CREATE DATABASE :"db" TEMPLATE :"tpl" OWNER kd_migrator;
REVOKE ALL ON DATABASE :"db" FROM PUBLIC;
GRANT CONNECT ON DATABASE :"db" TO kd_migrator, kd_app;
ALTER DATABASE :"db" SET timezone TO 'UTC';
SQL
then
  log "resetting $TEST_DB failed" >&2
  exit 1
fi
log "$TEST_DB recreated from $TEMPLATE_DB in ${SECONDS}s"

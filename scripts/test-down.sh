#!/usr/bin/env bash
# Removes the test stack: containers, anonymous volumes and the network of project kd-docker-test only.
# Contract: docs/4-scripts-contract.md. Exit codes: 0 ok, 1 docker compose down failed, 2 usage error or
# Docker not running, 3 refused for safety.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/test-down.sh

Runs "down -v --remove-orphans" for the test project (kd-docker-test) only, after printing the containers,
volumes and networks it is going to remove. The test stack is throw-away (data is on tmpfs), so this is the one
dev-side script that deletes without asking. It is safe to run at any time, also when nothing is running, and it
never touches the dev stack. .env.test.out is left in place.

Uses .env.test when it exists; without it the project name defaults to kd-docker-test.

  --help   show this text

Exit codes: 0 ok, 1 docker compose down failed, 2 usage error or Docker not running,
3 refused (APP_ENV is not test, or the project name does not end in -test).
EOF
}

log() { printf '[kd] %s\n' "$*"; }

cd "$(dirname "${BASH_SOURCE[0]}")/.."

for arg in "$@"; do
  case "$arg" in
    -h|--help) usage; exit 0 ;;
    *) log "unknown argument: $arg" >&2; usage >&2; exit 2 ;;
  esac
done

if [ ! -f compose.test.yaml ]; then
  log "compose.test.yaml not found" >&2
  exit 2
fi

env_files=(--env-file versions.env)
if [ -f .env.test ]; then
  set -a
  # shellcheck source=/dev/null
  . ./.env.test
  set +a
  env_files=(--env-file .env.test --env-file versions.env)
  if [ "${APP_ENV:-}" != test ]; then
    log "refused: APP_ENV is '${APP_ENV:-}' in .env.test, expected 'test'" >&2
    exit 3
  fi
else
  log ".env.test not found; using the default project name"
fi
project=${COMPOSE_PROJECT_NAME:-kd-docker-test}
# down -v deletes volumes, so the project must be recognisably a test one.
case "$project" in
  *-test) ;;
  *) log "refused: project '$project' does not end in -test; it must not be the dev project" >&2; exit 3 ;;
esac

if ! docker info >/dev/null 2>&1; then
  log "Docker is not running" >&2
  exit 2
fi

names=$(docker ps -a --filter "label=com.docker.compose.project=$project" \
  --filter "label=com.kitchen-daylight.stack=test" --format '{{.Names}}')
volumes=$(docker volume ls -q --filter "label=com.docker.compose.project=$project")
networks=$(docker network ls --filter "label=com.docker.compose.project=$project" --format '{{.Name}}')
if [ -z "$names$volumes$networks" ]; then
  log "nothing to remove for project $project"
else
  log "removing from project $project:"
  if [ -n "$names" ]; then printf '%s\n' "$names" | sed 's/^/[kd]   container /'; fi
  if [ -n "$volumes" ]; then printf '%s\n' "$volumes" | sed 's/^/[kd]   volume /'; fi
  if [ -n "$networks" ]; then printf '%s\n' "$networks" | sed 's/^/[kd]   network /'; fi
fi

if ! docker compose -p "$project" "${env_files[@]}" -f compose.test.yaml down -v --remove-orphans; then
  log "docker compose down failed" >&2
  exit 1
fi
log "test stack is down"

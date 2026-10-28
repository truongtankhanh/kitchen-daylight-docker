#!/usr/bin/env bash
# Stops and removes the containers and the network of the dev stack. Volumes are always kept.
# Contract: docs/4-scripts-contract.md. Exit codes: 0 ok, 1 failed, 2 usage error or missing prerequisite.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/down.sh

Stops and removes the containers and the network of this project. Named volumes (pgdata, s3data)
are NOT removed; scripts/reset.sh is the only dev script that deletes data.

  --help   show this text

Exit codes: 0 ok, 1 docker compose down failed, 2 usage error, no .env, Docker not running.
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

if [ ! -f .env ]; then
  log ".env not found; run scripts/init-env.sh <slot>" >&2
  exit 2
fi
set -a
# shellcheck source=/dev/null
. ./.env
set +a
project=${COMPOSE_PROJECT_NAME:-kd-docker}

if ! docker info >/dev/null 2>&1; then
  log "Docker is not running" >&2
  exit 2
fi

files=(-f compose.yaml)
if [ -f compose.apps.yaml ]; then
  files+=(-f compose.apps.yaml --profile apps)
fi

names=$(docker ps -a --filter "label=com.docker.compose.project=$project" \
  --filter "label=com.kitchen-daylight.stack=dev" --format '{{.Names}}')
if [ -n "$names" ]; then
  log "removing containers of project $project:"
  printf '%s\n' "$names" | sed 's/^/[kd]   /'
else
  log "no containers for project $project"
fi
log "volumes are kept"

if ! docker compose --env-file .env --env-file versions.env "${files[@]}" down --remove-orphans; then
  log "docker compose down failed" >&2
  exit 1
fi
log "stack is down"

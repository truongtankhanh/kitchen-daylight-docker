#!/usr/bin/env bash
# Removes the containers, the network and the volumes (pgdata, s3data) of the dev stack, so the next
# scripts/up.sh starts from an empty data directory and the init scripts run again.
# Contract: docs/4-scripts-contract.md. Exit codes: 0 ok, 1 failed, 2 usage error or missing prerequisite,
# 3 refused for safety (confirmation missing or wrong).
set -euo pipefail

CONFIRMATION='reset kd-docker'

usage() {
  cat <<'EOF'
Usage: scripts/reset.sh [--yes]

Deletes ALL data of this project: runs "docker compose down -v --remove-orphans", which removes the
containers, the network and the named volumes (pgdata, s3data). It never touches other projects.
The list of what will be removed is printed first.

  --yes    skip the typed confirmation (for scripted use)
  --help   show this text

Without --yes you must type exactly: reset kd-docker
Anything else (including empty input or no terminal) removes nothing and exits 3.

Exit codes: 0 ok, 1 docker compose down failed, 2 usage error, no .env, Docker not running,
3 not confirmed.
EOF
}

log() { printf '[kd] %s\n' "$*"; }

cd "$(dirname "${BASH_SOURCE[0]}")/.."

assume_yes=0
for arg in "$@"; do
  case "$arg" in
    -h|--help) usage; exit 0 ;;
    --yes) assume_yes=1 ;;
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

project_filter="label=com.docker.compose.project=$project"
containers=$(docker ps -a --filter "$project_filter" --format '{{.Names}}')
volumes=$(docker volume ls --filter "$project_filter" --format '{{.Name}}')

if [ -z "$containers" ] && [ -z "$volumes" ]; then
  log "nothing to remove for project $project"
  exit 0
fi

log "reset will remove, for project $project only:"
if [ -n "$volumes" ]; then
  printf '%s\n' "$volumes" | sed 's/^/[kd]   volume    /'
else
  log "  (no volumes)"
fi
if [ -n "$containers" ]; then
  printf '%s\n' "$containers" | sed 's/^/[kd]   container /'
fi
log "  plus the project network and any orphan containers"

if [ "$assume_yes" -ne 1 ]; then
  printf '[kd] this deletes the data above and cannot be undone. Type "%s" to continue: ' "$CONFIRMATION"
  answer=""
  read -r answer || answer=""
  if [ "$answer" != "$CONFIRMATION" ]; then
    printf '\n'
    log "not confirmed; nothing was removed" >&2
    exit 3
  fi
fi

if ! docker compose --env-file .env --env-file versions.env "${files[@]}" down -v --remove-orphans; then
  log "docker compose down -v failed" >&2
  exit 1
fi

remaining=$(docker volume ls --filter "$project_filter" --format '{{.Name}}')
log "removed:"
for v in $volumes; do
  case "
$remaining
" in
    *"
$v
"*) log "  volume $v STILL EXISTS" >&2; status=1 ;;
    *) log "  volume $v" ;;
  esac
done
for c in $containers; do
  log "  container $c"
done
if [ "${status:-0}" -ne 0 ]; then
  exit 1
fi
log "reset done; run scripts/up.sh to start from an empty database"

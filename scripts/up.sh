#!/usr/bin/env bash
# Starts the dependency stack, waits until it is healthy and prints the connection variables.
# Contract: docs/4-scripts-contract.md. Exit codes: 0 ok, 1 failed, 2 usage error or missing prerequisite.
set -euo pipefail

MIN_COMPOSE=2.24.1
MIN_ENGINE=20.10.23

usage() {
  cat <<EOF
Usage: scripts/up.sh [--apps] [--no-wait] [--build]

Starts the dependency stack (postgres, mailpit, s3 and the one-shot s3-init), then runs
scripts/wait-healthy.sh and scripts/print-env.sh. Data volumes are kept. Running it again on a
running stack changes nothing. The postgres image is built only when it does not exist yet.

  --apps       also start profile "apps" (needs compose.apps.yaml, which comes in phase 3)
  --no-wait    do not wait for the services to become healthy
  --build      rebuild the postgres image, after a change to postgres/Dockerfile or to
               POSTGRES_IMAGE / POSTGIS_PACKAGE_VERSION in versions.env. This recreates the
               postgres container (a rebuild gives the image a new digest, so it is not the default)
  --help       show this text

Minimum versions: Docker Engine $MIN_ENGINE, Docker Compose $MIN_COMPOSE (the "docker compose"
plugin, not docker-compose v1), bash 3.2, curl 7.75.0 (for the manual S3 checks).

Exit codes: 0 ok, 1 start or health failed, 2 usage error, no .env, Docker missing or too old.
EOF
}

log() { printf '[kd] %s\n' "$*"; }

# clean_version <text>: "v2.38.2-desktop.1" -> "2.38.2"
clean_version() {
  local v=${1#v}
  v=${v%%[!0-9.]*}
  printf '%s' "$v"
}

# version_ge <a> <b>: true when dotted version a >= b (each part below 1000, up to three parts)
version_ge() {
  local a1 a2 a3 b1 b2 b3
  IFS=. read -r a1 a2 a3 <<< "$1"
  IFS=. read -r b1 b2 b3 <<< "$2"
  [ $(( ${a1:-0} * 1000000 + ${a2:-0} * 1000 + ${a3:-0} )) -ge $(( ${b1:-0} * 1000000 + ${b2:-0} * 1000 + ${b3:-0} )) ]
}

# check_min <what> <found text> <minimum>
check_min() {
  local found
  found=$(clean_version "$2")
  if [ -z "$found" ]; then
    log "warning: cannot read the $1 version ('$2'); the minimum is $3" >&2
    return 0
  fi
  if ! version_ge "$found" "$3"; then
    log "$1 $found is older than the minimum $3" >&2
    exit 2
  fi
}

cd "$(dirname "${BASH_SOURCE[0]}")/.."

apps=0
wait_health=1
up_args=(-d)
for arg in "$@"; do
  case "$arg" in
    -h|--help) usage; exit 0 ;;
  esac
done
for arg in "$@"; do
  case "$arg" in
    --apps) apps=1 ;;
    --no-wait) wait_health=0 ;;
    --build) up_args+=(--build) ;;
    *) log "unknown argument: $arg" >&2; usage >&2; exit 2 ;;
  esac
done

if [ ! -f .env ]; then
  log ".env not found; run scripts/init-env.sh <slot>" >&2
  exit 2
fi

files=(-f compose.yaml)
if [ "$apps" = 1 ]; then
  if [ ! -f compose.apps.yaml ]; then
    log "compose.apps.yaml does not exist yet (the apps profile is added in phase 3)" >&2
    exit 2
  fi
  files+=(-f compose.apps.yaml --profile apps)
fi

if ! command -v docker >/dev/null 2>&1; then
  log "docker not found" >&2
  exit 2
fi
if ! docker info >/dev/null 2>&1; then
  log "Docker is not running" >&2
  exit 2
fi
check_min "Docker Compose" "$(docker compose version --short 2>/dev/null || true)" "$MIN_COMPOSE"
check_min "Docker Engine" "$(docker version --format '{{.Server.Version}}' 2>/dev/null || true)" "$MIN_ENGINE"

# Plain "docker compose" reads only .env; versions.env must be passed explicitly.
log "starting the stack (up ${up_args[*]})"
if ! docker compose --env-file .env --env-file versions.env "${files[@]}" up "${up_args[@]}"; then
  log "docker compose up failed" >&2
  exit 1
fi

if [ "$wait_health" = 1 ]; then
  scripts/wait-healthy.sh
fi
scripts/print-env.sh

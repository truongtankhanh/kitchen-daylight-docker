#!/usr/bin/env bash
# Waits until the dev stack is ready: every container with a health check is "healthy" and every
# container without one (a one-shot job) has exited 0. Contract: docs/4-scripts-contract.md.
# Exit codes: 0 ready, 1 failed or timed out, 2 usage error or missing prerequisite.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/wait-healthy.sh [--timeout <seconds>]

Polls the containers of the dev stack (project and label com.kitchen-daylight.stack=dev) until
every long-running service is healthy and every one-shot job has exited 0. It stops at the first
failed container. On failure or timeout it prints the last log lines of the containers involved.

  --timeout <s>   give up after this many seconds (default 90)
  --help          show this text

Exit codes: 0 ready, 1 failed or timed out, 2 usage error, no .env, Docker not running, no containers.
EOF
}

log() { printf '[kd] %s\n' "$*"; }

cd "$(dirname "${BASH_SOURCE[0]}")/.."

timeout=90
while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --timeout)
      if [ "$#" -lt 2 ]; then log "--timeout needs a number of seconds" >&2; exit 2; fi
      timeout=$2
      shift 2
      ;;
    *) log "unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done
case "$timeout" in
  ''|*[!0-9]*) log "--timeout must be a whole number of seconds, got: $timeout" >&2; exit 2 ;;
esac
if [ "$timeout" -lt 1 ]; then log "--timeout must be at least 1" >&2; exit 2; fi

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

list_ids() {
  docker ps -a -q \
    --filter "label=com.docker.compose.project=$project" \
    --filter "label=com.kitchen-daylight.stack=dev"
}

# Prints: <service> <state> <health or "none"> <exit code>
inspect_line() {
  docker inspect --format '{{index .Config.Labels "com.docker.compose.service"}} {{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}} {{.State.ExitCode}}' "$1"
}

# Prints ok, wait or fail for: <state> <health> <exit code>.
# A container with a health check is a long-running service; one without is a one-shot job.
classify() {
  case "$1" in
    running)
      case "$2" in
        healthy) echo ok ;;
        none|starting) echo wait ;;
        *) echo fail ;;
      esac
      ;;
    exited)
      if [ "$2" = none ] && [ "$3" = 0 ]; then echo ok; else echo fail; fi
      ;;
    created|restarting|paused) echo wait ;;
    *) echo fail ;;
  esac
}

show_logs() {
  local id
  for id in "$@"; do
    log "last log lines of $(docker inspect --format '{{index .Config.Labels "com.docker.compose.service"}}' "$id"):"
    docker logs --tail 20 "$id" 2>&1 | sed 's/^/[kd]   /' || true
  done
}

deadline=$((SECONDS + timeout))
last_pending="-"
while :; do
  ids=$(list_ids)
  if [ -z "$ids" ]; then
    log "no containers for project $project; run scripts/up.sh" >&2
    exit 2
  fi
  pending=""
  pending_ids=""
  failed=""
  failed_ids=""
  for id in $ids; do
    IFS=' ' read -r svc state health code <<< "$(inspect_line "$id")"
    case "$(classify "$state" "$health" "$code")" in
      wait) pending="$pending $svc"; pending_ids="$pending_ids $id" ;;
      fail) failed="$failed $svc($state,$health,exit $code)"; failed_ids="$failed_ids $id" ;;
    esac
  done
  if [ -n "$failed" ]; then
    log "failed:$failed" >&2
    # shellcheck disable=SC2086
    show_logs $failed_ids >&2
    exit 1
  fi
  if [ -z "$pending" ]; then
    log "all services ready"
    exit 0
  fi
  if [ "$SECONDS" -ge "$deadline" ]; then
    log "timeout after ${timeout}s; still waiting for:$pending" >&2
    # shellcheck disable=SC2086
    show_logs $pending_ids >&2
    exit 1
  fi
  if [ "$pending" != "$last_pending" ]; then
    log "waiting for:$pending"
    last_pending=$pending
  fi
  sleep 1
done

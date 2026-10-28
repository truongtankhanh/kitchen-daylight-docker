#!/usr/bin/env bash
# One line per service: state, health and published port. Contract: docs/4-scripts-contract.md.
# Exit codes: 0 no service is unhealthy, 1 a service is unhealthy or the stack is down, 2 usage/prerequisite.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/status.sh

Prints one line per container of the dev stack: service, state, health, published ports.
A container without a health check is a one-shot job and shows "-" as health.

  --help   show this text

Exit codes: 0 nothing is unhealthy; 1 a service is unhealthy or stopped, or there are no containers;
2 usage error, no .env, Docker not running.
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

ids=$(docker ps -a -q \
  --filter "label=com.docker.compose.project=$project" \
  --filter "label=com.kitchen-daylight.stack=dev")
if [ -z "$ids" ]; then
  log "no containers for project $project; run scripts/up.sh" >&2
  exit 1
fi

# classify <state> <health> <exit code>: ok, wait or fail (same rule as wait-healthy.sh)
classify() {
  case "$1" in
    running)
      case "$2" in
        healthy|none|starting) echo ok ;;
        *) echo fail ;;
      esac
      ;;
    exited)
      if [ "$2" = none ] && [ "$3" = 0 ]; then echo ok; else echo fail; fi
      ;;
    created|restarting|paused) echo ok ;;
    *) echo fail ;;
  esac
}

unhealthy=0
for id in $ids; do
  IFS=' ' read -r svc state health code <<< "$(docker inspect --format '{{index .Config.Labels "com.docker.compose.service"}} {{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}} {{.State.ExitCode}}' "$id")"
  ports=$(docker inspect --format '{{range $p, $b := .NetworkSettings.Ports}}{{if $b}}{{(index $b 0).HostIp}}:{{(index $b 0).HostPort}}->{{$p}} {{end}}{{end}}' "$id")
  shown_state=$state
  if [ "$state" = exited ]; then shown_state="exited($code)"; fi
  shown_health=$health
  if [ "$health" = none ]; then shown_health="-"; fi
  printf '[kd] %-10s %-12s %-10s %s\n' "$svc" "$shown_state" "$shown_health" "${ports:--}"
  if [ "$(classify "$state" "$health" "$code")" = fail ]; then
    unhealthy=1
  fi
done

if [ "$unhealthy" = 1 ]; then
  log "at least one service is unhealthy or stopped" >&2
  exit 1
fi

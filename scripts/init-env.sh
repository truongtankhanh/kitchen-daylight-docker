#!/usr/bin/env bash
# Writes .env (dev) and .env.test (test stack, ports +5) from .env.example for a port slot.
# Contract: docs/4-scripts-contract.md. Exit codes: 0 ok, 2 usage, 3 refused for safety.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/init-env.sh [<slot>] [--force]

Writes .env and .env.test from .env.example. Every port is base + slot x 10;
.env.test adds 5 to every port, uses project kd-docker-test and APP_ENV=test.

  <slot>     port slot, 0 to 99 (default 2; the maintainer's other stacks use 0 and 1)
  --force    overwrite an existing .env or .env.test
  --help     show this text

Environment:
  KD_ENV_DIR   folder to write the files to (default: the repository root)

Exit codes: 0 ok, 2 usage error or missing template, 3 refused (file exists
without --force, or a port of the slot is already listening).
EOF
}

log() { printf '[kd] %s\n' "$*"; }

# Resolve KD_ENV_DIR against the caller's folder before changing directory.
env_dir=${KD_ENV_DIR:-}
if [ -n "$env_dir" ]; then
  case "$env_dir" in
    /*) ;;
    *) env_dir="$PWD/$env_dir" ;;
  esac
fi
cd "$(dirname "${BASH_SOURCE[0]}")/.."
[ -n "$env_dir" ] || env_dir=$PWD

slot=""
force=0
for arg in "$@"; do
  case "$arg" in
    -h|--help) usage; exit 0 ;;
  esac
done
for arg in "$@"; do
  case "$arg" in
    --force) force=1 ;;
    -*) log "unknown option: $arg" >&2; usage >&2; exit 2 ;;
    *)
      if [ -n "$slot" ]; then
        log "only one slot may be given" >&2; usage >&2; exit 2
      fi
      slot=$arg
      ;;
  esac
done

[ -n "$slot" ] || slot=2
case "$slot" in
  *[!0-9]*) log "slot must be a number from 0 to 99, got: $slot" >&2; exit 2 ;;
esac
slot=$((10#$slot))
if [ "$slot" -gt 99 ]; then
  log "slot must be a number from 0 to 99, got: $slot" >&2
  exit 2
fi

template=.env.example
if [ ! -f "$template" ]; then
  log "missing $template in $PWD" >&2
  exit 2
fi

PORT_KEYS="POSTGRES_PORT MAILPIT_SMTP_PORT MAILPIT_UI_PORT S3_PORT S3_CONSOLE_PORT API_PORT CADDY_PORT"

base_port() {
  case "$1" in
    POSTGRES_PORT) echo 5432 ;;
    MAILPIT_SMTP_PORT) echo 1025 ;;
    MAILPIT_UI_PORT) echo 8025 ;;
    S3_PORT) echo 9000 ;;
    S3_CONSOLE_PORT) echo 9001 ;;
    API_PORT) echo 3000 ;;
    CADDY_PORT) echo 8000 ;;
    *) return 1 ;;
  esac
}

# render <output file> <port offset> <project> <app env> <database> <with caddy: 1|0>
render() {
  local out=$1 offset=$2 project=$3 app_env=$4 database=$5 with_caddy=$6
  local line key base
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      ''|'#'*) printf '%s\n' "$line"; continue ;;
    esac
    key=${line%%=*}
    case "$key" in
      KD_SLOT) printf 'KD_SLOT=%s\n' "$slot" ;;
      COMPOSE_PROJECT_NAME) printf 'COMPOSE_PROJECT_NAME=%s\n' "$project" ;;
      APP_ENV) printf 'APP_ENV=%s\n' "$app_env" ;;
      KD_DATABASE) printf 'KD_DATABASE=%s\n' "$database" ;;
      CADDY_PORT)
        if [ "$with_caddy" = 1 ]; then
          printf 'CADDY_PORT=%s\n' $((8000 + slot * 10 + offset))
        else
          printf '# CADDY_PORT is not used in the test stack\n'
        fi
        ;;
      *_PORT)
        if ! base=$(base_port "$key"); then
          log "no base port known for $key (update scripts/init-env.sh)" >&2
          exit 2
        fi
        printf '%s=%s\n' "$key" $((base + slot * 10 + offset))
        ;;
      *) printf '%s\n' "$line" ;;
    esac
  done < "$template" > "$out"
}

scanner=none
if command -v lsof >/dev/null 2>&1; then
  scanner=lsof
elif command -v ss >/dev/null 2>&1; then
  scanner=ss
fi

port_listening() {
  local out
  case "$scanner" in
    lsof) lsof -nP -iTCP:"$1" -sTCP:LISTEN >/dev/null 2>&1 ;;
    ss)
      out=$(ss -ltn "sport = :$1" 2>/dev/null || true)
      [ -n "$(printf '%s\n' "$out" | sed -n '2p')" ]
      ;;
    *) return 1 ;;
  esac
}

env_file="$env_dir/.env"
test_file="$env_dir/.env.test"

if [ "$force" != 1 ]; then
  for f in "$env_file" "$test_file"; do
    if [ -e "$f" ]; then
      log "$f already exists; use --force to overwrite" >&2
      exit 3
    fi
  done
fi

if [ "$scanner" = none ]; then
  log "warning: neither lsof nor ss found; the port check is skipped" >&2
else
  busy=""
  for key in $PORT_KEYS; do
    base=$(base_port "$key")
    port=$((base + slot * 10))
    if port_listening "$port"; then busy="$busy $port"; fi
    if [ "$key" != CADDY_PORT ]; then
      port=$((port + 5))
      if port_listening "$port"; then busy="$busy $port"; fi
    fi
  done
  if [ -n "$busy" ]; then
    log "slot $slot refused: already listening:$busy" >&2
    log "pick another slot (init-env.sh <slot>) or stop the stack that uses these ports" >&2
    exit 3
  fi
fi

mkdir -p "$env_dir"
tmp_env=""
tmp_test=""
trap 'rm -f "$tmp_env" "$tmp_test"' EXIT
tmp_env=$(mktemp "$env_dir/.env.XXXXXX")
tmp_test=$(mktemp "$env_dir/.env.test.XXXXXX")

render "$tmp_env" 0 kd-docker dev kd_dev 1
render "$tmp_test" 5 kd-docker-test test kd_test 0
mv "$tmp_env" "$env_file"
mv "$tmp_test" "$test_file"

log "wrote $env_file (project kd-docker, slot $slot)"
log "wrote $test_file (project kd-docker-test, ports +5)"
log "registry row for docker-local/docs/PORT_REGISTRY.md (match its column order):"
printf '| %s | kitchen-daylight-docker | %s | - | - | - |\n' "$slot" $((5432 + slot * 10))

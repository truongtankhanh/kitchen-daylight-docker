#!/usr/bin/env bash
# Starts the end-to-end test stack (compose.test.yaml, project kd-docker-test), waits until it is ready and writes
# .env.test.out for the consumers (docs/5-test-stack-and-ci.md, 5.1). Contract: docs/4-scripts-contract.md.
# Exit codes: 0 ok, 1 start or health failed, 2 usage error or missing prerequisite, 3 refused for safety.
set -euo pipefail

WAIT_TIMEOUT=120
# The services of compose.test.yaml in start order (5.2). The first one that is not ready is the blocking one.
SERVICES="postgres s3 s3-init mailpit migrate seed api"

usage() {
  cat <<'EOF'
Usage: scripts/test-up.sh [--keep-env]

Starts the test stack (postgres on tmpfs with database kd_test, mailpit, s3 + s3-init, migrate, seed, api; ports
are the dev ports +5), then waits until every long-running service is healthy and migrate, seed and s3-init have
exited 0. Waiting is by polling the container state, never a fixed sleep; the deadline is 120 s.
Every start recreates the containers, so migrate and seed run again on empty data. Once the stack is ready it
creates kd_test_template from the seeded kd_test (scripts/test-reset-db.sh --create-template; a failure is only a
warning) and checks the services again, because that step terminates the API's database connections once.

If .env.test has no JWT keys, scripts/gen-dev-secrets.sh --test --force writes throw-away ones into it first.
The previous .env.test.out is removed before the start. On success a new one is written (ignored by git, mode
600) with the variables of scripts/print-env.sh --env-file .env.test, plus API_BASE_URL. On failure the last 50
log lines of the blocking service are printed and the stack is left as it is for inspection;
scripts/test-down.sh removes it.

Needs .env.test (scripts/init-env.sh <slot>). It never reads or touches .env or the dev stack.

KD_BIND_ADDRESS (optional, environment or .env.test; default 127.0.0.1) is the address the API port is published
on. Set it to 0.0.0.0 to reach the API from a phone on the LAN (Maestro); a warning is printed. Postgres, Mailpit
and S3 stay on 127.0.0.1 whatever it says. .env.test.out keeps API_BASE_URL on 127.0.0.1.

  --keep-env   keep an existing .env.test.out instead of removing and rewriting it
  --help       show this text

Exit codes: 0 ready, 1 failed or timed out, 2 usage error, no .env.test, bad KD_BIND_ADDRESS, Docker not running,
3 refused (APP_ENV is not test, or the project name does not end in -test).
EOF
}

log() { printf '[kd] %s\n' "$*"; }

cd "$(dirname "${BASH_SOURCE[0]}")/.."

keep_env=0
for arg in "$@"; do
  case "$arg" in
    -h|--help) usage; exit 0 ;;
  esac
done
for arg in "$@"; do
  case "$arg" in
    --keep-env) keep_env=1 ;;
    *) log "unknown argument: $arg" >&2; usage >&2; exit 2 ;;
  esac
done

if [ ! -f .env.test ]; then
  log ".env.test not found; run scripts/init-env.sh <slot>" >&2
  exit 2
fi
if [ ! -f compose.test.yaml ]; then
  log "compose.test.yaml not found" >&2
  exit 2
fi
# Compose lets a variable exported by the calling shell win over the env file, so load .env.test here.
set -a
# shellcheck source=/dev/null
. ./.env.test
set +a
project=${COMPOSE_PROJECT_NAME:-kd-docker-test}

if [ "${APP_ENV:-}" != test ]; then
  log "refused: APP_ENV is '${APP_ENV:-}' in .env.test, expected 'test'" >&2
  exit 3
fi
case "$project" in
  *-test) ;;
  *) log "refused: project '$project' does not end in -test; it must not be the dev project" >&2; exit 3 ;;
esac

for name in POSTGRES_PORT KD_DATABASE KD_MIGRATOR_PASSWORD KD_APP_PASSWORD MAILPIT_SMTP_PORT \
  MAILPIT_UI_PORT S3_PORT S3_ACCESS_KEY S3_SECRET_KEY API_PORT; do
  if [ -z "${!name:-}" ]; then
    log ".env.test is missing $name; run scripts/init-env.sh <slot> --force" >&2
    exit 2
  fi
done

# Opt-in for a Maestro run on a phone on the LAN: only the API port follows KD_BIND_ADDRESS (compose.test.yaml).
bind=${KD_BIND_ADDRESS:-127.0.0.1}
if ! [[ $bind =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
  log "KD_BIND_ADDRESS must be an IPv4 address, got: $bind" >&2
  exit 2
fi
if [ "$bind" != 127.0.0.1 ]; then
  log "WARNING: KD_BIND_ADDRESS=$bind publishes the API (port $API_PORT) beyond loopback: every host that can reach" >&2
  log "WARNING: this machine can call it, with the seeded test data and the placeholder admin credentials" >&2
fi

# The API refuses to start without signing keys (ADR-0003) and init-env.sh writes none. Generate throw-away ones
# once (values not shown); later runs reuse them. Regenerating all four never leaves a key pair half replaced.
if [ -z "${JWT_PRIVATE_KEY:-}" ] || [ -z "${JWT_PUBLIC_KEY:-}" ] || [ -z "${JWT_KEY_ID:-}" ]; then
  log "no JWT keys in .env.test; generating test keys"
  scripts/gen-dev-secrets.sh --test --force
  set -a
  # shellcheck source=/dev/null
  . ./.env.test
  set +a
fi

if ! command -v docker >/dev/null 2>&1; then
  log "docker not found" >&2
  exit 2
fi
if ! docker info >/dev/null 2>&1; then
  log "Docker is not running" >&2
  exit 2
fi

compose=(docker compose -p "$project" --env-file .env.test --env-file versions.env -f compose.test.yaml)

tmp_out=""
trap 'rm -f "$tmp_out"' EXIT

# Sets, for the services of the test project: failed / pending (text for the log) and the first failed and
# first pending service in start order, with its container id (empty when the container does not exist yet).
failed=""
failed_svc=""
failed_id=""
pending=""
pending_svc=""
pending_id=""
check_once() {
  local rows svc id state health code
  failed=""; failed_svc=""; failed_id=""
  pending=""; pending_svc=""; pending_id=""
  rows=$(docker ps -a \
    --filter "label=com.docker.compose.project=$project" \
    --filter "label=com.kitchen-daylight.stack=test" \
    --format '{{.ID}} {{.Label "com.docker.compose.service"}}')
  for svc in $SERVICES; do
    id=$(printf '%s\n' "$rows" | awk -v s="$svc" '$2 == s { print $1; exit }')
    if [ -z "$id" ]; then
      pending="$pending $svc"
      if [ -z "$pending_svc" ]; then pending_svc=$svc; fi
      continue
    fi
    # A container with a health check is a long-running service; one without is a one-shot job.
    IFS=' ' read -r state health code <<< "$(docker inspect --format \
      '{{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}} {{.State.ExitCode}}' \
      "$id" 2>/dev/null || true)"
    case "${state:-gone}" in
      running)
        case "$health" in
          healthy) ;;
          none|starting)
            pending="$pending $svc"
            if [ -z "$pending_svc" ]; then pending_svc=$svc; pending_id=$id; fi
            ;;
          *)
            failed="$failed $svc($state,$health)"
            if [ -z "$failed_svc" ]; then failed_svc=$svc; failed_id=$id; fi
            ;;
        esac
        ;;
      exited)
        if [ "$health" != none ] || [ "$code" != 0 ]; then
          failed="$failed $svc($state,$health,exit $code)"
          if [ -z "$failed_svc" ]; then failed_svc=$svc; failed_id=$id; fi
        fi
        ;;
      created|restarting|paused)
        pending="$pending $svc"
        if [ -z "$pending_svc" ]; then pending_svc=$svc; pending_id=$id; fi
        ;;
      *)
        failed="$failed $svc(${state:-gone})"
        if [ -z "$failed_svc" ]; then failed_svc=$svc; failed_id=$id; fi
        ;;
    esac
  done
}

# show_logs <service> <container id or empty>
show_logs() {
  if [ -z "$2" ]; then
    log "$1: container not created" >&2
    return 0
  fi
  log "last 50 log lines of $1:" >&2
  docker logs --tail 50 "$2" 2>&1 | sed 's/^/[kd]   /' >&2 || true
}

leave_stack() {
  log "the stack is left running for inspection; scripts/test-down.sh removes it" >&2
}

# A stale .env.test.out from an earlier run must not outlive a failed start (it is a generated, ignored file).
if [ "$keep_env" != 1 ] && [ -f .env.test.out ]; then
  rm -f .env.test.out
  log "removed the previous .env.test.out"
fi

# --force-recreate: the one-shot jobs (migrate, seed) must run again and postgres must start with empty tmpfs data,
# so every start is from a clean, seeded state, also after a failed run that was left for inspection.
log "starting the test stack (project $project)"
if ! "${compose[@]}" up -d --force-recreate --remove-orphans; then
  log "docker compose up failed" >&2
  check_once
  if [ -n "$failed_svc" ]; then
    log "failed:$failed" >&2
    show_logs "$failed_svc" "$failed_id"
  fi
  leave_stack
  exit 1
fi

# wait_ready: returns when every service is ready; on a failure or the deadline it reports and exits 1.
wait_ready() {
  local deadline last_pending
  deadline=$((SECONDS + WAIT_TIMEOUT))
  last_pending="-"
  while :; do
    check_once
    if [ -n "$failed" ]; then
      log "failed:$failed" >&2
      show_logs "$failed_svc" "$failed_id"
      leave_stack
      exit 1
    fi
    if [ -z "$pending" ]; then
      log "all services ready"
      return 0
    fi
    if [ "$SECONDS" -ge "$deadline" ]; then
      log "timeout after ${WAIT_TIMEOUT}s; still waiting for:$pending" >&2
      show_logs "$pending_svc" "$pending_id"
      leave_stack
      exit 1
    fi
    if [ "$pending" != "$last_pending" ]; then
      log "waiting for:$pending"
      last_pending=$pending
    fi
    sleep 1
  done
}

wait_ready

# Optional fast reset (docs/5-test-stack-and-ci.md, 5.1): copy the freshly seeded kd_test into kd_test_template.
# This terminates the API's database connections once, so the services are checked again afterwards. A failure
# here only costs the fast reset, not the stack, so it is a warning.
if scripts/test-reset-db.sh --create-template; then
  wait_ready
else
  log "warning: kd_test_template was not created; scripts/test-reset-db.sh will not work until it is" >&2
fi

if [ "$keep_env" = 1 ] && [ -f .env.test.out ]; then
  log "keeping the existing .env.test.out"
else
  tmp_out=$(mktemp .env.test.out.XXXXXX)
  # The variable list is print-env.sh's own (the contract with the monorepo), read from .env.test.
  scripts/print-env.sh --env-file .env.test > "$tmp_out"
  printf 'API_BASE_URL=http://127.0.0.1:%s\n' "$API_PORT" >> "$tmp_out"
  mv "$tmp_out" .env.test.out
  tmp_out=""
  log "wrote .env.test.out"
fi
log "test stack is ready; scripts/test-down.sh removes it"

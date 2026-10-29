#!/usr/bin/env bash
# Runs the API image's seed command as a one-off container against the dev database (R10: seeds are not
# reimplemented here). Contract: docs/4-scripts-contract.md; the command is assumed in docs/api-contract.md.
# Exit codes: 0 ok, 1 the seed command failed, 2 usage error or missing prerequisite (no .env, Docker not
# running, stack down, API image absent), 3 refused for safety (demo outside APP_ENV=dev).
set -euo pipefail

DEFAULT_SEED_CMD='node dist/cli.js seed'

usage() {
  cat <<'EOF'
Usage: scripts/seed.sh reference|business|demo [--commit]

Runs "<API_SEED_CMD> <mode>" in a one-off container of the API image (docker compose run --rm, service
migrate), connected to the dev database as kd_migrator. The seed tool is a dry run by default; --commit
is passed to it only when you pass --commit here.

  reference   reference data (provinces, roles, settings, ...)
  business    the owner's menu and branches, or the synthetic example
  demo        synthetic orders; refused unless APP_ENV=dev in .env

  --commit    let the seed tool write (without it, nothing is written)
  --help      show this text

API_SEED_CMD (optional, in .env) replaces the default "node dist/cli.js seed" (docs/api-contract.md).
It does not start the stack: run scripts/up.sh --apps first (the API image must be present locally).

Exit codes: 0 ok, 1 the seed command failed, 2 usage error, no .env, Docker not running, stack down, API image
absent, 3 refused (demo while APP_ENV is not dev).
EOF
}

log() { printf '[kd] %s\n' "$*"; }

cd "$(dirname "${BASH_SOURCE[0]}")/.."

mode=""
commit=0
for arg in "$@"; do
  case "$arg" in
    -h|--help) usage; exit 0 ;;
    --commit) commit=1 ;;
    reference|business|demo)
      if [ -n "$mode" ]; then
        log "give one mode only (got $mode and $arg)" >&2
        exit 2
      fi
      mode=$arg
      ;;
    *) log "unknown argument: $arg" >&2; usage >&2; exit 2 ;;
  esac
done
if [ -z "$mode" ]; then
  log "missing mode: reference, business or demo" >&2
  usage >&2
  exit 2
fi

if [ ! -f .env ]; then
  log ".env not found; run scripts/init-env.sh <slot>" >&2
  exit 2
fi
set -a
# shellcheck source=/dev/null
. ./.env
set +a

if [ "$mode" = demo ] && [ "${APP_ENV:-}" != dev ]; then
  log "refused: demo data is only seeded when APP_ENV=dev (it is '${APP_ENV:-}' in .env)" >&2
  exit 3
fi

if ! docker info >/dev/null 2>&1; then
  log "Docker is not running" >&2
  exit 2
fi
if [ ! -f compose.apps.yaml ]; then
  log "compose.apps.yaml not found; the apps profile is missing" >&2
  exit 2
fi

compose=(docker compose --env-file .env --env-file versions.env -f compose.yaml -f compose.apps.yaml --profile apps)

running=$("${compose[@]}" ps --status running --services 2>/dev/null) || running=""
case "
$running
" in
  *"
postgres
"*) ;;
  *) log "the stack is not running (postgres is down); run scripts/up.sh --apps first" >&2; exit 2 ;;
esac

# The image comes from compose.apps.yaml, so the name is read from the resolved configuration, not repeated here.
images=$("${compose[@]}" config --images 2>/dev/null) || {
  log "docker compose config failed; check .env and versions.env" >&2
  exit 2
}
image=""
for candidate in $images; do
  case "$candidate" in
    */kitchen-daylight-api:*) image=$candidate; break ;;
  esac
done
if [ -z "$image" ]; then
  log "no kitchen-daylight-api image in the resolved configuration" >&2
  exit 2
fi
if ! docker image inspect "$image" >/dev/null 2>&1; then
  log "the API image is not present locally: $image" >&2
  log "it is published by the monorepo (docs/api-contract.md); set API_TAG in versions.env and run scripts/up.sh --apps" >&2
  exit 2
fi

seed_cmd=${API_SEED_CMD:-$DEFAULT_SEED_CMD}
# The command may hold several words (for example "node dist/cli.js seed"); split it on purpose.
read -r -a cmd <<< "$seed_cmd"
cmd+=("$mode")
if [ "$commit" -eq 1 ]; then
  cmd+=(--commit)
  log "seeding $mode with --commit (the seed tool writes to the dev database)"
else
  log "seeding $mode as a dry run (the seed tool is asked not to write)"
fi

# Service "migrate" is the same image with the kd_migrator URL already in its environment, so the password
# is not passed on a command line. --no-deps: this script never starts anything else.
if ! "${compose[@]}" run --rm --no-deps -T migrate "${cmd[@]}"; then
  log "the seed command failed (exit above)" >&2
  exit 1
fi
if [ "$commit" -eq 1 ]; then
  log "seed $mode committed"
else
  log "seed $mode dry run finished; add --commit to write"
fi

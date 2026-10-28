#!/usr/bin/env bash
# Prints the connection variables for the apps (the stable list of docs/4-scripts-contract.md, 4.3).
# Does not need Docker. Exit codes: 0 ok, 2 usage error or missing/incomplete .env.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/print-env.sh [--shell]

Prints KEY=value lines built from .env. The variable names are a contract with the monorepo.
Passwords are the local placeholders of .env and must be URL-safe (they are placed in URLs as written).

  --shell   print "export KEY='value'" lines, ready for eval "$(scripts/print-env.sh --shell)"
  --help    show this text

Exit codes: 0 ok, 2 usage error, no .env, or a variable missing from .env.
EOF
}

log() { printf '[kd] %s\n' "$*"; }

cd "$(dirname "${BASH_SOURCE[0]}")/.."

shell_mode=0
for arg in "$@"; do
  case "$arg" in
    -h|--help) usage; exit 0 ;;
    --shell) shell_mode=1 ;;
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

for name in POSTGRES_PORT KD_DATABASE KD_MIGRATOR_PASSWORD KD_APP_PASSWORD MAILPIT_SMTP_PORT \
  MAILPIT_UI_PORT S3_PORT S3_ACCESS_KEY S3_SECRET_KEY APP_ENV; do
  if [ -z "${!name:-}" ]; then
    log ".env is missing $name; run scripts/init-env.sh <slot> --force" >&2
    exit 2
  fi
done

# shq <value>: single-quote a value for a shell
shq() {
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

# emit <name> <value>
emit() {
  if [ "$shell_mode" = 1 ]; then
    printf 'export %s=%s\n' "$1" "$(shq "$2")"
  else
    printf '%s=%s\n' "$1" "$2"
  fi
}

emit DATABASE_URL_MIGRATOR "postgres://kd_migrator:${KD_MIGRATOR_PASSWORD}@127.0.0.1:${POSTGRES_PORT}/${KD_DATABASE}"
emit DATABASE_URL_APP "postgres://kd_app:${KD_APP_PASSWORD}@127.0.0.1:${POSTGRES_PORT}/${KD_DATABASE}"
emit MAIL_SMTP_HOST 127.0.0.1
emit MAIL_SMTP_PORT "$MAILPIT_SMTP_PORT"
emit MAIL_UI_URL "http://127.0.0.1:${MAILPIT_UI_PORT}"
emit STORAGE_S3_ENDPOINT "http://127.0.0.1:${S3_PORT}"
emit STORAGE_S3_FORCE_PATH_STYLE true
emit STORAGE_S3_ACCESS_KEY "$S3_ACCESS_KEY"
emit STORAGE_S3_SECRET_KEY "$S3_SECRET_KEY"
emit STORAGE_S3_BUCKET_MEDIA "kd-${APP_ENV}-media"
emit STORAGE_S3_BUCKET_PRIVATE "kd-${APP_ENV}-private"
emit APP_ENV "$APP_ENV"

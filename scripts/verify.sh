#!/usr/bin/env bash
# Runtime checks of a running dev stack (docs/5-test-stack-and-ci.md, section 5.3). Stops at the first failed check.
# Contract: docs/4-scripts-contract.md. Exit codes: 0 all checks passed, 1 a check failed,
# 2 usage error or missing prerequisite (no .env, Docker not running, stack not running, no curl).
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/verify.sh

Runs ten checks against the running dev stack and prints "PASS <name>" or "FAIL <name>: <reason>"
for each; it stops at the first failure.

   1 postgres-login      kd_migrator and kd_app can connect
   2 extensions          postgis, pg_trgm, unaccent, citext are installed
   3 uuidv7              uuidv7() works (PostgreSQL 18)
   4 app-no-ddl          kd_app cannot run CREATE TABLE
   5 migrator-ddl        kd_migrator creates a table, kd_app can INSERT but not DELETE
   6 postgis             ST_AsText(ST_Point(...)) works
   7 mailpit             a message sent over SMTP is read back from the UI API
   8 s3                  put, head, get, delete of an object in kd-dev-media; both dev buckets are listed
   9 ports-loopback      every published port is bound to 127.0.0.1
  10 app-env-dev         no running container has APP_ENV other than dev

Everything the checks create (table, message, S3 object) is removed again, also after a failure.
The stack is never started by this script.

  --help   show this text

Exit codes: 0 all passed, 1 a check failed, 2 usage error, no .env, Docker not running, stack not running,
curl missing.
EOF
}

log() { printf '[kd] %s\n' "$*"; }
pass() { printf 'PASS %s\n' "$1"; }
fail() { printf 'FAIL %s: %s\n' "$1" "$2"; exit 1; }

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

for var in KD_DATABASE MAILPIT_SMTP_PORT MAILPIT_UI_PORT S3_PORT S3_ACCESS_KEY S3_SECRET_KEY; do
  if [ -z "${!var:-}" ]; then
    log "$var is not set in .env" >&2
    exit 2
  fi
done

if ! command -v curl >/dev/null 2>&1; then
  log "curl is required on the host" >&2
  exit 2
fi

if ! docker info >/dev/null 2>&1; then
  log "Docker is not running" >&2
  exit 2
fi

files=(-f compose.yaml)
if [ -f compose.apps.yaml ]; then
  files+=(-f compose.apps.yaml --profile apps)
fi
compose=(docker compose --env-file .env --env-file versions.env "${files[@]}")

running=$("${compose[@]}" ps --status running --services 2>/dev/null) || running=""
for svc in postgres mailpit s3; do
  case "
$running
" in
    *"
$svc
"*) ;;
    *) log "service $svc is not running; run scripts/up.sh" >&2; exit 2 ;;
  esac
done

media_bucket=kd-dev-media
private_bucket=kd-dev-private
s3_region=us-east-1
s3_url="http://127.0.0.1:$S3_PORT"
smtp_from=verify@kitchendaylight.example
smtp_to=dev@kitchendaylight.example
mailpit_api="http://127.0.0.1:$MAILPIT_UI_PORT/api/v1"
run_id="kd-verify-$$-$(date +%s)"

# pg <role> <sql>: runs one statement inside the postgres container over TCP, authenticating with the
# role's password from the container's own environment (the password never leaves the container).
# Prints stdout and stderr together; the exit status is psql's.
pg() {
  local pwvar
  case "$1" in
    kd_migrator) pwvar=KD_MIGRATOR_PASSWORD ;;
    kd_app) pwvar=KD_APP_PASSWORD ;;
    *) return 2 ;;
  esac
  # The single-quoted script is expanded by the shell inside the container, on purpose.
  # shellcheck disable=SC2016
  "${compose[@]}" exec -T postgres sh -c \
    'export PGPASSWORD="$(printenv "$1")"; exec psql -X -At -v ON_ERROR_STOP=1 -h 127.0.0.1 -U "$2" -d "$3" -c "$4"' \
    sh "$pwvar" "$1" "$KD_DATABASE" "$2" 2>&1
}

# s3_code <curl args...>: prints the HTTP status of a signed request (000 when curl itself failed).
s3_code() {
  curl -s -o /dev/null -w '%{http_code}' --max-time 10 \
    --aws-sigv4 "aws:amz:$s3_region:s3" --user "$S3_ACCESS_KEY:$S3_SECRET_KEY" \
    -H 'x-amz-content-sha256: UNSIGNED-PAYLOAD' "$@" || true
}

mail_subject=""
s3_key=""

mail_delete() {
  curl -s -o /dev/null -w '%{http_code}' --max-time 10 -X DELETE -G \
    --data-urlencode "query=subject:\"$mail_subject\"" "$mailpit_api/search" || true
}

# Runs on every exit, so the tables, the message and the object do not outlive a failed check.
cleanup() {
  "${compose[@]}" exec -T postgres psql -X -q -U postgres -d "$KD_DATABASE" \
    -c 'DROP TABLE IF EXISTS kd_verify_app_ddl, kd_verify_priv' >/dev/null 2>&1 || true
  if [ -n "$mail_subject" ]; then
    mail_delete >/dev/null
  fi
  if [ -n "$s3_key" ]; then
    s3_code -X DELETE "$s3_url/$media_bucket/$s3_key" >/dev/null
  fi
}
trap cleanup EXIT
trap 'exit 1' INT TERM
cleanup

# 1 postgres-login
name=postgres-login
for role in kd_migrator kd_app; do
  out=$(pg "$role" 'SELECT current_user') || fail "$name" "$role cannot connect: $out"
  [ "$out" = "$role" ] || fail "$name" "connected as '$out' instead of $role"
done
pass "$name"

# 2 extensions
name=extensions
out=$(pg kd_migrator 'SELECT extname FROM pg_extension') || fail "$name" "$out"
for ext in postgis pg_trgm unaccent citext; do
  printf '%s\n' "$out" | grep -qx "$ext" || fail "$name" "extension $ext is missing"
done
pass "$name"

# 3 uuidv7
name=uuidv7
out=$(pg kd_migrator 'SELECT uuidv7()') || fail "$name" "$out"
uuid_re='^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[0-9a-f]{4}-[0-9a-f]{12}$'
[[ $out =~ $uuid_re ]] || fail "$name" "unexpected result: $out"
pass "$name"

# 4 app-no-ddl
name=app-no-ddl
if out=$(pg kd_app 'CREATE TABLE kd_verify_app_ddl (id integer)'); then
  fail "$name" "kd_app created a table"
fi
printf '%s\n' "$out" | grep -qi 'permission denied' || fail "$name" "expected a permission error, got: $out"
pass "$name"

# 5 migrator-ddl
name=migrator-ddl
out=$(pg kd_migrator 'CREATE TABLE kd_verify_priv (id integer PRIMARY KEY, note text)') \
  || fail "$name" "kd_migrator cannot create a table: $out"
out=$(pg kd_app "INSERT INTO kd_verify_priv (id, note) VALUES (1, 'kd-verify')") \
  || fail "$name" "kd_app cannot INSERT (default privileges missing?): $out"
if out=$(pg kd_app 'DELETE FROM kd_verify_priv'); then
  fail "$name" "kd_app could DELETE"
fi
printf '%s\n' "$out" | grep -qi 'permission denied' || fail "$name" "expected a permission error on DELETE, got: $out"
out=$(pg kd_migrator 'DROP TABLE kd_verify_priv') || fail "$name" "cannot drop the test table: $out"
pass "$name"

# 6 postgis
name=postgis
out=$(pg kd_migrator 'SELECT ST_AsText(ST_Point(106.7, 10.77))') || fail "$name" "$out"
[ "$out" = 'POINT(106.7 10.77)' ] || fail "$name" "unexpected result: $out"
pass "$name"

# 7 mailpit
name=mailpit
mail_subject="$run_id"
out=$(printf 'From: %s\r\nTo: %s\r\nSubject: %s\r\n\r\nkd verify message\r\n' "$smtp_from" "$smtp_to" "$mail_subject" \
  | curl -sS --max-time 10 --url "smtp://127.0.0.1:$MAILPIT_SMTP_PORT" \
      --mail-from "$smtp_from" --mail-rcpt "$smtp_to" -T - 2>&1) \
  || fail "$name" "SMTP send to port $MAILPIT_SMTP_PORT failed: $out"
out=$(curl -sS --max-time 10 -G --data-urlencode "query=subject:\"$mail_subject\"" "$mailpit_api/search" 2>&1) \
  || fail "$name" "UI API on port $MAILPIT_UI_PORT failed: $out"
case "$out" in
  *"\"Subject\":\"$mail_subject\""*) ;;
  *) fail "$name" "the sent message was not found through the UI API" ;;
esac
code=$(mail_delete)
[ "$code" = 200 ] || fail "$name" "deleting the message returned HTTP $code"
out=$(curl -sS --max-time 10 -G --data-urlencode "query=subject:\"$mail_subject\"" "$mailpit_api/search" 2>&1) \
  || fail "$name" "UI API on port $MAILPIT_UI_PORT failed: $out"
case "$out" in
  *"\"Subject\":\"$mail_subject\""*) fail "$name" "the message is still there after the delete" ;;
esac
mail_subject=""
pass "$name"

# 8 s3
name=s3
s3_key="$run_id.txt"
object="$s3_url/$media_bucket/$s3_key"
code=$(s3_code -X PUT --data-binary "$run_id" "$object")
[ "$code" = 200 ] || fail "$name" "PUT returned HTTP $code"
code=$(s3_code -I "$object")
[ "$code" = 200 ] || fail "$name" "HEAD returned HTTP $code"
out=$(curl -s --max-time 10 --aws-sigv4 "aws:amz:$s3_region:s3" --user "$S3_ACCESS_KEY:$S3_SECRET_KEY" \
  -H 'x-amz-content-sha256: UNSIGNED-PAYLOAD' "$object" || true)
[ "$out" = "$run_id" ] || fail "$name" "GET returned a different body"
code=$(s3_code -X DELETE "$object")
case "$code" in
  200|204) ;;
  *) fail "$name" "DELETE returned HTTP $code" ;;
esac
code=$(s3_code -I "$object")
[ "$code" = 404 ] || fail "$name" "HEAD after DELETE returned HTTP $code instead of 404"
s3_key=""
out=$(curl -s --max-time 10 --aws-sigv4 "aws:amz:$s3_region:s3" --user "$S3_ACCESS_KEY:$S3_SECRET_KEY" \
  -H 'x-amz-content-sha256: UNSIGNED-PAYLOAD' "$s3_url/" || true)
for bucket in "$media_bucket" "$private_bucket"; do
  case "$out" in
    *"<Name>$bucket</Name>"*) ;;
    *) fail "$name" "bucket $bucket is not listed" ;;
  esac
done
pass "$name"

# 9 ports-loopback
name=ports-loopback
ps_json=$("${compose[@]}" ps --format json 2>&1) || fail "$name" "docker compose ps failed: $ps_json"
publishers=$(printf '%s\n' "$ps_json" \
  | grep -o '"URL":"[^"]*","TargetPort":[0-9]*,"PublishedPort":[0-9]*' || true)
published=$(printf '%s\n' "$publishers" | grep -c '"PublishedPort":[1-9]' || true)
[ "$published" -gt 0 ] || fail "$name" "no published port found in docker compose ps output"
exposed=$(printf '%s\n' "$publishers" | grep '"PublishedPort":[1-9]' | grep -v '^"URL":"127\.0\.0\.1"' || true)
[ -z "$exposed" ] || fail "$name" "a port is not bound to 127.0.0.1: $exposed"
pass "$name"

# 10 app-env-dev
name=app-env-dev
ids=$(docker ps -q --filter "label=com.docker.compose.project=$project")
for id in $ids; do
  app_env=$(docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$id" | grep '^APP_ENV=' || true)
  if [ -n "$app_env" ] && [ "$app_env" != 'APP_ENV=dev' ]; then
    svc=$(docker inspect --format '{{index .Config.Labels "com.docker.compose.service"}}' "$id")
    fail "$name" "service $svc runs with $app_env"
  fi
done
pass "$name"

log "all 10 checks passed"

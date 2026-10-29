#!/usr/bin/env bash
# Writes local JWT signing keys and the HMAC secret for the email codes into .env (profile "apps").
# Contract: docs/4-scripts-contract.md; key rules: ADR-0003 (ES256 with a kid; codes stored as a keyed hash).
# Exit codes: 0 ok, 1 key generation or writing failed, 2 usage error or missing prerequisite (no .env, no openssl),
# 3 refused for safety (values already set, no --force).
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/gen-dev-secrets.sh [--force] [--test]

Generates, with openssl only, and writes into .env as single-line values:

  JWT_PRIVATE_KEY   ES256 (P-256) private key, PKCS#8 PEM, base64 on one line
  JWT_PUBLIC_KEY    the matching public key, SPKI PEM, base64 on one line
  JWT_KEY_ID        the kid: "kd-dev-" + the first 16 hex digits of the SHA-256 of the public key
  OTP_HMAC_SECRET   256 random bits, base64, for the keyed hash of the email codes

The values are never printed. .env gets file mode 600. The placeholder CHANGE_ME_LOCAL counts as "not set".
If any of the four is already set the script refuses and changes nothing, so a key pair is never half
replaced; --force regenerates all four.

  --force  replace values that are already set
  --test   write to .env.test (the test stack) instead of .env; the kid starts with "kd-test-"
  --help   show this text

KD_ENV_DIR (optional) is the folder that holds .env, as for scripts/init-env.sh.

Exit codes: 0 ok, 1 generation or write failed, 2 usage error, no .env (or .env.test), no openssl, 3 refused (values set, no --force).
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

force=0
target=.env
kid_prefix=kd-dev-
for arg in "$@"; do
  case "$arg" in
    -h|--help) usage; exit 0 ;;
    --force) force=1 ;;
    --test) target=.env.test; kid_prefix=kd-test- ;;
    *) log "unknown argument: $arg" >&2; usage >&2; exit 2 ;;
  esac
done

env_file="$env_dir/$target"
if [ ! -f "$env_file" ]; then
  log "$target not found; run scripts/init-env.sh <slot>" >&2
  exit 2
fi
if ! command -v openssl >/dev/null 2>&1; then
  log "openssl is required" >&2
  exit 2
fi

keys="JWT_PRIVATE_KEY JWT_PUBLIC_KEY JWT_KEY_ID OTP_HMAC_SECRET"

# current_value <key>: the last value of the key in .env, empty when absent.
current_value() {
  local line
  line=$(grep -E "^$1=" "$env_file" | tail -1 || true)
  printf '%s' "${line#*=}"
}

already=""
for k in $keys; do
  v=$(current_value "$k")
  if [ -n "$v" ] && [ "$v" != CHANGE_ME_LOCAL ]; then
    already="$already $k"
  fi
done
if [ -n "$already" ] && [ "$force" -ne 1 ]; then
  log "refused: already set in $target:$already; use --force to replace them" >&2
  exit 3
fi

# Nothing below may print a value or pass one as an argument of an external command (ps would show it).
fail() { log "$1" >&2; exit 1; }
umask 077

private_pem=$(openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 2>/dev/null) \
  || fail "openssl could not generate the signing key"
case "$private_pem" in
  *"BEGIN PRIVATE KEY"*) ;;
  *) fail "openssl did not return a PKCS#8 private key" ;;
esac
public_pem=$(printf '%s\n' "$private_pem" | openssl pkey -pubout 2>/dev/null) \
  || fail "openssl could not derive the public key"
key_digest=$(printf '%s\n' "$public_pem" | openssl pkey -pubin -outform DER 2>/dev/null \
  | openssl dgst -sha256 | awk '{ print $NF }' | cut -c1-16) \
  || fail "openssl could not fingerprint the public key"
jwt_private=$(printf '%s\n' "$private_pem" | openssl base64 -A) || fail "base64 of the private key failed"
jwt_public=$(printf '%s\n' "$public_pem" | openssl base64 -A) || fail "base64 of the public key failed"
hmac_secret=$(openssl rand -base64 32) || fail "openssl could not generate the HMAC secret"
if [ -z "$key_digest" ] || [ -z "$jwt_private" ] || [ -z "$jwt_public" ] || [ -z "$hmac_secret" ]; then
  fail "a generated value is empty"
fi
jwt_key_id="$kid_prefix$key_digest"

# new_value <key>: prints the value (printf is a builtin, so no argument list shows it).
new_value() {
  case "$1" in
    JWT_PRIVATE_KEY) printf '%s' "$jwt_private" ;;
    JWT_PUBLIC_KEY) printf '%s' "$jwt_public" ;;
    JWT_KEY_ID) printf '%s' "$jwt_key_id" ;;
    OTP_HMAC_SECRET) printf '%s' "$hmac_secret" ;;
  esac
}

# Rewrite .env into a mode-600 temporary file in the same folder, then move it over .env.
tmp=$(mktemp "$env_dir/.env.XXXXXX") || fail "cannot create a temporary file in $env_dir"
trap 'rm -f "$tmp"' EXIT

seen=" "
while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in
    ''|'#'*) printf '%s\n' "$line" ;;
    *)
      key=${line%%=*}
      case " $keys " in
        *" $key "*)
          case "$seen" in
            *" $key "*) ;;
            *) printf '%s=%s\n' "$key" "$(new_value "$key")"; seen="$seen$key " ;;
          esac
          ;;
        *) printf '%s\n' "$line" ;;
      esac
      ;;
  esac
done < "$env_file" > "$tmp"

missing=""
for k in $keys; do
  case "$seen" in
    *" $k "*) ;;
    *) missing="$missing $k" ;;
  esac
done
if [ -n "$missing" ]; then
  {
    printf '\n# Local JWT and HMAC keys written by scripts/gen-dev-secrets.sh (dev only, never committed)\n'
    for k in $missing; do
      printf '%s=%s\n' "$k" "$(new_value "$k")"
    done
  } >> "$tmp"
fi

chmod 600 "$tmp"
mv "$tmp" "$env_file"
chmod 600 "$env_file"

# Compose lets a variable exported by the calling shell win over .env, so a stale one (for example from an earlier
# "set -a; . ./.env") would hide the new value. Names only, never values.
for k in $keys; do
  if [ -n "${!k+x}" ] && [ "${!k}" != "$(new_value "$k")" ]; then
    log "warning: your shell exports $k with another value, which overrides .env in Compose; run: unset $k (or open a new terminal)" >&2
  fi
done
log "wrote JWT_PRIVATE_KEY, JWT_PUBLIC_KEY, JWT_KEY_ID and OTP_HMAC_SECRET to $env_file (values not shown, mode 600)"

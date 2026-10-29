#!/usr/bin/env bash
# Compares the pins of versions.env with those of the monorepo's infra/ (R11; docs/5-test-stack-and-ci.md, 5.6).
# Contract: docs/4-scripts-contract.md. Exit codes: 0 all equal (or infra not found, skipped),
# 1 a mismatch, 2 usage error or no pin file in the folder.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/check-parity.sh <path-to-monorepo-infra>

Compares these pins of versions.env with the same names in <path>/versions.env (or <path> itself when it
is a file) and prints one line per pin: name | here | there | ok or MISMATCH.

  POSTGRES_IMAGE            PostgreSQL image (the base of postgres/Dockerfile)
  POSTGIS_PACKAGE_VERSION   PostGIS version
  CADDY_IMAGE               Caddy tag
  API_TAG                   API image tag

The file name and format in infra/ are still to be agreed; versions.env is read first, as KEY=value lines
(an "export " prefix and surrounding quotes are accepted).
Digests are shortened in the table but compared in full.

Exit codes: 0 all equal, or the path does not exist (prints "infra not found, skipped");
1 a mismatch; 2 usage error, or the folder holds no versions.env.
EOF
}

log() { printf '[kd] %s\n' "$*"; }

for arg in "$@"; do
  case "$arg" in
    -h|--help) usage; exit 0 ;;
  esac
done

infra=""
for arg in "$@"; do
  case "$arg" in
    -*) log "unknown option: $arg" >&2; usage >&2; exit 2 ;;
    *)
      if [ -n "$infra" ]; then
        log "only one path may be given" >&2; usage >&2; exit 2
      fi
      infra=$arg
      ;;
  esac
done
if [ -z "$infra" ]; then
  log "missing <path-to-monorepo-infra>" >&2; usage >&2; exit 2
fi

# Resolve the path against the caller's folder before changing directory.
case "$infra" in
  /*) ;;
  *) infra="$PWD/$infra" ;;
esac
cd "$(dirname "${BASH_SOURCE[0]}")/.."

if [ -d "$infra" ]; then
  there_file=$infra/versions.env
elif [ -f "$infra" ]; then
  there_file=$infra
else
  log "infra not found, skipped: $infra"
  exit 0
fi
if [ ! -f "$there_file" ]; then
  log "no versions.env in $infra; the pin file of infra/ is still to be agreed" >&2
  exit 2
fi
if [ ! -f versions.env ]; then
  log "versions.env not found in the repository root" >&2
  exit 2
fi

# get_value <file> <key>: the value of the first KEY=value (or export KEY=value) line, without surrounding
# quotes; empty if absent.
get_value() {
  local v
  v=$(sed -n "s/^export[[:space:]][[:space:]]*//;/^$2=/{s/^$2=//;s/\\r\$//;p;q;}" "$1")
  case "$v" in
    \"*\") v=${v#\"}; v=${v%\"} ;;
    \'*\') v=${v#\'}; v=${v%\'} ;;
  esac
  printf '%s' "$v"
}

# short <value>: "(missing)" for an empty value, otherwise the value with the digest cut to 12 characters.
short() {
  local d
  case "$1" in
    "") printf '(missing)' ;;
    *@sha256:*) d=${1#*@sha256:}; printf '%s@sha256:%s...' "${1%%@sha256:*}" "${d:0:12}" ;;
    *) printf '%s' "$1" ;;
  esac
}

mismatches=0
printf '%-25s | %-45s | %-45s | %s\n' name here there result
for name in POSTGRES_IMAGE POSTGIS_PACKAGE_VERSION CADDY_IMAGE API_TAG; do
  here=$(get_value versions.env "$name")
  there=$(get_value "$there_file" "$name")
  if [ -n "$here" ] && [ "$here" = "$there" ]; then
    result=ok
  else
    result=MISMATCH
    mismatches=$((mismatches + 1))
  fi
  printf '%-25s | %-45s | %-45s | %s\n' "$name" "$(short "$here")" "$(short "$there")" "$result"
done

if [ "$mismatches" -ne 0 ]; then
  log "parity failed: $mismatches mismatch(es) against $there_file" >&2
  exit 1
fi
log "parity ok against $there_file"

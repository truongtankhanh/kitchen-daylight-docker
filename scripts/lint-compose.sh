#!/usr/bin/env bash
# Static hygiene checks for the Compose files (docs/3-compose-files-and-profiles.md, 3.3; docs/5-test-stack-and-ci.md, 5.4).
# Uses only bash, grep-style awk and git ls-files; it needs no .env and never talks to Docker.
# Contract: docs/4-scripts-contract.md. Exit codes: 0 clean (or, with --expect-fail, rejected as expected),
# 1 a violation was found (or, with --expect-fail, the file was accepted), 2 usage error or missing file.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/lint-compose.sh [<file>...]
       scripts/lint-compose.sh --expect-fail <file>

Checks Compose files (default: every compose*.yaml in the repository root) and fails, naming file and
line, on:

  - a ports: entry that does not start with 127.0.0.1: or with the opt-in ${KD_BIND_ADDRESS:-127.0.0.1}:
    (the long syntax is rejected too: write "127.0.0.1:HOST:CONTAINER");
  - any container_name;
  - restart: always or restart: unless-stopped;
  - an image with the tag latest or with no tag (a digest counts as a pin); an image taken from a
    variable such as ${S3_IMAGE} is checked where it is defined, in versions.env (*_IMAGE=);
  - any 0.0.0.0 binding;
  - a .env file tracked by git (.env, .env.test, .env.test.out; *.example is allowed). This check runs
    once per normal run, not with --expect-fail.

  --expect-fail <file>   succeed only if <file> is rejected; used to prove the bad examples in
                         scripts/tests/ are caught
  --help                 show this text

Paths are relative to the repository root (the script changes there first).
Exit codes: 0 clean (or rejected as expected), 1 a violation (or a bad example was accepted),
2 usage error or missing file.
EOF
}

log() { printf '[kd] %s\n' "$*"; }

# The awk program, shared by the Compose files and versions.env (mode=env).
awk_program() {
  cat <<'AWK'
function report(msg) { printf "%s:%d: %s\n", FILENAME, FNR, msg }
function strip(s) {
  sub(/[ \t]+#.*$/, "", s)
  sub(/^[ \t]+/, "", s)
  sub(/[ \t]+$/, "", s)
  return s
}
function unq(s,   n) {
  s = strip(s)
  n = length(s)
  if (n >= 2 && ((substr(s, 1, 1) == "\"" && substr(s, n, 1) == "\"") || (substr(s, 1, 1) == q && substr(s, n, 1) == q))) {
    s = substr(s, 2, n - 2)
  }
  return s
}
function check_image(v,   d, parts, n, last, c, tag, has_digest) {
  if (index(v, "${") > 0) {
    # The tag lives in the variable's definition (versions.env); only an explicit latest is caught here.
    if (v ~ /:latest($|[^A-Za-z0-9_.-])/) report("image uses the latest tag: " v)
    return
  }
  d = v
  has_digest = (index(d, "@") > 0)
  if (has_digest) d = substr(d, 1, index(d, "@") - 1)
  n = split(d, parts, "/")
  last = parts[n]
  tag = ""
  c = index(last, ":")
  if (c > 0) tag = substr(last, c + 1)
  if (tag == "latest") report("image uses the latest tag: " v)
  else if (tag == "" && !has_digest) report("image has no tag: " v)
}
function check_port(e) {
  if (e ~ /^[A-Za-z_]+:[ \t]/) report("ports entry in long syntax; write \"127.0.0.1:HOST:CONTAINER\"")
  else if (index(e, "127.0.0.1:") != 1 && index(e, "${KD_BIND_ADDRESS:-127.0.0.1}:") != 1) report("ports entry must start with 127.0.0.1: or ${KD_BIND_ADDRESS:-127.0.0.1}: (found " e ")")
}
BEGIN { q = sprintf("%c", 39) }
{
  line = $0
  sub(/\r$/, "", line)
}
mode == "env" {
  if (line ~ /^[A-Za-z0-9_]*_IMAGE=/) check_image(unq(substr(line, index(line, "=") + 1)))
  next
}
line ~ /^[ \t]*(#.*)?$/ { next }
{
  code = strip(line)
  match(line, /^ */)
  ind = RLENGTH
  if (in_ports && ind <= ports_ind) in_ports = 0

  if (index(code, "0.0.0.0") > 0) report("0.0.0.0 binding: " code)
  if (code ~ /^container_name:/) report("container_name is not allowed: " code)
  if (code ~ /^restart:/) {
    v = unq(substr(code, 9))
    if (v == "always" || v == "unless-stopped") report("restart: " v " is not allowed (use \"no\")")
  }
  if (code ~ /^image:/) check_image(unq(substr(code, 7)))

  if (in_ports) {
    if (code ~ /^-/) check_port(unq(substr(code, 2)))
    next
  }
  if (code ~ /^ports:/) {
    rest = strip(substr(code, 7))
    if (rest == "") {
      in_ports = 1
      ports_ind = ind
    } else if (rest ~ /^\[.*\]$/) {
      n = split(substr(rest, 2, length(rest) - 2), parts, ",")
      for (i = 1; i <= n; i++) {
        e = unq(parts[i])
        if (e != "") check_port(e)
      }
    } else if (rest !~ /^!/) {
      report("unsupported ports: syntax: " rest)
    }
  }
}
AWK
}

cd "$(dirname "${BASH_SOURCE[0]}")/.."

expect_fail=0
case "${1:-}" in
  --expect-fail) expect_fail=1; shift ;;
esac
for arg in "$@"; do
  case "$arg" in
    -h|--help) usage; exit 0 ;;
    -*) log "unknown argument: $arg" >&2; usage >&2; exit 2 ;;
  esac
done

if [ "$expect_fail" -eq 1 ] && [ "$#" -ne 1 ]; then
  log "--expect-fail takes exactly one file" >&2
  exit 2
fi
if [ "$#" -eq 0 ]; then
  set -- compose*.yaml
  if [ ! -e "$1" ]; then
    log "no compose*.yaml in the repository root" >&2
    exit 2
  fi
fi
for f in "$@"; do
  if [ ! -f "$f" ]; then
    log "file not found: $f" >&2
    exit 2
  fi
done

prog=$(awk_program)

# lint <mode> <file>: prints one "file:line: message" per violation.
lint() {
  awk -v mode="$1" "$prog" "$2"
}

if [ "$expect_fail" -eq 1 ]; then
  out=$(lint compose "$1")
  if [ -z "$out" ]; then
    log "expected a violation but found none: $1" >&2
    exit 1
  fi
  printf '%s\n' "$out" | sed 's/^/[kd] /'
  log "rejected as expected: $1"
  exit 0
fi

failed=0

for f in "$@"; do
  out=$(lint compose "$f")
  if [ -n "$out" ]; then
    printf '%s\n' "$out" | sed 's/^/[kd] /' >&2
    failed=1
  else
    log "ok $f"
  fi
done

# The images of the Compose files come from versions.env, so its pins are checked as well.
if [ -f versions.env ]; then
  out=$(lint env versions.env)
  if [ -n "$out" ]; then
    printf '%s\n' "$out" | sed 's/^/[kd] /' >&2
    failed=1
  else
    log "ok versions.env"
  fi
fi

# A .env file in the index (committed or staged) would publish local settings.
if command -v git >/dev/null 2>&1 && git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  tracked=$(git ls-files | awk -F/ '{ b = $NF } b ~ /^\.env(\..*)?$/ && b !~ /\.example$/ { print }')
  if [ -n "$tracked" ]; then
    printf '%s\n' "$tracked" | sed 's/$/: a .env file is tracked by git; run git rm --cached on it and keep it ignored/; s/^/[kd] /' >&2
    failed=1
  else
    log "ok no .env file is tracked"
  fi
else
  log "not a git work tree; skipped the tracked .env check"
fi

if [ "$failed" -ne 0 ]; then
  log "lint failed" >&2
  exit 1
fi
log "lint passed"

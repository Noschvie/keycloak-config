#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Noschvie
# keycloak-config -- shared helpers
#
# Sourced by all configure-*.sh scripts. Provides logging, environment
# checks, kcadm.sh execution inside the Keycloak container, JSON
# rendering and diffing.
#
# Principles (see requirements, section 2):
#   - create missing objects, update managed attributes
#   - never touch unmanaged attributes (kcadm "update" merges by default)
#   - never delete anything
#   - never print secrets

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CONFIG_DIR="${REPO_ROOT}/config"
KCADM="/opt/keycloak/bin/kcadm.sh"
KCADM_CONFIG="/tmp/kcadm.config"

DRY_RUN="${DRY_RUN:-0}"
CHANGES=0

# --- Logging -----------------------------------------------------------

if [[ -t 1 ]]; then
  C_RESET=$'\e[0m'; C_GREEN=$'\e[32m'; C_YELLOW=$'\e[33m'; C_RED=$'\e[31m'; C_BLUE=$'\e[34m'
else
  C_RESET=""; C_GREEN=""; C_YELLOW=""; C_RED=""; C_BLUE=""
fi

log_info()      { printf '%s[INFO]%s      %s\n' "$C_BLUE" "$C_RESET" "$*"; }
log_created()   { printf '%s[CREATED]%s   %s\n' "$C_GREEN" "$C_RESET" "$*"; }
log_updated()   { printf '%s[UPDATED]%s   %s\n' "$C_YELLOW" "$C_RESET" "$*"; }
log_unchanged() { printf '[UNCHANGED] %s\n' "$*"; }
log_drift()     { printf '%s[DRIFT]%s     %s\n' "$C_YELLOW" "$C_RESET" "$*"; }
log_warn()      { printf '%s[WARN]%s      %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
die()           { printf '%s[ERROR]%s     %s\n' "$C_RED" "$C_RESET" "$*" >&2; exit 1; }

# Record a change. In dry-run mode only report it.
# Usage: record_change created|updated "<description>"
LAST_CHANGE=""

record_change() {
  CHANGES=$((CHANGES + 1))
  LAST_CHANGE="$1: $2"
  if [[ "$DRY_RUN" == "1" ]]; then
    log_drift "would be $1: $2"
  elif [[ "$1" == "created" ]]; then
    log_created "$2"
  else
    log_updated "$2"
  fi
}

is_dry_run() { [[ "$DRY_RUN" == "1" ]]; }

# Changes are reported just before they are applied. If a script fails,
# point out the last reported change -- it may not have been applied.
_on_exit() {
  local rc=$?
  if (( rc != 0 && rc != 3 )) && [[ -n "$LAST_CHANGE" ]] && ! is_dry_run; then
    printf '%s[ERROR]%s     run aborted; last reported change may not have been applied: %s\n' \
      "$C_RED" "$C_RESET" "$LAST_CHANGE" >&2
  fi
}
trap _on_exit EXIT

# Exit code: 0 = ok; in dry-run mode 3 = changes pending
finish() {
  if is_dry_run && (( CHANGES > 0 )); then
    log_info "dry run: ${CHANGES} change(s) pending"
    exit 3
  fi
  log_info "done (${CHANGES} change(s))"
  exit 0
}

# --- Environment -------------------------------------------------------

require_cmd() {
  local c
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || die "required command not found: $c"
  done
}

require_env() {
  local v
  for v in "$@"; do
    [[ -n "${!v:-}" ]] || die "required environment variable not set: $v"
  done
}

# Load a secret from a file if <NAME>_FILE is set (Docker convention).
# The file content is taken verbatim -- no shell parsing, so any special
# character is allowed. Trailing newlines are removed. <NAME>_FILE takes
# precedence over <NAME>. The value is exported for docker exec -e.
load_secret() {
  local name="$1" file_var="${1}_FILE" file perms
  file="${!file_var:-}"
  if [[ -n "$file" ]]; then
    # relative paths are relative to the repository root
    [[ "$file" == /* ]] || file="${REPO_ROOT}/${file}"
    [[ -f "$file" && -r "$file" ]] || die "${file_var}: file not readable: ${file}"
    perms="$(stat -c '%a' "$file" 2>/dev/null || echo '?')"
    [[ "$perms" == "600" || "$perms" == "400" ]] \
      || log_warn "${file_var}: ${file} has permissions ${perms}, expected 600"
    printf -v "$name" '%s' "$(<"$file")"
    [[ -n "${!name}" ]] || die "${file_var}: file is empty: ${file}"
  fi
  if [[ -n "${!name:-}" ]]; then
    export "${name?}"
  fi
}

# Login mode:
#   client -- service account (KC_AUTOMATION_CLIENT_ID + secret), default
#             when KC_AUTOMATION_CLIENT_ID is set
#   user   -- admin user (KC_ADMIN_USER + password or prompt); forced by
#             KC_FORCE_USER_LOGIN=1 (used by the bootstrap script)
login_mode() {
  if [[ -n "${KC_AUTOMATION_CLIENT_ID:-}" && "${KC_FORCE_USER_LOGIN:-0}" != "1" ]]; then
    echo client
  else
    echo user
  fi
}

check_prerequisites() {
  require_cmd docker jq
  require_env KC_CONTAINER KC_SERVER_URL KC_ADMIN_REALM
  # Renamed variables: fail loudly instead of silently ignoring them.
  local old
  for old in KC_TEMP_PASSWORD KC_TEMP_PASSWORD_FILE; do
    [[ -z "${!old:-}" ]] || die "${old} has been renamed to ${old/KC_TEMP_PASSWORD/KC_USER_INITIAL_PASSWORD} -- please update your environment"
  done
  if [[ "$(login_mode)" == "client" ]]; then
    load_secret KC_AUTOMATION_CLIENT_SECRET
    require_env KC_AUTOMATION_CLIENT_SECRET
  else
    require_env KC_ADMIN_USER
    load_secret KC_ADMIN_PASSWORD
  fi
  load_secret KC_USER_INITIAL_PASSWORD
  [[ "$(docker inspect -f '{{.State.Running}}' "$KC_CONTAINER" 2>/dev/null)" == "true" ]] \
    || die "container not running: $KC_CONTAINER"
}

# --- kcadm.sh inside the container ------------------------------------

# kcadm.sh writes empty lines to stderr; drop them, keep real messages.
_filter_blank() { grep -v '^[[:space:]]*$' >&2 || true; }

# UTF-8 locale inside the container, so that non-ASCII characters in
# command line arguments (e.g. admin password, group names) are decoded
# correctly by Java.
KC_EXEC_ENV=(-e LC_ALL=C.UTF-8 -e LANG=C.UTF-8)

# Run kcadm.sh without stdin.
kc() {
  docker exec "${KC_EXEC_ENV[@]}" "$KC_CONTAINER" "$KCADM" "$@" --config "$KCADM_CONFIG" 2> >(_filter_blank)
}

# Run kcadm.sh with JSON on stdin (use with "-f -").
kc_in() {
  docker exec -i "${KC_EXEC_ENV[@]}" "$KC_CONTAINER" "$KCADM" "$@" --config "$KCADM_CONFIG" 2> >(_filter_blank)
}

# Authenticate once per run. Skipped when KC_SKIP_LOGIN=1 (set by
# apply-all.sh after it has logged in).
#
# Secrets are passed as environment variable KC_LOGIN_SECRET into the
# container (docker exec -e NAME, value taken from this shell), so they
# never appear on the host's command line or in the script output.
kc_login() {
  if [[ "${KC_SKIP_LOGIN:-0}" == "1" ]]; then
    return 0
  fi

  if [[ "$(login_mode)" == "client" ]]; then
    log_info "login: client ${KC_AUTOMATION_CLIENT_ID}@${KC_ADMIN_REALM} via container ${KC_CONTAINER}"
    KC_LOGIN_SECRET="$KC_AUTOMATION_CLIENT_SECRET" \
    docker exec "${KC_EXEC_ENV[@]}" -e KC_LOGIN_SECRET "$KC_CONTAINER" bash -c \
      '"$0" config credentials --config "$1" --server "$2" --realm "$3" --client "$4" --secret "$KC_LOGIN_SECRET"' \
      "$KCADM" "$KCADM_CONFIG" "$KC_SERVER_URL" "$KC_ADMIN_REALM" "$KC_AUTOMATION_CLIENT_ID" >/dev/null \
      || die "login failed (client ${KC_AUTOMATION_CLIENT_ID})"
    return 0
  fi

  log_info "login: ${KC_ADMIN_USER}@${KC_ADMIN_REALM} via container ${KC_CONTAINER}"
  if [[ -n "${KC_ADMIN_PASSWORD:-}" ]]; then
    KC_LOGIN_SECRET="$KC_ADMIN_PASSWORD" \
    docker exec "${KC_EXEC_ENV[@]}" -e KC_LOGIN_SECRET "$KC_CONTAINER" bash -c \
      '"$0" config credentials --config "$1" --server "$2" --realm "$3" --user "$4" --password "$KC_LOGIN_SECRET"' \
      "$KCADM" "$KCADM_CONFIG" "$KC_SERVER_URL" "$KC_ADMIN_REALM" "$KC_ADMIN_USER" >/dev/null \
      || die "login failed"
  else
    [[ -t 0 ]] || die "KC_ADMIN_PASSWORD not set and no terminal for the password prompt"
    docker exec -it "${KC_EXEC_ENV[@]}" "$KC_CONTAINER" "$KCADM" config credentials --config "$KCADM_CONFIG" \
      --server "$KC_SERVER_URL" --realm "$KC_ADMIN_REALM" --user "$KC_ADMIN_USER" \
      || die "login failed"
  fi
}

# --- Realm -------------------------------------------------------------

# The realm name is defined once, in config/realm/*.json.
realm_name() {
  local f
  f="$(find "${CONFIG_DIR}/realm" -maxdepth 1 -name '*.json' | head -n1)"
  [[ -n "$f" ]] || die "no realm file in ${CONFIG_DIR}/realm"
  jq -er '.realm' "$f" || die "no .realm in $f"
}

realm_exists() {
  local out
  # An API error (e.g. 401/403) must not be mistaken for "realm missing".
  out="$(kc get realms --fields realm)" \
    || die "cannot list realms -- authentication or permission problem (see message above)"
  jq -e --arg r "$1" 'any(.[]; .realm == $r)' <<<"$out" >/dev/null
}

# Abort (or end the dry run) if the realm does not exist yet.
require_realm() {
  if ! realm_exists "$1"; then
    if is_dry_run; then
      record_change created "realm $1 (and all objects in it)"
      finish
    fi
    die "realm $1 does not exist -- run configure-realm.sh first"
  fi
}

# --- JSON helpers ------------------------------------------------------

# Render a config file: replace ${TASMOFLEET_BASE_URL}; fail on any
# placeholder left over. Output to stdout -- never log it.
render_json() {
  local file="$1" out
  require_env TASMOFLEET_BASE_URL
  [[ "$TASMOFLEET_BASE_URL" != */ ]] || die "TASMOFLEET_BASE_URL must not end with '/'"
  out="$(jq --arg base "$TASMOFLEET_BASE_URL" \
    'walk(if type == "string" then gsub("\\$\\{TASMOFLEET_BASE_URL\\}"; $base) else . end)' "$file")" \
    || die "invalid JSON: $file"
  # shellcheck disable=SC2016  # literal ${ is intended
  if grep -q '\${' <<<"$out"; then
    die "unresolved placeholder in $file"
  fi
  printf '%s\n' "$out"
}

# List the managed attribute paths whose desired value differs from the
# current one. Arrays of scalars are compared order-independently.
# Usage: json_diff "<desired json>" "<current json>"
json_diff() {
  # Values are handed over via environment, not command line arguments,
  # because the desired JSON may contain a client secret.
  _JD_DESIRED="$1" _JD_CURRENT="$2" jq -rn '
    ($ENV._JD_DESIRED | fromjson) as $d
    | ($ENV._JD_CURRENT | fromjson) as $c
    | def norm: if type == "array" and all(.[]; type != "object" and type != "array")
              then sort else . end;
    def diffs($d; $c; $p):
      if ($d | type) == "object" then
        $d | to_entries[] | . as $e
        | diffs($e.value; (if ($c | type) == "object" then $c[$e.key] else null end); $p + [$e.key])
      elif ($d | norm) == ($c | norm) then empty
      else $p | join(".")
      end;
    [diffs($d; $c; [])] | unique | .[]'
}

# Join diff paths for logging; secrets are named but never shown.
format_diff() {
  paste -sd, - | sed 's/,/, /g'
}

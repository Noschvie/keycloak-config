#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Noschvie
# Create or update users from config/users/users.json and ensure their
# group memberships.
#
# - New users get the temporary password and must change it at first
#   login (UPDATE_PASSWORD).
# - Existing users: managed attributes are updated, the password is
#   NEVER reset.
# - Group memberships are only added, never removed.
set -euo pipefail
# shellcheck source=lib/common.sh
source "$(dirname "$0")/lib/common.sh"

# check_prerequisites also loads KC_TEMP_PASSWORD from KC_TEMP_PASSWORD_FILE
check_prerequisites

# PoC: default temporary password, overridable via KC_TEMP_PASSWORD(_FILE)
readonly TEMP_PASSWORD="${KC_TEMP_PASSWORD:-myPassword}"

kc_login

realm="$(realm_name)"
require_realm "$realm"
users_file="${CONFIG_DIR}/users/users.json"

if [[ -n "${KC_TEMP_PASSWORD_FILE:-}" ]]; then
  log_info "temporary password source: file KC_TEMP_PASSWORD_FILE"
elif [[ -n "${KC_TEMP_PASSWORD:-}" ]]; then
  log_info "temporary password source: environment variable KC_TEMP_PASSWORD"
else
  log_info "temporary password source: script default (PoC)"
fi

all_groups="$(kc get groups -r "$realm" --fields id,name)"

group_id() {
  jq -r --arg n "$1" 'map(select(.name == $n)) | .[0].id // empty' <<<"$all_groups"
}

user_id() {
  kc get users -r "$realm" -q "username=$1" -q exact=true --fields id,username \
    | jq -r --arg u "$1" 'map(select(.username == $u)) | .[0].id // empty'
}

ensure_groups() {
  local uid="$1" username="$2" wanted="$3" current_groups name gid

  if [[ -n "$uid" ]]; then
    current_groups="$(kc get "users/${uid}/groups" -r "$realm" --fields name)"
  else
    current_groups="[]"
  fi

  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    if jq -e --arg n "$name" 'any(.[]; .name == $n)' <<<"$current_groups" >/dev/null; then
      log_unchanged "user ${username}: member of ${name}"
      continue
    fi
    gid="$(group_id "$name")"
    if [[ -z "$gid" ]]; then
      is_dry_run || die "group ${name} does not exist -- run configure-groups.sh first"
    fi
    record_change updated "user ${username}: add to group ${name}"
    is_dry_run || kc update "users/${uid}/groups/${gid}" -r "$realm" \
      -s "realm=${realm}" -s "userId=${uid}" -s "groupId=${gid}" -n
  done < <(jq -r '.[]' <<<"$wanted")
}

count="$(jq '.users | length' "$users_file")"
for (( i = 0; i < count; i++ )); do
  user="$(jq -c ".users[$i]" "$users_file")"
  username="$(jq -r '.username' <<<"$user")"
  attrs="$(jq -c 'del(.groups)' <<<"$user")"
  groups="$(jq -c '.groups // []' <<<"$user")"

  uid="$(user_id "$username")"

  if [[ -z "$uid" ]]; then
    record_change created "user ${username} (temporary password, UPDATE_PASSWORD)"
    if ! is_dry_run; then
      # Password is passed via stdin as part of the representation,
      # never on a command line.
      _KC_INITIAL_PW="$TEMP_PASSWORD" jq -c '
        . + {
          requiredActions: ["UPDATE_PASSWORD"],
          credentials: [{ type: "password", value: $ENV._KC_INITIAL_PW, temporary: true }]
        }' <<<"$attrs" | kc_in create users -r "$realm" -f - >/dev/null
      uid="$(user_id "$username")"
      [[ -n "$uid" ]] || die "user ${username} not found after creation"
    fi
  else
    current="$(kc get "users/${uid}" -r "$realm")"
    changed="$(json_diff "$attrs" "$current")"
    if [[ -z "$changed" ]]; then
      log_unchanged "user ${username}"
    else
      record_change updated "user ${username}: $(format_diff <<<"$changed")"
      is_dry_run || kc_in update "users/${uid}" -r "$realm" -f - <<<"$attrs"
    fi
  fi

  ensure_groups "$uid" "$username" "$groups"
done

finish

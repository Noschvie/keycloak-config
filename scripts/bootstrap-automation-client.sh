#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Noschvie
# Create or update the automation client (service account) in the master
# realm and grant it the roles from config/automation/keycloak-config.json.
#
# Run with an ADMIN USER (KC_ADMIN_USER + password), once per Keycloak
# instance and again whenever the role list changes. Afterwards the other
# scripts can log in as the service account (KC_AUTOMATION_CLIENT_ID).
#
# Roles are only added, never removed (same rule as for all objects).
#
# Note: realm-management roles live on the master client "<realm>-realm",
# which exists only after the realm has been created. On a fresh
# instance, run this script again after the first apply-all.sh. (A realm
# created by the service account itself grants it admin rights on that
# realm anyway -- Keycloak gives the creator of a realm full access.)
set -euo pipefail
# shellcheck source=lib/common.sh
source "$(dirname "$0")/lib/common.sh"

export KC_FORCE_USER_LOGIN=1
check_prerequisites
load_secret KC_AUTOMATION_CLIENT_SECRET
require_env KC_AUTOMATION_CLIENT_SECRET
kc_login

automation_file="${CONFIG_DIR}/automation/keycloak-config.json"
master="$KC_ADMIN_REALM"
realm="$(realm_name)"

desired="$(jq -c '.client' "$automation_file")"
client_id="$(jq -r '.clientId' <<<"$desired")"
[[ -z "${KC_AUTOMATION_CLIENT_ID:-}" || "$KC_AUTOMATION_CLIENT_ID" == "$client_id" ]] \
  || die "KC_AUTOMATION_CLIENT_ID (${KC_AUTOMATION_CLIENT_ID}) does not match ${automation_file} (${client_id})"
desired="$(jq '.secret = $ENV.KC_AUTOMATION_CLIENT_SECRET' <<<"$desired")"

log_info "automation client: ${client_id} in realm ${master}"

# --- client ------------------------------------------------------------

uuid="$(kc get clients -r "$master" -q "clientId=${client_id}" --fields id,clientId \
  | jq -r --arg c "$client_id" 'map(select(.clientId == $c)) | .[0].id // empty')"

if [[ -z "$uuid" ]]; then
  record_change created "client ${client_id} (service account)"
  if is_dry_run; then
    finish
  fi
  kc_in create clients -r "$master" -f - <<<"$desired" >/dev/null
  uuid="$(kc get clients -r "$master" -q "clientId=${client_id}" --fields id,clientId \
    | jq -r --arg c "$client_id" 'map(select(.clientId == $c)) | .[0].id // empty')"
  [[ -n "$uuid" ]] || die "client ${client_id} not found after creation"
else
  changed="$(json_diff "$desired" "$(kc get "clients/${uuid}" -r "$master")")"
  if [[ -z "$changed" ]]; then
    log_unchanged "client ${client_id}"
  else
    record_change updated "client ${client_id}: $(format_diff <<<"$changed")"
    is_dry_run || kc_in update "clients/${uuid}" -r "$master" -f - <<<"$desired"
  fi
fi

# --- default client scopes ---------------------------------------------
# Keycloak 26.8 requires the Admin API audience in the access token. It is
# added by the client scope "kc-admin-api" (default scope of admin-cli);
# without it every Admin API call of the service account gets HTTP 401.

current_scopes="$(kc get "clients/${uuid}/default-client-scopes" -r "$master" | jq -c '[.[].name]')"
realm_scopes="$(kc get client-scopes -r "$master" --fields id,name)"
while IFS= read -r scope; do
  if jq -e --arg s "$scope" 'index($s) != null' <<<"$current_scopes" >/dev/null; then
    log_unchanged "client ${client_id}: default client scope ${scope}"
    continue
  fi
  sid="$(jq -r --arg s "$scope" 'map(select(.name == $s)) | .[0].id // empty' <<<"$realm_scopes")"
  [[ -n "$sid" ]] || die "client scope ${scope} not found in realm ${master}"
  record_change updated "client ${client_id}: add default client scope ${scope}"
  is_dry_run || kc_in update "clients/${uuid}/default-client-scopes/${sid}" -r "$master" -n -f - <<<'{}'
done < <(jq -r '.defaultClientScopes[]?' "$automation_file")

# --- roles of the service account user ---------------------------------

sa_user="$(kc get "clients/${uuid}/service-account-user" -r "$master" --fields id,username)"
sa_id="$(jq -r '.id' <<<"$sa_user")"
sa_name="$(jq -r '.username' <<<"$sa_user")"
mappings="$(kc get "users/${sa_id}/role-mappings" -r "$master")"

# Add the roles from $2 (JSON array) that are missing in $3 (JSON array
# of current role names). $1 = "realm" or the client id of the roles.
ensure_roles() {
  local container="$1" wanted="$2" current="$3" role missing=()
  while IFS= read -r role; do
    if jq -e --arg r "$role" 'index($r) != null' <<<"$current" >/dev/null; then
      log_unchanged "${sa_name}: role ${container}/${role}"
    else
      missing+=("$role")
      record_change updated "${sa_name}: add role ${container}/${role}"
    fi
  done < <(jq -r '.[]' <<<"$wanted")

  if (( ${#missing[@]} == 0 )) || is_dry_run; then
    return 0
  fi
  local args=()
  for role in "${missing[@]}"; do args+=(--rolename "$role"); done
  if [[ "$container" == "realm" ]]; then
    kc add-roles -r "$master" --uid "$sa_id" "${args[@]}"
  else
    kc add-roles -r "$master" --uid "$sa_id" --cclientid "$container" "${args[@]}"
  fi
}

ensure_roles realm \
  "$(jq -c '.realmRoles' "$automation_file")" \
  "$(jq -c '[.realmMappings[]?.name]' <<<"$mappings")"

mgmt_client="${realm}-realm"
mgmt_lookup="$(kc get clients -r "$master" -q "clientId=${mgmt_client}" --fields clientId)" \
  || die "cannot look up client ${mgmt_client}"
if jq -e --arg c "$mgmt_client" 'any(.[]; .clientId == $c)' <<<"$mgmt_lookup" >/dev/null; then
  ensure_roles "$mgmt_client" \
    "$(jq -c '.realmManagementRoles' "$automation_file")" \
    "$(jq -c --arg c "$mgmt_client" '[.clientMappings[$c].mappings[]?.name]' <<<"$mappings")"
else
  log_warn "realm ${realm} does not exist yet: roles on ${mgmt_client} skipped -- run this script again after apply-all.sh"
fi

finish

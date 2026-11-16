#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Noschvie
# Create or update all clients in config/clients/*.json, including their
# protocol mappers.
#
# Client secret: for confidential clients the secret is taken from the
# environment variable <CLIENTID>_CLIENT_SECRET (upper case, non
# alphanumeric characters replaced by "_"), e.g. TASMOFLEET_CLIENT_SECRET.
set -euo pipefail
# shellcheck source=lib/common.sh
source "$(dirname "$0")/lib/common.sh"

check_prerequisites
kc_login

realm="$(realm_name)"
require_realm "$realm"

secret_var_for() {
  printf '%s_CLIENT_SECRET' "$(tr '[:lower:]' '[:upper:]' <<<"$1" | tr -c 'A-Z0-9\n' '_')"
}

# Reconcile protocol mappers by name: create missing, update changed.
# Mappers not listed in the file are left untouched.
reconcile_mappers() {
  local client_uuid="$1" client_id="$2" desired_mappers="$3"
  local current_mappers count i mapper name mid changed

  current_mappers="$(kc get "clients/${client_uuid}/protocol-mappers/models" -r "$realm")"
  count="$(jq 'length' <<<"$desired_mappers")"

  for (( i = 0; i < count; i++ )); do
    mapper="$(jq -c ".[$i]" <<<"$desired_mappers")"
    name="$(jq -r '.name' <<<"$mapper")"
    mid="$(jq -r --arg n "$name" 'map(select(.name == $n)) | .[0].id // empty' <<<"$current_mappers")"

    if [[ -z "$mid" ]]; then
      record_change created "client ${client_id}: protocol mapper ${name}"
      is_dry_run || kc_in create "clients/${client_uuid}/protocol-mappers/models" -r "$realm" -f - <<<"$mapper" >/dev/null
      continue
    fi

    changed="$(json_diff "$mapper" "$(jq -c --arg n "$name" 'map(select(.name == $n)) | .[0]' <<<"$current_mappers")")"
    if [[ -z "$changed" ]]; then
      log_unchanged "client ${client_id}: protocol mapper ${name}"
    else
      record_change updated "client ${client_id}: protocol mapper ${name}: $(format_diff <<<"$changed")"
      is_dry_run || kc_in update "clients/${client_uuid}/protocol-mappers/models/${mid}" -r "$realm" -f - <<<"$mapper"
    fi
  done
}

shopt -s nullglob
for file in "${CONFIG_DIR}"/clients/*.json; do
  desired="$(render_json "$file")"
  client_id="$(jq -r '.clientId' <<<"$desired")"
  log_info "client: ${client_id}"

  # Inject the client secret for confidential clients.
  if [[ "$(jq -r '.publicClient // false' <<<"$desired")" != "true" ]]; then
    secret_var="$(secret_var_for "$client_id")"
    load_secret "$secret_var"
    require_env "$secret_var"
    desired="$(SECRET_VAR="$secret_var" jq '.secret = $ENV[$ENV.SECRET_VAR]' <<<"$desired")"
  fi

  mappers="$(jq -c '.protocolMappers // []' <<<"$desired")"
  client_repr="$(jq -c 'del(.protocolMappers)' <<<"$desired")"

  existing="$(kc get clients -r "$realm" -q "clientId=${client_id}" --fields id,clientId)"
  uuid="$(jq -r --arg c "$client_id" 'map(select(.clientId == $c)) | .[0].id // empty' <<<"$existing")"

  if [[ -z "$uuid" ]]; then
    # Create including protocol mappers in a single call.
    record_change created "client ${client_id} (incl. $(jq 'length' <<<"$mappers") protocol mapper(s))"
    is_dry_run || kc_in create clients -r "$realm" -f - <<<"$desired" >/dev/null
    continue
  fi

  current="$(kc get "clients/${uuid}" -r "$realm")"
  changed="$(json_diff "$client_repr" "$current")"
  if [[ -z "$changed" ]]; then
    log_unchanged "client ${client_id}"
  else
    # Attribute names are logged, values are not (may include the secret).
    record_change updated "client ${client_id}: $(format_diff <<<"$changed")"
    is_dry_run || kc_in update "clients/${uuid}" -r "$realm" -f - <<<"$client_repr"
  fi

  # A client update does not change existing protocol mappers.
  reconcile_mappers "$uuid" "$client_id" "$mappers"
done

finish

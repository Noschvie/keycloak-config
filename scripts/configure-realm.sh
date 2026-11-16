#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Noschvie
# Create the realm if missing, otherwise update its managed attributes.
# Source: config/realm/<realm>.json
set -euo pipefail
# shellcheck source=lib/common.sh
source "$(dirname "$0")/lib/common.sh"

check_prerequisites
kc_login

realm_file="$(find "${CONFIG_DIR}/realm" -maxdepth 1 -name '*.json' | head -n1)"
realm="$(realm_name)"
desired="$(render_json "$realm_file")"

log_info "realm: ${realm}"

if ! realm_exists "$realm"; then
  record_change created "realm ${realm}"
  is_dry_run || kc_in create realms -f - <<<"$desired" >/dev/null
  finish
fi

current="$(kc get "realms/${realm}")"
changed="$(json_diff "$desired" "$current")"

if [[ -z "$changed" ]]; then
  log_unchanged "realm ${realm}"
else
  record_change updated "realm ${realm}: $(format_diff <<<"$changed")"
  # kcadm "update" merges into the existing representation:
  # attributes not contained in the file stay untouched.
  is_dry_run || kc_in update "realms/${realm}" -f - <<<"$desired"
fi

finish

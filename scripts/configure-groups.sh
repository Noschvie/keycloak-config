#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Noschvie
# Create missing top-level groups. Existing groups are left as they are,
# groups not listed in the file are never deleted.
# Source: config/groups/groups.json
set -euo pipefail
# shellcheck source=lib/common.sh
source "$(dirname "$0")/lib/common.sh"

check_prerequisites
kc_login

realm="$(realm_name)"
require_realm "$realm"
groups_file="${CONFIG_DIR}/groups/groups.json"

current="$(kc get groups -r "$realm" --fields name)"

while IFS= read -r name; do
  if jq -e --arg n "$name" 'any(.[]; .name == $n)' <<<"$current" >/dev/null; then
    log_unchanged "group ${name}"
  else
    record_change created "group ${name}"
    is_dry_run || kc create groups -r "$realm" -s "name=${name}" >/dev/null
  fi
done < <(jq -r '.groups[].name' "$groups_file")

finish

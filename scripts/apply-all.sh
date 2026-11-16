#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Noschvie
# Apply the complete configuration in the required order:
#   realm -> groups -> clients -> users
#
# DRY_RUN=1 ./scripts/apply-all.sh   shows pending changes only
# Exit codes: 0 = ok, 1 = error, 3 = dry run with pending changes
set -euo pipefail
# shellcheck source=lib/common.sh
source "$(dirname "$0")/lib/common.sh"

check_prerequisites
kc_login
export KC_SKIP_LOGIN=1

scripts_dir="$(dirname "$0")"
pending=0

for step in configure-realm configure-groups configure-clients configure-users; do
  log_info "=== ${step} ==="
  rc=0
  "${scripts_dir}/${step}.sh" || rc=$?
  case "$rc" in
    0) ;;
    3) pending=1
       # Without the realm the later steps cannot be checked.
       if [[ "$step" == "configure-realm" ]] && ! realm_exists "$(realm_name)"; then
         break
       fi ;;
    *) die "${step} failed (exit ${rc})" ;;
  esac
done

if (( pending )); then
  log_info "dry run: changes pending"
  exit 3
fi
log_info "all steps completed"

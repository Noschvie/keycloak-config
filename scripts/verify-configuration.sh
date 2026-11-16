#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Noschvie
# Compare Keycloak against the configuration in Git without changing
# anything (drift report).
# Exit codes: 0 = in sync, 1 = error, 3 = drift detected
set -euo pipefail

rc=0
DRY_RUN=1 "$(dirname "$0")/apply-all.sh" || rc=$?

case "$rc" in
  0) echo "Keycloak matches the configuration in Git." ;;
  3) echo "Drift detected: run ./scripts/apply-all.sh to apply the configuration." ;;
  *) echo "Verification failed (exit ${rc})." >&2 ;;
esac
exit "$rc"

# Phase 3 -- Automation

**Status:** Completed (mock-tested; real tests see Phase 4)\
**Related:** [phase-2-declarative-configuration.md](phase-2-declarative-configuration.md),
[phase-4-reproducibility-test.md](phase-4-reproducibility-test.md)

------------------------------------------------------------------------

## 1. Scripts

| Script                     | Purpose                                                        |
|----------------------------|----------------------------------------------------------------|
| `apply-all.sh`             | Login once, then realm → groups → clients → users              |
| `verify-configuration.sh`  | `DRY_RUN=1 apply-all.sh`; drift report, changes nothing        |
| `configure-realm.sh`       | Create realm or update managed attributes                      |
| `configure-groups.sh`      | Create missing top-level groups                                |
| `configure-clients.sh`     | Create/update clients, inject secret, reconcile protocol mappers |
| `configure-users.sh`       | Create/update users, temporary password, add group memberships |
| `lib/common.sh`            | Logging, env and secret loading, `kc`/`kc_in`, render, diff    |

Exit codes: `0` ok, `1` error, `3` dry run with pending changes.

## 2. Design

### 2.1 kcadm.sh execution

-   `kc()` = `docker exec <container> /opt/keycloak/bin/kcadm.sh ... --config /tmp/kcadm.config`
-   `kc_in()` = same with `docker exec -i`, JSON via stdin (`-f -`)
-   Both run with `LC_ALL=C.UTF-8` so that non-ASCII characters in
    command line arguments are decoded correctly by Java.
-   Blank lines that `kcadm.sh` writes to stderr are filtered; real
    error messages are kept.

### 2.2 Login

-   With an admin password (`KC_ADMIN_PASSWORD_FILE` or
    `KC_ADMIN_PASSWORD`): passed with `docker exec -e KC_ADMIN_PASSWORD`
    (value from the environment, not on the host command line) into
    `bash -c` inside the container. Residual exposure: visible in the
    Java process arguments inside the container during the login --
    accepted for the PoC.
-   Without: interactive prompt (`docker exec -it`), requires a terminal.
-   `apply-all.sh` logs in once and sets `KC_SKIP_LOGIN=1` for the steps.

### 2.3 Secrets

-   `load_secret NAME`: if `NAME_FILE` is set, the file content is read
    verbatim (no shell parsing; any character, incl. umlauts, quotes,
    `$`, backticks). Trailing newlines are removed, relative paths are
    relative to the repository root, a warning is issued if the file is
    not `chmod 600`. `NAME_FILE` wins over `NAME`.
-   Client secret: `<CLIENTID>_CLIENT_SECRET` (e.g.
    `TASMOFLEET_CLIENT_SECRET`), required for confidential clients,
    injected via `jq $ENV`.
-   Temporary password: inserted into the user representation via
    `jq $ENV`, sent via stdin.
-   `json_diff` receives JSON via environment variables, not arguments.
-   Logs contain attribute **names** only, never values.

### 2.4 Reconciliation

-   **Diff:** recursive comparison of managed attributes only; arrays of
    scalars compared order-independently. Unchanged objects are not
    written.
-   **Update:** `kcadm.sh update` (merge mode) -- unmanaged attributes
    remain untouched.
-   **Protocol mappers:** reconciled by name via
    `clients/<id>/protocol-mappers/models`.
-   **Users:** created with `credentials` (`temporary: true`) and
    `requiredActions: ["UPDATE_PASSWORD"]`; existing users: attributes
    updated, password never touched.
-   **Groups / memberships:** only created / added, never removed.
-   **Deletion:** not implemented anywhere.

## 3. Mock tests

A fake `docker` + `kcadm.sh` emulation held the Keycloak state in a JSON
file. shellcheck: no findings.

| # | Scenario                                         | Result |
|---|--------------------------------------------------|--------|
| 1 | Verify on empty Keycloak                         | "realm would be created", exit 3 |
| 2 | Fresh apply                                      | Realm, groups, client + mapper, users with temp password + `UPDATE_PASSWORD`, memberships |
| 3 | Second run                                       | Only `[UNCHANGED]`, exit 0 |
| 4 | Drift as in the original realm                   | All drifts reported in dry run, then applied |
| 5 | Unmanaged settings                               | Preserved |
| 6 | Objects not in Git (extra user, extra group)     | Preserved |
| 7 | Existing user passwords                          | Unchanged |
| 8 | Secrets in output                                | None |
| 9 | Missing variables, trailing `/`, no terminal     | Clear error, exit 1 |
| 10| Secret files with umlauts, quotes, `$(...)`, backticks, backslash | Received verbatim, nothing executed, nothing logged |

Bug found during testing and fixed: the `readonly` `TEMP_PASSWORD`
could not be used as a temporary environment assignment for `jq`.

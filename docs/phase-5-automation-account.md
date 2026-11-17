# Phase 5 -- Automation Account

**Status:** Completed (2026-11-17) -- tested on dev and live instance\
**Related:** [requirements.md](requirements.md) (section 6),
[phase-3-automation.md](phase-3-automation.md)

------------------------------------------------------------------------

## 1. Goal

Until Phase 4 the scripts logged in as a master-realm administrator,
which has full access to every realm. Requirement (section 6): use a
dedicated automation account with only the permissions the scripts
need.

## 2. Design

-   Confidential client **`keycloak-config`** in the `master` realm with
    **service account** enabled; standard, implicit and direct grant
    flows disabled.
-   Client secret from `KC_AUTOMATION_CLIENT_SECRET_FILE` (not in Git).
-   Declarative definition: `config/automation/keycloak-config.json`
    (client representation, realm roles, realm-management roles).

### 2.1 Roles

| Container                         | Roles | Needed for |
|-----------------------------------|-------|------------|
| `master` realm                    | `create-realm` | creating the realm on a fresh instance (decision) |
| client `tasmofleet-realm` (master)| `view-realm`, `manage-realm` | realm settings, brute-force protection |
|                                   | `query-clients`, `view-clients`, `manage-clients` | TasmoFleet client, secret, protocol mapper |
|                                   | `query-users`, `view-users`, `manage-users`, `query-groups` | users, initial password, groups, memberships |

The service account has no rights on the `master` realm itself or on
other existing realms. With `create-realm` it can create new realms;
Keycloak grants the creator of a realm full admin rights on that realm.

### 2.2 Bootstrap

`scripts/bootstrap-automation-client.sh` runs **with the admin user**
(`KC_FORCE_USER_LOGIN=1` internally):

1.  Create or update the client (`json_diff`, merge update, secret from
    file).
2.  Read the service account user
    (`clients/<id>/service-account-user`) and its role mappings.
3.  Add missing realm roles and missing roles on `<realm>-realm`
    (`kcadm.sh add-roles`). Roles are only added, never removed.
4.  If the realm does not exist yet, the roles on `<realm>-realm` are
    skipped with a warning -- on a fresh instance: bootstrap →
    `apply-all.sh` → bootstrap again.

Idempotent; supports `DRY_RUN=1`.

### 2.3 Login

`lib/common.sh` selects the login mode:

| Condition                                | Login |
|------------------------------------------|-------|
| `KC_AUTOMATION_CLIENT_ID` set            | `kcadm.sh config credentials --client <id> --secret ...` |
| not set, or `KC_FORCE_USER_LOGIN=1`      | admin user as before |

The secret (client secret or admin password) is passed into the
container as `KC_LOGIN_SECRET` via `docker exec -e`, never on the host
command line or in the output.

## 3. Mock tests

| # | Scenario | Result |
|---|----------|--------|
| 1 | Bootstrap on fresh instance (admin login) | Client + service account created, `create-realm` added, warning for missing `tasmofleet-realm` |
| 2 | `apply-all.sh` with `KC_AUTOMATION_CLIENT_ID` | Login as client, realm and all objects created; secret with special characters received verbatim |
| 3 | Bootstrap again (realm exists) | 9 roles on `tasmofleet-realm` added |
| 4 | Bootstrap a third time | 0 changes |
| 5 | `DRY_RUN=1` bootstrap | No changes, exit 0 |
| 6 | `verify-configuration.sh` as service account | "matches" |
| 7 | Without `KC_AUTOMATION_CLIENT_ID` | Admin user login as before |
| 8 | Missing client secret | Clear error |
| 9 | `KC_AUTOMATION_CLIENT_ID` differs from the config file | Clear error |

The mock does not enforce permissions. Whether the role set is
sufficient for every operation must be verified against a real
Keycloak.

## 4. Finding from the first real test: Admin API audience

First run on `dev-keycloak-1`: the client login succeeded, but every
Admin API call returned **HTTP 401 Unauthorized**.

Cause: Keycloak 26.8 requires the Admin API audience in the access
token. It is added by the client scope **`kc-admin-api`** (mapper
`oidc-admin-api-audience-mapper`), which is a default scope of
`admin-cli` but not of newly created clients.

Fix:

-   `config/automation/keycloak-config.json`:
    `"defaultClientScopes": ["kc-admin-api"]`
-   The bootstrap assigns missing default client scopes via
    `clients/<id>/default-client-scopes/<scope-id>`.

The same run revealed two weaknesses in the error handling, also fixed:

-   `realm_exists` treated an API error as "realm missing" and went on
    to create the realm. It now aborts with "cannot list realms --
    authentication or permission problem".
-   Changes are reported just before they are applied, so the log showed
    `[CREATED] realm tasmofleet` although the creation failed. On an
    abort the scripts now print the last reported change with the note
    that it may not have been applied.

The mock now emulates the 401 for client tokens without `kc-admin-api`;
the full fresh-instance sequence (bootstrap → apply → bootstrap → apply)
ends with 0 changes.

## 5. Real tests (2026-11-17)

### Development instance `dev-keycloak-1`

| # | Test | Result |
|---|------|--------|
| D1| Bootstrap after the scope fix | `kc-admin-api` added; afterwards all client calls succeed (confirms the cause of the 401) |
| D2| `apply-all.sh` as service account on a realm with deviating settings | Realm, client (incl. secret), protocol mapper, groups, users with initial password and memberships created/updated -- the role set is sufficient |
| D3| Bootstrap and `apply-all.sh` again | 0 changes |
| D4| Isolation: `get users -r master`, `get clients -r master`, `update realms/master` | `403 Forbidden` each |
| D5| Access to realm `tasmofleet` (`get users`) | OK |
| D6| `create-realm`: service account creates realm `create-test`, then `get users -r create-test` | Realm created; `[]` instead of 403 -- creator rights granted |

`get realms/master` as service account returns only a reduced
representation (name, display name, locales): Keycloak shows it to any
account with an admin role in `master` for the realm name list. The full
representation requires `view-realm` on `master`, which the account does
not have.

Note: `dev-keycloak-1` imports the development realm of the login theme
project on start. Running these scripts against it overwrites that
realm's client settings; reset the container afterwards if it is used
for theme development.

Cosmetic fix from the dev test: `kcadm.sh` prints "Created new ... with
id ..." on stderr; these notices are filtered.

### Live instance `keycloak`

| # | Test | Result |
|---|------|--------|
| L1| Bootstrap with the admin user, separate client secret for the live instance | Client created, `kc-admin-api`, `create-realm` and 9 roles on `tasmofleet-realm` added |
| L2| `verify-configuration.sh` as service account | Login `client keycloak-config@master`; 0 changes, "matches" |

## 6. Result

The scripts run without a master-realm administrator. The admin user is
only needed for `bootstrap-automation-client.sh` (once per instance and
when the role list changes). Use a separate client secret per instance.

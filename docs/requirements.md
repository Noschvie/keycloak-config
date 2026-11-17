# Keycloak Configuration as Code -- Requirements

**Status:** v0.4 (Proof of Concept, implemented and tested -- see Phase 4)\
**Project:** `keycloak-config`\
**Target realm:** `tasmofleet`\
**Target Keycloak version:** 26.8\
**Purpose:** Requirements and implementation plan for reproducibly
configuring Keycloak for TasmoFleet and, potentially, further
applications.

Implementation details that evolved during the project (repository
layout, secret files, UTF-8 handling) are documented in the phase
documents and the [README](../README.md); where they differ, those take
precedence.

------------------------------------------------------------------------

## 1. Background

A Keycloak realm named `tasmofleet` had been configured manually for
TasmoFleet login and Single Sign-On (SSO). The setup was created
primarily for learning and testing and is now documented and made
reproducible.

A partial JSON export of the realm served as the factual baseline for
reviewing the configuration (see Phase 1).

The aim is to avoid relying on manual steps in the Keycloak Admin
Console and instead maintain a clear, repeatable configuration that can
be applied to a fresh Keycloak installation.

The first implementation is a **proof of concept (PoC)**. Simplifications
accepted for the PoC are marked explicitly.

## 2. Core design principle: Git is the Source of Truth

**The scripts and configuration files in the Git repository define the
desired state of Keycloak.** This is the central design requirement of
the project and takes precedence over any manual change made in the
Admin Console.

The approach is a lean Infrastructure-as-Code model with these rules:

1.  **Changes are applied.** Changes to the JSON configuration are
    transferred to Keycloak when the scripts are run.
2.  **Existing objects are updated.** Realm settings, clients and users
    that already exist are updated to match the managed configuration.
3.  **Missing objects are created.** Objects defined in the
    configuration but not present in Keycloak are created.
4.  **Unmanaged settings remain untouched.** Settings and objects that
    are not defined in the repository are neither changed nor reset.
    Only the attributes explicitly listed in the configuration files are
    managed.
5.  **Deletions never happen automatically.** Objects that have been
    removed from the configuration are *not* deleted from Keycloak. If a
    deletion is ever required, it is a separate, deliberate action,
    never a side effect of a normal run.

Consequences:

-   Manual changes in the Admin Console to *managed* settings are
    considered drift and will be overwritten on the next run.
-   Permanent changes must therefore be made in the repository first and
    then applied with the scripts.
-   The scripts support both **initial provisioning** of a fresh
    Keycloak instance and **controlled updates** of an existing realm.

## 3. Goals

1.  Capture and document the working `tasmofleet` realm configuration.
2.  Automate the creation and configuration of the realm.
3.  Automate the creation and configuration of the TasmoFleet OIDC
    client.
4.  Manage users and group assignments reproducibly from a static
    `users.json`.
5.  Keep passwords, client secrets and other credentials out of the
    Git repository.
6.  Make the setup repeatable on another Keycloak instance or host.
7.  Support initial provisioning and controlled updates according to
    the Source-of-Truth rules in section 2.
8.  Provide clear installation, configuration, execution and recovery
    instructions.

## 4. Scope

### 4.1 In scope

-   Realm `tasmofleet`: creation, enabled state, login/registration and
    security settings (incl. brute-force protection).
-   TasmoFleet OIDC client: client ID, protocol, client authentication,
    standard flow, redirect URIs, web origins, post-logout redirect URIs,
    protocol mappers, login theme, logo URI.
-   Groups used for authorisation.
-   Users from a static `users.json`: username, profile attributes,
    enabled state, group memberships, initial password.
-   Automation with the official Keycloak Admin CLI (`kcadm.sh`) of
    Keycloak 26.8; idempotent, with validation, drift report and clear
    error reporting.
-   Documentation: prerequisites, secret handling, execution,
    verification, troubleshooting.

### 4.2 Out of scope

-   Installation or lifecycle management of the Keycloak server itself
-   A general-purpose Keycloak management framework
-   Migration of unrelated realms or applications
-   Custom Keycloak themes or extensions (see
    [tasmofleet-keycloak-theme](https://github.com/Noschvie/tasmofleet-keycloak-theme))
-   SMTP configuration and email-based flows
-   Automatic deletion of objects removed from the configuration
-   Production hardening beyond the requirements of this setup

## 5. User and password provisioning

Users are defined in `config/users/users.json`, without passwords or
password hashes. **No SMTP server is required or assumed**; initial
access uses a temporary password with a forced password change at
first login.

User lifecycle:

1.  Create the user with the required profile attributes.
2.  Assign the groups.
3.  Set the enabled state as defined in `users.json`.
4.  **Only when the user is newly created:** set the temporary password
    (`temporary: true`) and the required action `UPDATE_PASSWORD`.

### 5.1 Initial password

The initial password for new users is supplied at runtime via
`KC_USER_INITIAL_PASSWORD_FILE` (file, read verbatim, any characters)
or `KC_USER_INITIAL_PASSWORD`.

-   **No default.** If a user has to be created and no initial password
    is set, the script aborts before creating anything; the dry run
    only warns. Runs without new users do not need it.
-   The script reports the source (file or variable), never the value.
-   Set only when a user is **created**; existing passwords are
    **never** reset.
-   Usable only for the first login, then replaced by the user.

History: the PoC started with a hardcoded default (`myPassword`),
overridable via `KC_TEMP_PASSWORD`. As the default was readable in the
public repository, it was removed and the variable renamed to
`KC_USER_INITIAL_PASSWORD` (decision 6). The old names abort with a
hint to rename.

Setting `UPDATE_PASSWORD` alone is not sufficient: a user without a
password credential cannot log in, so the temporary credential is
mandatory for the bootstrap. Per-user generated passwords or an
execute-actions email flow (once SMTP is available) remain possible
extensions.

## 6. Security and secret management

The repository must not contain client secrets, administrator
passwords, user passwords or hashes, tokens or other
deployment-specific credentials.

-   Secrets are supplied at runtime from protected files (`*_FILE`
    variables, directory `secrets/`, Git-ignored) or environment
    variables.
-   Secrets are never printed in script output or logs.
-   The scripts run as a dedicated automation client (service account
    `keycloak-config`) with minimal roles; the master-realm
    administrator is only needed once for its bootstrap (Phase 5).
-   Keep test and production credentials separate.
-   Treat realm exports as sensitive until reviewed; they are
    Git-ignored.

## 7. Technical approach

-   `kcadm.sh` runs inside the Keycloak container (`docker exec`); the
    host only needs `docker` and `jq`.
-   JSON for declarative configuration, containing only **managed**
    attributes -- not a full realm export.
-   Reconciliation per object:

| Situation in Keycloak                         | Action                          |
|-----------------------------------------------|---------------------------------|
| Object defined in Git, missing in Keycloak    | Create                          |
| Object defined in Git, exists in Keycloak     | Update managed attributes only  |
| Attribute not defined in Git                  | Leave untouched                 |
| Object exists in Keycloak, not defined in Git | Leave untouched (no deletion)   |
| New user                                      | Initial password (temporary) + `UPDATE_PASSWORD` |
| Existing user's password                      | Leave untouched (no reset)      |

-   Scripts are safe to run any number of times; a second run with
    unchanged configuration results in no changes.
-   A dry-run / drift report mode shows differences without applying
    them.

## 8. Work plan

| Phase | Content | Document |
|-------|---------|----------|
| 1 | Review of the existing configuration | [phase-1-configuration-review.md](phase-1-configuration-review.md) |
| 2 | Declarative configuration files | [phase-2-declarative-configuration.md](phase-2-declarative-configuration.md) |
| 3 | Automation scripts | [phase-3-automation.md](phase-3-automation.md) |
| 4 | Reproducibility test | [phase-4-reproducibility-test.md](phase-4-reproducibility-test.md) |
| 5 | Automation account   | [phase-5-automation-account.md](phase-5-automation-account.md) |

## 9. Acceptance criteria

-   The `tasmofleet` realm on Keycloak 26.8 can be configured from the
    files in the repository, which act as the Source of Truth.
-   The TasmoFleet OIDC client is created and updated automatically,
    with correct redirect and post-logout redirect URIs.
-   Users are provisioned from `users.json` without passwords in Git.
-   New users receive the initial password and must change it at
    first login; no SMTP is required.
-   Existing users' passwords are never reset by a normal run.
-   Client secrets and admin credentials are supplied outside the
    repository and are not exposed in logs.
-   Re-running the scripts creates missing objects, updates managed
    attributes, leaves unmanaged settings untouched and never deletes
    anything automatically.
-   A clean test setup completes login and logout.
-   The README explains prerequisites, execution, verification and
    troubleshooting, and the initial password handling.

## 10. Decisions

| #  | Topic                | Decision                                                              |
|----|----------------------|-----------------------------------------------------------------------|
| 1  | Keycloak version     | 26.8                                                                  |
| 2  | Realm                | `tasmofleet`                                                          |
| 3  | User source          | Static `config/users/users.json`                                      |
| 4  | Secrets              | No real passwords or client secrets in Git                            |
| 5  | Initial user access  | Initial password (temporary credential) + `UPDATE_PASSWORD`           |
| 6  | Initial password     | `KC_USER_INITIAL_PASSWORD_FILE`, required for new users, no default; only set on user creation |
| 7  | SMTP                 | Not required, not assumed                                             |
| 8  | Operating mode       | Initial provisioning and controlled updates                           |
| 9  | Source of Truth      | Git configuration and scripts define the desired state                |
| 10 | Deletions            | Never automatic; only as separate, explicitly confirmed action        |
| 11 | Usernames            | ASCII only; first/last names may contain non-ASCII characters         |
| 12 | Secret input         | Secret files (`*_FILE`), read verbatim; any character allowed         |
| 13 | Automation account   | Service account `keycloak-config` in `master`, `create-realm` + minimal roles on `<realm>-realm` |

## 11. References

-   Keycloak documentation: https://www.keycloak.org/documentation
-   Keycloak Admin REST API: https://www.keycloak.org/docs-api/latest/rest-api/
-   Keycloak Server Administration Guide: https://www.keycloak.org/docs/latest/server_admin/
-   Keycloak Import / Export: https://www.keycloak.org/server/importExport

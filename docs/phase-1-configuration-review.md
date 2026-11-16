# Phase 1 -- Configuration Review of Realm `tasmofleet`

**Status:** Completed\
**Source:** Partial realm export from the Admin Console (2,659 lines)
plus user list read via `kcadm.sh`\
**Keycloak version:** 26.8.2\
**Related:** [requirements.md](requirements.md)

Host names in this document are neutralised: `tasmofleet.example.org`
stands for the real TasmoFleet host.

------------------------------------------------------------------------

## 1. Summary

The realm is close to Keycloak defaults. The TasmoFleet-specific
configuration consists of only a few elements:

-   Realm display name `TasmoFleet`
-   One confidential OIDC client `tasmofleet` (login theme, logo,
    redirect/logout URIs, group mapper)
-   Two groups: `TasmoFleet Admins`, `TasmoFleet Users`
-   Two users: `tasmofleet-admin`, `tasmofleet-user`

No custom realm roles, client roles, client scopes, authentication
flows, identity providers or SMTP configuration exist.

A partial export from the Admin Console never contains users; they were
read separately with `kcadm.sh get users` (no credentials included).

### 1.1 Environments

| Container        | Database   | Purpose                             |
|------------------|------------|-------------------------------------|
| `keycloak`       | PostgreSQL | Live instance with realm `tasmofleet` |
| `dev-keycloak-1` | H2 (dev)   | Development / test instance         |

`kcadm.sh` is not installed on the host; it is executed inside the
container via `docker exec <container> /opt/keycloak/bin/kcadm.sh` with
`--server http://localhost:8080` and a temporary
`--config /tmp/kcadm.config`.

## 2. Sensitive values

| Item                    | Finding                                          | Action                                  |
|-------------------------|--------------------------------------------------|-----------------------------------------|
| Client secret           | Masked (`**********`) by the export              | Supplied at runtime                     |
| Realm keys              | Only provider names/priorities, no key material  | Not managed; Keycloak generates keys    |
| Users / password hashes | Not included                                     | --                                      |
| Personal data of users  | Real names/emails in the live realm              | Replaced by neutral values (D6)         |
| IDs (UUIDs)             | Present everywhere                               | Never copied into managed config        |

The export is kept outside the repository (Git-ignored).

## 3. Inventory and classification

Legend: **M** = managed (in Git), **D** = default, not managed,
**P** = parameterised per environment, **X** = out of scope.

### 3.1 Realm

| Setting                    | Value             | Class | Note                                   |
|----------------------------|-------------------|-------|----------------------------------------|
| `realm`                    | `tasmofleet`      | M     |                                        |
| `enabled`                  | `true`            | M     |                                        |
| `displayName`              | `TasmoFleet`      | M     |                                        |
| `displayNameHtml`          | `TasmoFleet`      | M     |                                        |
| `registrationAllowed`      | `false`           | M     | Explicitly pinned (security-relevant)  |
| `resetPasswordAllowed`     | `false`           | M     | Pinned; no SMTP                        |
| `verifyEmail`              | `false`           | M     | Pinned; no SMTP                        |
| `loginWithEmailAllowed`    | `true`            | M     | Pinned                                 |
| `rememberMe`               | `false`           | M     | Pinned                                 |
| `sslRequired`              | `external`        | M     | Pinned                                 |
| `bruteForceProtected`      | **`true`** (export: `false`) | M | D3, see 3.6                     |
| Brute-force parameters     | see 3.6           | M     |                                        |
| Token / session lifespans  | Keycloak defaults | D     | Manage later if changed                |
| OTP / WebAuthn policies    | Defaults          | D     |                                        |
| Browser security headers   | Defaults          | D     |                                        |
| Events / admin events      | Disabled          | D     |                                        |
| Authentication flows       | Built-in only     | D     |                                        |
| Required actions           | Built-in; `UPDATE_PASSWORD` enabled | D | Must stay enabled           |
| Realm themes               | Not set           | D     | Theme is set on client level           |
| Key providers              | Generated         | D     |                                        |
| SMTP                       | Empty             | X     | No SMTP                                |

### 3.2 Client `tasmofleet`

Base URL: `${TASMOFLEET_BASE_URL}`, e.g. `https://tasmofleet.example.org`
(lower case only, D2).

| Setting                        | Target value                                     | Class |
|--------------------------------|--------------------------------------------------|-------|
| `clientId`                     | `tasmofleet`                                     | M     |
| `name`                         | `Tasmota Fleet`                                  | M     |
| `protocol`                     | `openid-connect`                                 | M     |
| `enabled`                      | `true`                                           | M     |
| `publicClient`                 | `false` (confidential)                           | M     |
| `clientAuthenticatorType`      | `client-secret`                                  | M     |
| `secret`                       | runtime secret                                   | M     |
| `standardFlowEnabled`          | `true`                                           | M     |
| `implicitFlowEnabled`          | `false`                                          | M     |
| `directAccessGrantsEnabled`    | `false`                                          | M     |
| `serviceAccountsEnabled`       | `false`                                          | M     |
| `fullScopeAllowed`             | `false` (non-default)                            | M     |
| `frontchannelLogout`           | `true`                                           | M     |
| `rootUrl` / `adminUrl` / `baseUrl` | `<base>`                                     | M + P |
| `redirectUris`                 | `["<base>/oidc/callback"]`                       | M + P |
| `webOrigins`                   | `["<base>"]`                                     | M + P |
| `post.logout.redirect.uris`    | `<base>/*`                                       | M + P |
| `login_theme`                  | `tasmofleet`                                     | M     |
| `logoUri`                      | TasmoFleet icon (GitHub raw URL)                 | M     |
| Other attributes, client scopes| Defaults                                         | D     |
| Protocol mapper `tasmofleet-groups` | `oidc-group-membership-mapper`, claim `groups`, `full.path=false`, multivalued, in ID/access/userinfo/introspection token | M |

The export contained each URI twice, in lower case and mixed case
(`TasmoFleet...`). Browsers normalise host names to lower case, so the
mixed-case variants are dropped (D2). As these lists are managed, the
first run on the existing realm removes the mixed-case entries -- an
intended change of a managed attribute, not an object deletion.

`login_theme = tasmofleet` requires the theme to be deployed; otherwise
Keycloak falls back to the default theme.

### 3.3 Groups

| Group               | Roles | Class |
|---------------------|-------|-------|
| `TasmoFleet Admins` | none  | M     |
| `TasmoFleet Users`  | none  | M     |

TasmoFleet authorises via the `groups` claim (names without path), not
via roles. Every user must be a member of one of the two groups.

### 3.4 Users (D1, D6)

Usernames and groups are taken over; names and emails are replaced by
neutral values under the non-routable domain `dummy.local`.

| Username           | First name   | Last name | Email                          | Group               |
|--------------------|--------------|-----------|--------------------------------|---------------------|
| `tasmofleet-admin` | `TasmoFleet` | `Admin`   | `tasmofleet-admin@dummy.local` | `TasmoFleet Admins` |
| `tasmofleet-user`  | `TasmoFleet` | `User`    | `tasmofleet-user@dummy.local`  | `TasmoFleet Users`  |

Managed: `username`, `firstName`, `lastName`, `email`, `emailVerified`,
`enabled`, group memberships (additive only). Passwords are not managed.

### 3.5 Other objects

Built-in clients, client scopes (incl. `kc-admin-api`, built-in in
26.8), client registration policies and default realm roles: defaults,
not managed.

### 3.6 Brute-force protection (D3, D7)

| Setting                         | Value      | Meaning                                  |
|---------------------------------|------------|------------------------------------------|
| `bruteForceProtected`           | `true`     | Protection on                            |
| `permanentLockout`              | `false`    | Temporary lockout only                   |
| `failureFactor`                 | **`10`**   | Failed logins before lockout             |
| `waitIncrementSeconds`          | `60`       | Lockout duration increment               |
| `maxFailureWaitSeconds`         | `900`      | Maximum lockout duration (15 min)        |
| `minimumQuickLoginWaitSeconds`  | `60`       | Wait after too-quick failed logins       |
| `quickLoginCheckMilliSeconds`   | `1000`     | Threshold for "too quick"                |
| `maxDeltaTimeSeconds`           | `43200`    | Failure counter reset after 12 h         |

## 4. Parameters per environment

| Variable                   | Example / source                       | Required |
|----------------------------|----------------------------------------|----------|
| `KC_CONTAINER`             | `keycloak` / `dev-keycloak-1`          | yes      |
| `TASMOFLEET_BASE_URL`      | `https://tasmofleet.example.org`       | yes      |
| `TASMOFLEET_CLIENT_SECRET` | runtime secret, must match TasmoFleet  | yes      |
| `KC_TEMP_PASSWORD`         | optional, default `myPassword`         | no       |

## 5. Decisions

| #  | Topic                 | Decision                                                        |
|----|-----------------------|-----------------------------------------------------------------|
| D1 | Users                 | Take over the two existing users (usernames, groups)            |
| D2 | Mixed-case URIs       | Removed; only lower-case `<base>` URIs are managed              |
| D3 | Brute-force protection| Enabled and managed                                             |
| D4 | Client secret         | Supplied at runtime (required)                                  |
| D5 | kcadm.sh execution    | Inside the Keycloak container via `docker exec`                 |
| D6 | User personal data    | Neutral names, emails `<username>@dummy.local`                  |
| D7 | `failureFactor`       | 10                                                              |

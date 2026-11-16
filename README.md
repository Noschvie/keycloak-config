# keycloak-config

Configuration as Code for the Keycloak realm **`tasmofleet`** (TasmoFleet
login / SSO), based on `kcadm.sh` and JSON files.

> **Status: Proof of Concept.** New users get a shared default temporary
> password (see [Temporary password](#temporary-password)). Use in test
> environments only.

## Principle: Git is the Source of Truth

The files in this repository define the desired state of Keycloak:

- changes in the JSON files are applied to Keycloak,
- existing realm, clients and users are updated,
- missing objects are created,
- settings not contained in the files remain untouched,
- **nothing is ever deleted automatically.**

Manual changes in the Admin Console to managed settings are overwritten
on the next run. Make permanent changes in Git first.

## Repository layout

```text
config/
  realm/tasmofleet.json      realm settings incl. brute-force protection
  clients/tasmofleet.json    OIDC client incl. protocol mapper "groups"
  groups/groups.json         TasmoFleet Admins, TasmoFleet Users
  users/users.json           users and groups (no passwords)
scripts/
  apply-all.sh               apply everything (realm -> groups -> clients -> users)
  verify-configuration.sh    drift report, changes nothing
  configure-realm.sh         single steps, can be run individually
  configure-groups.sh
  configure-clients.sh
  configure-users.sh
  lib/common.sh              shared helpers
examples/environment.example runtime variables
```

## Prerequisites

- Keycloak **26.8** running in Docker (`quay.io/keycloak/keycloak`)
- On the host: `docker`, `jq`, `bash`
- No Keycloak installation on the host: `kcadm.sh` runs inside the
  Keycloak container via `docker exec`.
- An admin account in the `master` realm

## Setup

```bash
cp examples/environment.example environment
chmod 600 environment
$EDITOR environment            # fill in values

# secrets: one file per secret, content taken verbatim
mkdir -p secrets && chmod 700 secrets
$EDITOR secrets/admin-password
$EDITOR secrets/tasmofleet-client-secret
chmod 600 secrets/*

set -a; . ./environment; set +a
```

| Variable                        | Required | Description                                        |
|---------------------------------|----------|----------------------------------------------------|
| `KC_CONTAINER`                  | yes      | Keycloak container, e.g. `dev-keycloak-1`          |
| `KC_SERVER_URL`                 | yes      | `http://localhost:8080` (as seen from the container) |
| `KC_ADMIN_REALM`                | yes      | `master`                                           |
| `KC_ADMIN_USER`                 | yes      | admin user (ASCII)                                 |
| `KC_ADMIN_PASSWORD_FILE`        | no       | file with the admin password; empty = prompt       |
| `TASMOFLEET_BASE_URL`           | yes      | e.g. `https://tasmofleet.example.org`, lower case, no trailing `/` |
| `TASMOFLEET_CLIENT_SECRET_FILE` | yes      | file with the client secret, must match TasmoFleet |
| `KC_TEMP_PASSWORD_FILE`         | no       | file with the temporary password for new users     |

`environment` and `secrets/` are Git-ignored. Never commit secrets.

### Special characters

- **Secrets** (`*_FILE`): the file content is used verbatim -- any
  character is allowed, including umlauts, quotes, `$`, `!`, `\` and
  spaces. A trailing newline is removed. Relative paths are relative to
  the repository root. The scripts warn if a file is not `chmod 600`.
- Each secret can alternatively be given directly as `NAME=value`
  (e.g. `TASMOFLEET_CLIENT_SECRET`); then shell quoting rules apply.
  If both are set, `NAME_FILE` wins.
- **`environment`** is parsed by the shell: keep it to simple values.
- **Usernames** must be ASCII (no umlauts). First and last names may
  contain umlauts.
- `kcadm.sh` runs with `LC_ALL=C.UTF-8` so that non-ASCII characters in
  command line arguments are decoded correctly.

## Usage

```bash
# 1. Check what would change (no changes are made)
./scripts/verify-configuration.sh

# 2. Apply
./scripts/apply-all.sh

# 3. Check again: should report "matches"
./scripts/verify-configuration.sh
```

`DRY_RUN=1` works for every script, e.g. `DRY_RUN=1 ./scripts/configure-users.sh`.

Exit codes: `0` ok / in sync, `1` error, `3` dry run with pending changes
(drift). `verify-configuration.sh` can therefore be used in monitoring.

Output example:

```text
[UPDATED]   client tasmofleet: redirectUris, secret
[UNCHANGED] user tasmofleet-user
[DRIFT]     would be updated: realm tasmofleet: failureFactor
```

Only attribute names are logged, never values, so secrets do not appear
in the output.

## Users

Users are defined in `config/users/users.json` without passwords:

```json
{
  "username": "tasmofleet-admin",
  "firstName": "TasmoFleet",
  "lastName": "Admin",
  "email": "tasmofleet-admin@dummy.local",
  "emailVerified": false,
  "enabled": true,
  "groups": ["TasmoFleet Admins"]
}
```

TasmoFleet authorises via the `groups` claim, so every user needs one of
the groups `TasmoFleet Admins` or `TasmoFleet Users`. Group memberships
are only added, never removed.

### Temporary password

No SMTP is required. A **new** user gets a temporary password and must
set a new one at first login (`UPDATE_PASSWORD`):

```bash
readonly TEMP_PASSWORD="${KC_TEMP_PASSWORD:-myPassword}"
```

- Default `myPassword` (PoC), overridable via `KC_TEMP_PASSWORD_FILE` (or `KC_TEMP_PASSWORD`)
- Set only when the user is created -- **existing passwords are never
  reset**
- Hand the temporary password to the user via a secure channel

**PoC limitation:** the default is part of the repository. Anyone who
knows it can log in as a newly created user before that user has changed
the password. Before production use, remove the default.

## Recommended test procedure

1. Run against the development instance first:
   `KC_CONTAINER=dev-keycloak-1` -- the realm is created from scratch.
2. Test login and logout in TasmoFleet, and the first login with the
   temporary password.
3. Run `apply-all.sh` again: all lines must be `[UNCHANGED]`.
4. Then against the real instance (`KC_CONTAINER=keycloak`):
   `verify-configuration.sh` first and review the drift report, then
   `apply-all.sh`.

## Troubleshooting

| Symptom                                          | Cause / fix                                               |
|--------------------------------------------------|-----------------------------------------------------------|
| `container not running`                          | check `KC_CONTAINER` with `docker ps`                     |
| `login failed`                                   | admin user/password, `KC_ADMIN_REALM`, `KC_SERVER_URL`    |
| `no terminal for the password prompt`            | set `KC_ADMIN_PASSWORD_FILE` or run interactively         |
| `required environment variable not set`          | load `environment`: `set -a; . ./environment; set +a`     |
| `realm ... does not exist`                       | run `apply-all.sh` (or `configure-realm.sh` first)        |
| `TASMOFLEET_BASE_URL must not end with '/'`      | remove trailing slash                                     |
| Same attribute reported as changed on every run  | Keycloak normalises the value: adjust the value in Git to the form Keycloak returns |
| Login page without TasmoFleet design             | login theme `tasmofleet` not deployed in this container   |

## Documentation

Overview here, details per phase in [`docs/`](docs/):

| Document | Content |
|----------|---------|
| [requirements.md](docs/requirements.md) | Requirements, Source-of-Truth principle, decisions |
| [phase-1-configuration-review.md](docs/phase-1-configuration-review.md) | Review of the original realm, managed vs. default settings |
| [phase-2-declarative-configuration.md](docs/phase-2-declarative-configuration.md) | JSON files and conventions |
| [phase-3-automation.md](docs/phase-3-automation.md) | Script design, secret handling, mock tests |
| [phase-4-reproducibility-test.md](docs/phase-4-reproducibility-test.md) | Tests against a real Keycloak 26.8 |

## License

AGPL-3.0-or-later, see [`LICENSE`](LICENSE). Same licence as TasmoFleet
and [tasmofleet-keycloak-theme](https://github.com/Noschvie/tasmofleet-keycloak-theme).
Runtime tools and their licences are listed in [`NOTICE`](NOTICE).

# Phase 4 -- Reproducibility Test

**Status:** Completed -- Part A and Part B passed (2026-11-17)\
**Related:** [phase-3-automation.md](phase-3-automation.md)

------------------------------------------------------------------------

## Part A -- Development instance `dev-keycloak-1`

Keycloak 26.8.2 with H2; realm `tasmofleet` created from scratch by the
scripts (2026-11-16).

| # | Test                                                       | Result |
|---|------------------------------------------------------------|--------|
| A1| `apply-all.sh` on a clean instance                         | Realm, groups, client + mapper, users created |
| A2| Second `apply-all.sh` run                                  | All `[UNCHANGED]`, 0 changes |
| A3| First login of `tasmofleet-user` with the temporary password (Account Console `/realms/tasmofleet/account`) | Accepted, password change enforced |
| A4| `apply-all.sh` after the password change                   | All `[UNCHANGED]` |
| A5| Login with the new password after A4                       | OK -- existing password not reset |
| A6| Non-ASCII data (2026-11-17): test user `mueller` with first/last name `Jörg Müller`, temporary password `wörd11!#` from `KC_USER_INITIAL_PASSWORD_FILE` | Created; second run all `[UNCHANGED]`; login with the temporary password OK, password change enforced; names shown correctly in the Account Console |

Confirmed Keycloak behaviour:

| Point                                                     | Status |
|-----------------------------------------------------------|--------|
| `kcadm.sh update` merge behaviour                         | Confirmed (no drift after update) |
| User creation with inline credentials + `UPDATE_PASSWORD` | Confirmed |
| Client GET returns `secret`                               | Confirmed (no permanent `secret` drift) |
| User lookup with `-q exact=true`                          | Confirmed (no duplicates) |
| Login via `docker exec -e ... bash -c`                    | Confirmed |
| No values normalised differently by Keycloak              | Confirmed |
| `login_theme` on an instance without that theme           | Not blocking |

A6 confirms the secret-file handling (`*_FILE`, read verbatim) and the
UTF-8 locale for `kcadm.sh`: umlauts and `!`/`#` pass through unchanged,
and non-ASCII names cause no permanent drift. Usernames stay ASCII by
decision.

Issue found and fixed: blank lines from `kcadm.sh` on stderr cluttered
the output; they are now filtered.

The TasmoFleet redirect after login and the post-logout redirect could
not be tested without a TasmoFleet test instance; they are covered in
Part B.

## Part B -- Live instance `keycloak`

Keycloak 26.8.2 with PostgreSQL, existing realm `tasmofleet`
(2026-11-17). Client URIs and user data had already been aligned
manually with the Git configuration before the run.

| # | Test                                                       | Result |
|---|------------------------------------------------------------|--------|
| B1| Backup of the Keycloak database (`pg_dump`)                | Done |
| B2| `verify-configuration.sh`                                  | Drift: realm `bruteForceProtected`, `failureFactor`; client and users unchanged (no `secret` drift -- secret file matches TasmoFleet) |
| B3| `apply-all.sh`                                             | `[UPDATED] realm tasmofleet: bruteForceProtected, failureFactor`, everything else `[UNCHANGED]` |
| B4| `verify-configuration.sh` after apply                      | 0 changes, "matches" |
| B5| TasmoFleet login via Keycloak, redirect back to TasmoFleet | OK |
| B6| TasmoFleet logout, post-logout redirect                    | OK |
| B7| Authorisation via `groups` claim: `tasmofleet-admin` and `tasmofleet-user` | Each receives the expected permissions |

## Result

All acceptance criteria from [requirements.md](requirements.md) are met:
the realm is configured from the repository as Source of Truth, runs are
idempotent, unmanaged settings and passwords are preserved, nothing is
deleted, secrets stay outside Git, and TasmoFleet login and logout work
against the configured realm.

Follow-up done: the default temporary password was removed; the initial
password for new users is now mandatory (`KC_USER_INITIAL_PASSWORD_FILE`).

Follow-up: dedicated automation account instead of a master-realm
administrator, see [phase-5-automation-account.md](phase-5-automation-account.md).

# Phase 4 -- Reproducibility Test

**Status:** Part A passed; Part B (live instance) pending\
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
| A6| Non-ASCII data (2026-11-17): test user `mueller` with first/last name `Jörg Müller`, temporary password `wörd11!#` from `KC_TEMP_PASSWORD_FILE` | Created; second run all `[UNCHANGED]`; login with the temporary password OK, password change enforced; names shown correctly in the Account Console |

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

## Part B -- Live instance `keycloak` (pending)

1.  Backup: `pg_dump` of the Keycloak PostgreSQL database.
2.  `secrets/tasmofleet-client-secret` = the secret currently used by
    TasmoFleet.
3.  `KC_CONTAINER=keycloak ./scripts/verify-configuration.sh` -- review
    the drift report. Expected:
    -   realm: `bruteForceProtected`, `failureFactor`
    -   client: `redirectUris`, `webOrigins`,
        `attributes.post.logout.redirect.uris`, possibly `secret`
    -   users: `email`, `firstName`, `lastName`
4.  `KC_CONTAINER=keycloak ./scripts/apply-all.sh`
5.  Second run: all `[UNCHANGED]`.
6.  TasmoFleet login, redirect back, logout, post-logout redirect.

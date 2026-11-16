# Phase 2 -- Declarative Configuration

**Status:** Completed\
**Related:** [requirements.md](requirements.md),
[phase-1-configuration-review.md](phase-1-configuration-review.md)

------------------------------------------------------------------------

## 1. Configuration files

``` text
config/
├── realm/tasmofleet.json      # managed realm attributes
├── clients/tasmofleet.json    # OIDC client incl. protocol mapper
├── groups/groups.json         # groups
└── users/users.json           # users (no passwords)
examples/environment.example   # runtime variables (no secrets)
```

Compared with the requirements draft, `config/groups/groups.json` was
added: groups are a separate Admin API resource and must exist before
users are assigned.

The realm name is defined once, in `config/realm/tasmofleet.json`.

## 2. Conventions

-   Files contain **only managed attributes** -- no IDs, no defaults, no
    full export.
-   **No secrets.** The client secret is injected at runtime.
-   **Placeholder:** `${TASMOFLEET_BASE_URL}` is the only placeholder.
    The scripts replace it with `jq` (`walk` + `gsub`) before passing
    the JSON to `kcadm.sh` via stdin. A leftover `${...}` aborts the run.
-   `users.json` and `groups.json` use a wrapper object
    (`{"users": [...]}`, `{"groups": [...]}`). Realm and client files are
    plain Keycloak representations.

## 3. Validation against the original realm

Realm -- intended differences only:

| Attribute             | Export | Git    |
|-----------------------|--------|--------|
| `bruteForceProtected` | false  | true   |
| `failureFactor`       | 30     | 10     |

Client (rendered with the real base URL) -- intended differences only:

| Attribute                   | Change                              |
|-----------------------------|-------------------------------------|
| `redirectUris`              | mixed-case variant removed          |
| `webOrigins`                | mixed-case variant removed          |
| `post.logout.redirect.uris` | mixed-case variant removed          |

## 4. Runtime variables

See [`examples/environment.example`](../examples/environment.example)
and the [README](../README.md#setup). Secrets are read from files
(`*_FILE`), so any character is allowed.

## 5. Notes for the implementation

-   Host prerequisites: `docker`, `jq`.
-   `kcadm.sh update` merges the supplied JSON into the existing
    representation (GET, merge, PUT): unmanaged settings stay untouched.
    `--no-merge` is not used for configuration objects.
-   A client update does not change existing protocol mappers; they are
    reconciled separately via `clients/<id>/protocol-mappers/models`.
-   Order: realm → groups → client → users.

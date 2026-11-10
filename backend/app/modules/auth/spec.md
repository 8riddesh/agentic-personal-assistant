# Module spec — `backend/auth`

> Status: draft v1 · 2026-11-08 · Governed by `constitution.md` (P1, P12) and `plan.md` (§4.1, §5.1, §6.1, §12.1).
> Milestone: M1. **Status: implemented** (2026-11-09); AUTH-AC-01..10 are covered by `tests/auth/test_auth.py`.
> `current_user` and the services use `SessionDep` (the function-scoped session of core) so a request shares one session.

## 1. Purpose & scope

Serves **C1** (email + password login, single user).

In scope: the single `user_account` row, seeding it from `OWNER_EMAIL` / `OWNER_PASSWORD_HASH` at startup, the
`hash_password` CLI, argon2id verification via pwdlib, `POST /api/v1/auth/login`, HS256 JWT issue/verify, the
`current_user` FastAPI dependency, and invalidation of all tokens via `token_version`.

**Explicitly out of scope (user decision, P1):** sign-up, OAuth, 2FA, refresh tokens, roles, password-reset flows or
emails, account lockout, a rate-limiter service, session tables, logout endpoint. A JWT is valid until it expires
(30 days) or `token_version` is bumped.

## 2. Folder layout

```
app/modules/auth/
├── spec.md
├── __init__.py        # exports: current_user, AuthService, get_auth_service, UserDTO, TokenDTO, LoginRequest
├── api.py             # router: POST /auth/login
├── service.py         # AuthService (login, ensure_owner)
├── security.py        # PasswordHasher wrapper over pwdlib; encode_jwt / decode_jwt (pure functions)
├── dependencies.py    # current_user (HTTPBearer → UserDTO)
├── hash_password.py   # CLI: `uv run python -m app.modules.auth.hash_password`
├── models.py          # UserAccount ORM (private)
├── repository.py      # UserAccountRepository (private)
└── schemas.py         # LoginRequest, TokenDTO, UserDTO, JwtClaims
```

## 3. Dependencies

- **Internal:** `core` only (`Base`, mixins, `get_session`, `get_settings`, `get_clock`, `Clock`, `AuthenticationError`,
  `DomainValidationError`, `AppSettingsService`, `AppSettingsPatch`, `get_logger`). No other module imports `auth`
  except `app.main` (enforced by import-linter, core spec §7.8).
- **Third-party:** `pwdlib[argon2]`, `PyJWT`, `fastapi` (`HTTPBearer`), `pydantic` (`EmailStr`).

## 4. Data owned

### `user_account` (exactly one row)

| Column | SQL type | Null | Default | Notes |
|---|---|---|---|---|
| id | uuid | no | app-side `uuid4()` | PK; JWT `sub` |
| singleton | boolean | no | `true` | `UNIQUE`, `CHECK (singleton)` → at most one row |
| email | text | no | — | `UNIQUE`; stored normalised (`strip().lower()`); plaintext (login lookup; no 🔒) |
| password_hash | text | no | — | PHC string, `$argon2id$...` |
| token_version | integer | no | `1` | `CHECK (token_version >= 1)`; bump to revoke all JWTs |
| last_login_at | timestamptz | yes | `NULL` | |
| created_at, updated_at | timestamptz | no | `now()` | `TimestampMixin` |

No 🔒 columns. Migration: `auth: create user_account` (table only; the row is seeded at app startup, not in the
migration, so no credential ever lives in the repo).

## 5. Public interface

```python
# dependencies.py (canonical, plan §4.1)
async def current_user(
    credentials: HTTPAuthorizationCredentials | None = Depends(HTTPBearer(auto_error=False)),
    session: AsyncSession = Depends(get_session),
    settings: Settings = Depends(get_settings),
    clock: Clock = Depends(get_clock),
) -> UserDTO: ...


# service.py
class AuthService:
    def __init__(
        self, session: AsyncSession, settings: Settings, clock: Clock, hasher: PasswordHasher | None = None
    ) -> None: ...
    async def login(self, email: str, password: str) -> TokenDTO: ...  # canonical signature
    async def ensure_owner(
        self, email: str, password_hash: str
    ) -> bool: ...  # True if inserted; startup seeding


def get_auth_service(
    session=Depends(get_session), settings=Depends(get_settings), clock=Depends(get_clock)
) -> AuthService: ...


# security.py (module-private helpers, used by service/dependencies/CLI)
class PasswordHasher:  # thin wrapper over pwdlib.PasswordHash((Argon2Hasher(),))
    def hash(self, password: str) -> str: ...
    def verify_and_update(self, password: str, hash_: str) -> tuple[bool, str | None]: ...
    def is_supported_hash(self, hash_: str) -> bool: ...  # identifies $argon2id$


def encode_jwt(claims: JwtClaims, secret: str) -> str: ...
def decode_jwt(token: str, secret: str) -> JwtClaims: ...  # raises AuthenticationError(code="invalid_token")
```

### DTOs

```python
class LoginRequest(BaseModel):  # extra="forbid"
    email: EmailStr
    password: str = Field(min_length=1, max_length=1024)
    timezone: str | None = Field(default=None, max_length=64)  # extra: device IANA tz (core spec Q2)


class TokenDTO(BaseModel):
    access_token: str
    token_type: Literal["bearer"] = "bearer"  # extra field
    expires_at: datetime  # UTC, ISO 8601


class UserDTO(BaseModel):
    id: UUID
    email: EmailStr


class JwtClaims(BaseModel):
    sub: UUID
    ver: int
    iat: int
    exp: int  # NumericDate seconds
```

## 6. HTTP endpoints

### `POST /api/v1/auth/login` — public

Request:
```json
{"email": "Me@Example.com", "password": "correct horse battery staple", "timezone": "Europe/Bucharest"}
```

| Status | Body |
|---|---|
| 200 | `{"access_token":"eyJhbGciOiJIUzI1NiIs...","token_type":"bearer","expires_at":"2026-12-08T07:20:00Z"}` |
| 401 | problem, `code:"invalid_credentials"`, `detail:"Email or password is incorrect."` — identical for unknown email and wrong password |
| 422 | problem, `code:"validation_failed"` (malformed email, missing field, password > 1024 chars); input values never echoed |

### Protected routes (all others except `/health`)

`current_user` is attached by `app.main` at router mount. Failures → 401 `application/problem+json` with header
`WWW-Authenticate: Bearer`:

| Condition | `code` |
|---|---|
| No / non-Bearer `Authorization` header | `not_authenticated` |
| Bad signature, malformed, wrong `alg`, missing claim, `sub` not a UUID, user not found, `ver` ≠ `token_version` | `invalid_token` |
| `exp` ≤ now | `token_expired` |

The mobile app treats any 401 as "re-login".

## 7. Behaviour & rules

### 7.1 Seeding (`ensure_owner`, called from `app.main` lifespan in its own `session_scope`)
1. Validate `OWNER_PASSWORD_HASH` with `hasher.is_supported_hash` (must start with `$argon2id$`); otherwise abort
   startup with `"OWNER_PASSWORD_HASH is not an argon2id hash"` (value never printed).
2. `email = OWNER_EMAIL.strip().lower()`.
3. If a `user_account` row exists → **leave it unchanged** (plan §6.1). If its email differs from the configured one,
   log WARNING `owner_email_mismatch` (no values). Return `False`.
4. Else insert `{email, password_hash, token_version: 1}`; on `IntegrityError` (concurrent start) roll back and
   treat as existing. Return `True`. Log INFO `owner_seeded`.

### 7.2 Login (`AuthService.login`)
1. `email_n = email.strip().lower()`; `user = repo.get_by_email(email_n)`.
2. `target_hash = user.password_hash if user else self._dummy_hash` — `_dummy_hash` is a module-level argon2id hash of
   a random 32-byte secret computed once (lazily, first use) with the same parameters, so unknown-email and
   wrong-password paths both perform one full argon2 verification (timing equalisation).
3. `ok, new_hash = await run_in_threadpool(hasher.verify_and_update, password, target_hash)` — argon2 is CPU/memory
   bound (~50–100 ms, 64 MiB with pwdlib defaults) and must not block the event loop.
4. If `user is None or not ok` → raise `AuthenticationError(code="invalid_credentials")`. No counter, no lockout.
5. If `new_hash` (pwdlib parameters changed) → `user.password_hash = new_hash`.
6. `now = clock.now_utc()`; `user.last_login_at = now`.
7. Claims: `sub=str(user.id)`, `ver=user.token_version`, `iat=int(now.timestamp())`,
   `exp=iat + JWT_TTL_DAYS*86400`. Token: `jwt.encode(claims, JWT_SECRET, algorithm="HS256")`.
8. Timezone bootstrap: if `timezone` was supplied and `AppSettingsService.get().timezone_confirmed` is `False`, call
   `AppSettingsService.update(AppSettingsPatch(timezone=timezone))`. An invalid tz is ignored (log WARNING
   `login_timezone_ignored`) — it never fails a login. (Wired in `api.py`, which receives `timezone` from
   `LoginRequest`; `AuthService.login` keeps the canonical signature.)
9. Return `TokenDTO(access_token, expires_at=datetime.fromtimestamp(exp, UTC))`. Session commit by `get_session`.

### 7.3 `current_user`
1. Missing credentials or scheme ≠ `bearer` (case-insensitive) → `not_authenticated`.
2. `jwt.decode(token, JWT_SECRET, algorithms=["HS256"], options={"require": ["sub","ver","iat","exp"],
   "verify_exp": False})` — `algorithms` pinned (rejects `none`/RS*); `exp` is checked against the injected
   `Clock` (step 4) so tests are deterministic. Any `jwt.InvalidTokenError` → `invalid_token`.
3. Parse into `JwtClaims` (pydantic) → failure → `invalid_token`.
4. `claims.exp <= int(clock.now_utc().timestamp())` → `token_expired` (leeway 0).
5. `user = repo.get(claims.sub)`; `None` → `invalid_token`; `claims.ver != user.token_version` → `invalid_token`.
6. Return `UserDTO(id, email)`. One indexed PK lookup per request — acceptable for one user and required for
   `ver` checks. FastAPI caches the dependency per request and shares the request's session.

### 7.4 Token invalidation & password change (operational, no endpoint)
- Revoke all tokens: `UPDATE user_account SET token_version = token_version + 1, updated_at = now();`
  (Supabase SQL editor).
- Change password: run the CLI to get a new hash, then
  `UPDATE user_account SET password_hash = '<hash>', token_version = token_version + 1, updated_at = now();`
  and update `OWNER_PASSWORD_HASH` on Render so a fresh DB seeds the same credentials.
- Rotating `JWT_SECRET` also invalidates every token.

### 7.5 `hash_password` CLI
`uv run python -m app.modules.auth.hash_password [--stdin]`
- Imports only `security.PasswordHasher` (+ stdlib); must run with **no env vars set** (core `Settings` is never
  instantiated at import time — core spec §7.1).
- Default: `getpass("Password: ")` and `getpass("Repeat: ")`; mismatch → stderr message, exit 1; length < 8 → exit 2.
- `--stdin`: reads one line from stdin (trailing newline stripped) for scripted use; no repeat prompt.
- Prints the PHC hash on **stdout** only; prints to stderr a hint: the hash contains `$` — wrap it in single quotes in
  shells / `.env`, paste as-is in the Render dashboard.
- Never prints or logs the password.

### 7.6 Constant-time behaviour
- Unknown email and wrong password: same status, body, and one argon2 verify each (step 7.2.2).
- Hash comparison is performed inside argon2-cffi (constant-time); JWT signature comparison inside PyJWT
  (`hmac.compare_digest`). No manual string comparison of secrets anywhere.
- Email lookup timing differences (index hit vs miss) are negligible relative to argon2 and are accepted.

## 8. Configuration

| Var | Use | Default |
|---|---|---|
| `OWNER_EMAIL` | seed email | required |
| `OWNER_PASSWORD_HASH` | seed hash (argon2id PHC) | required |
| `JWT_SECRET` | HS256 key, ≥ 32 chars (e.g. `python -c "import secrets;print(secrets.token_urlsafe(48))"`) | required |
| `JWT_TTL_DAYS` | token lifetime | `30` |

argon2 parameters: pwdlib/argon2-cffi defaults (RFC 9106 low-memory profile: t=3, m=64 MiB, p=4) — fits 512 MB.

## 9. Errors & degradation

| Situation | Behaviour |
|---|---|
| Invalid credentials | 401 `invalid_credentials` |
| DB down during login / token check | 500 `internal_error` (core) — not disguised as 401 |
| `OWNER_*` missing/invalid at startup | startup aborts (fail fast) |
| Settings update for timezone fails | login still succeeds; WARNING logged |

## 10. Security & privacy notes

- Passwords never logged, echoed, or stored in plaintext; request-validation errors drop `input` (core §7.5).
- Log events: `login_succeeded` / `login_failed` with `request_id` only — no email, no password, no token.
- JWT carries only `sub`, `ver`, `iat`, `exp` (no email). Stored on the phone in secure storage (P12).
- HTTPS is terminated by Render; tokens only travel over TLS.
- The user explicitly declined extra layers (lockout, rate limiting, 2FA); argon2 cost is the brute-force brake.

## 11. Testing plan

Fixtures: `owner_hash` (pwdlib hash of `"test-password-123"` computed once per session), `settings` with
`OWNER_EMAIL=owner@example.com`, `fake_clock`, `seeded_owner` (calls `ensure_owner`), `client`, `make_token(**claims)`.

| Test | Kind |
|---|---|
| `test_ensure_owner_inserts_when_empty`, `test_ensure_owner_leaves_existing_row_unchanged`, `test_ensure_owner_email_mismatch_logs_warning_without_values`, `test_ensure_owner_rejects_non_argon2id_hash` | integration |
| `test_login_success_returns_token_and_expiry` (FakeClock → `expires_at` = now + 30 d), `test_login_normalises_email_case`, `test_login_updates_last_login_at` | integration |
| `test_login_wrong_password_401`, `test_login_unknown_email_401_same_body`, `test_login_unknown_email_runs_dummy_verify` (spy on hasher: called once) | unit |
| `test_login_rehashes_when_params_outdated` | unit |
| `test_login_sets_timezone_when_unconfirmed`, `test_login_does_not_override_confirmed_timezone`, `test_login_ignores_invalid_timezone` | integration |
| `test_jwt_claims_exact_set` (sub, ver, iat, exp only; alg HS256) | unit |
| `test_current_user_missing_header_401`, `test_current_user_bad_signature_401`, `test_current_user_alg_none_rejected`, `test_current_user_expired_401` (FakeClock advanced 30 d + 1 s), `test_current_user_version_bump_revokes`, `test_current_user_unknown_sub_401` | integration |
| `test_protected_route_requires_token` (e.g. `GET /api/v1/settings`), `test_health_and_login_are_public` | integration |
| `test_hash_password_cli_stdin_outputs_argon2id` (subprocess with empty env), `test_hash_password_cli_mismatch_exit_1`, `test_hash_password_cli_short_exit_2` | unit |
| `test_password_never_logged` (caplog over success + failure) | unit |

## 12. Acceptance criteria

| ID | Given / When / Then | Test |
|---|---|---|
| AUTH-AC-01 | Given an empty `user_account` and valid `OWNER_*`, when the app starts, then exactly one row exists with the normalised email | `test_ensure_owner_inserts_when_empty` |
| AUTH-AC-02 | Given an existing row and different `OWNER_*` values, when the app restarts, then the row is unchanged | `test_ensure_owner_leaves_existing_row_unchanged` |
| AUTH-AC-03 | Given correct credentials, when `POST /auth/login`, then 200 with an HS256 JWT whose claims are exactly `sub, ver, iat, exp` and `expires_at = now + JWT_TTL_DAYS` | `test_login_success_returns_token_and_expiry`, `test_jwt_claims_exact_set` |
| AUTH-AC-04 | Given a wrong password or unknown email, when login, then 401 `invalid_credentials` with identical bodies, and one argon2 verification ran in both cases | `test_login_wrong_password_401`, `test_login_unknown_email_401_same_body`, `test_login_unknown_email_runs_dummy_verify` |
| AUTH-AC-05 | Given no/invalid/`alg:none` token, when calling a protected route, then 401 problem with `WWW-Authenticate: Bearer` | `test_current_user_missing_header_401`, `test_current_user_bad_signature_401`, `test_current_user_alg_none_rejected` |
| AUTH-AC-06 | Given a token issued 30 days + 1 s ago, when used, then 401 `token_expired` | `test_current_user_expired_401` |
| AUTH-AC-07 | Given a valid token, when `token_version` is incremented, then the token is rejected with 401 `invalid_token` | `test_current_user_version_bump_revokes` |
| AUTH-AC-08 | Given `timezone_confirmed=false`, when login includes `timezone`, then app_settings.timezone is set and confirmed; a later login does not change it | `test_login_sets_timezone_when_unconfirmed`, `test_login_does_not_override_confirmed_timezone` |
| AUTH-AC-09 | Given no env vars, when running the hash CLI with a password on stdin, then it prints an `$argon2id$` hash that `ensure_owner` accepts | `test_hash_password_cli_stdin_outputs_argon2id` |
| AUTH-AC-10 | Given any login attempt, then no log record contains the password, token, or email | `test_password_never_logged` |

## 13. Open questions

- **Q1:** Password change / revoke-all is an operational SQL step (§7.4). Is that acceptable, or should a
  `OWNER_RESEED=true` startup flag (overwrite hash + bump `token_version`) be added? Kept out for simplicity.
- **Q2 (plan §5.2 / §6.1):** the optional `timezone` field on `LoginRequest` is an addition to the plan's
  `{email, password}` body, used to satisfy "timezone default from device on first login". Mobile `app_shell` must
  send it (or PATCH `/settings`). Coordinate.
- **Q3:** plan §5 says `created_at/updated_at` on every table; §5.1 omits them for `user_account` — added here.

# Module spec — `backend/core`

> Status: draft v1 · 2026-11-08 · Governed by `constitution.md` and `plan.md` (§2.3, §4.1, §5.2, §7, §12.1, §13, §15).
> Milestone: M0 (config, db, errors, logging, health, main) / M1 (app_settings).
> **M0 status: implemented.** Not yet built (M1): `models.py`, `repository.py`, `service.py`, the `/settings` router,
> `AppSettings*` DTOs, the `app_settings` migration, the `crypto.CryptoError` handler, and mounting of auth-guarded
> routers in `app/main.py`. `migrations/versions/` is empty, so `alembic upgrade head` is a no-op until M1.

## 1. Purpose & scope

`core` is the foundation every other backend module depends on. It owns:

| Concern | Serves |
|---|---|
| Typed configuration (`Settings`) for every env var in plan §12.1 | all capabilities |
| Async SQLAlchemy engine / session for Supabase (Supavisor **session** pooler) | all persistence |
| Declarative `Base`, UUID PK + timestamp mixins, constraint naming convention, Alembic conventions | all persistence |
| `Clock` protocol + `SystemClock` / `FakeClock` | C5–C9 (all day/time logic) |
| `app_settings` single row + `AppSettingsService` + `GET/PATCH /api/v1/settings` | C5 (offsets), C8/C9 (timezone), C10 (report email) |
| Domain error hierarchy → RFC 7807 `application/problem+json` | all endpoints |
| Structured JSON logging with request id, no personal text | P11, P12 |
| `GET /health` (liveness + DB ping, public) | CI deploy check (§13) |
| Composition-root contract for `app/main.py` and import-linter boundary contracts | ADR-001, §3.1 |

**Out of scope:** authentication (`auth`), encryption primitives (`crypto` — core only *uses* `EncryptedText`),
background schedulers (none exist, §2.3), CORS (the only client is a native Android app), rate limiting.

## 2. Folder layout

```
app/modules/core/
├── spec.md
├── __init__.py      # public exports listed in §5 only
├── config.py        # Settings (pydantic-settings), get_settings() (lru_cache), no import-time instantiation
├── db.py            # NAMING_CONVENTION, Base, UUIDPkMixin, TimestampMixin, build_engine(), build_session_factory(),
│                    #   get_session() dependency, session_scope() for background work, db_ping()
├── clock.py         # Clock Protocol, SystemClock, FakeClock, get_clock() dependency
├── errors.py        # AppError hierarchy, ProblemDetails builder, install_error_handlers(app)
├── logs.py          # configure_logging(), JsonFormatter, RedactingFilter, RequestContextMiddleware, get_logger()
│                    #   (named logs.py, not logging.py, to avoid confusion with stdlib)
├── models.py        # AppSettings ORM (private)
├── repository.py    # AppSettingsRepository (private)
├── schemas.py       # AppSettingsDTO, AppSettingsPatch, HealthDTO, ProblemDetails
├── service.py       # AppSettingsService
└── api.py           # settings_router (/settings), health_router (/health)
```

`app/main.py` (composition root) is specified in §7.7 of this spec because core defines its contract.

## 3. Dependencies

- **Internal:** `crypto` only (for `EncryptedText` on `app_settings.report_email`). `crypto` must therefore never import
  `core` (see crypto spec §3). No other module may be imported by core.
- **Third-party:** `fastapi`, `starlette`, `pydantic`, `pydantic-settings`, `email-validator`, `sqlalchemy[asyncio]`,
  `asyncpg`, `alembic`, `tzdata` (zoneinfo data in slim Docker images), `uvicorn`.
- **Dev:** `pytest`, `pytest-asyncio`, `pytest-cov`, `httpx`, `freezegun` (not used for Clock — FakeClock is preferred),
  `import-linter`, `grimp` (transitively via import-linter).

## 4. Data owned

### 4.1 `app_settings` (exactly one row)

| Column | SQL type | Null | Default | Notes |
|---|---|---|---|---|
| id | uuid | no | app-side `uuid4()` | PK |
| singleton | boolean | no | `true` | `UNIQUE`, `CHECK (singleton)` → at most one row |
| timezone | text | no | `'UTC'` | IANA key; validated with `zoneinfo.ZoneInfo` on write |
| timezone_confirmed | boolean | no | `false` | becomes `true` on first explicit timezone write (device tz on first login, see auth spec §7.2) |
| reminder_offsets_min | integer[] | no | `'{60,30}'` | `CHECK (cardinality(reminder_offsets_min) BETWEEN 1 AND 2)` |
| report_email 🔒 | text | yes | `NULL` | `EncryptedText(aad="app_settings.report_email")` |
| week_start | smallint | no | `1` | ISO weekday 1=Mon..7=Sun, `CHECK (week_start BETWEEN 1 AND 7)` (see Open questions Q3) |
| created_at | timestamptz | no | `now()` | |
| updated_at | timestamptz | no | `now()` | ORM `onupdate=func.now()` |

Migration `core: create app_settings` creates the table **and inserts the default row** (data migration). The
repository additionally does get-or-create (defensive; race-free because of the `singleton` unique constraint →
on `IntegrityError` re-select).

### 4.2 Persistence conventions (binding for all modules)

- `Base = DeclarativeBase` subclass with `metadata = MetaData(naming_convention=NAMING_CONVENTION)`:
  `ix: "ix_%(table_name)s_%(column_0_N_name)s"`, `uq: "uq_%(table_name)s_%(column_0_N_name)s"`,
  `ck: "ck_%(table_name)s_%(constraint_name)s"`, `fk: "fk_%(table_name)s_%(column_0_name)s_%(referred_table_name)s"`,
  `pk: "pk_%(table_name)s"`.
- `UUIDPkMixin`: `id: Mapped[UUID] = mapped_column(Uuid(as_uuid=True), primary_key=True, default=uuid4)`.
- `TimestampMixin`: `created_at`, `updated_at` as `DateTime(timezone=True)`, `server_default=func.now()`, `updated_at`
  with `onupdate=func.now()`. All datetimes in Python are tz-aware UTC; naive datetimes are a bug.
- Enums: `sqlalchemy.Enum(PyEnum, native_enum=False, create_constraint=True, length=32, values_callable=...)`
  (varchar + CHECK) — cheaper migrations than native PG enums.
- Table names: singular snake_case, owned by exactly one module; no cross-module FKs unless plan §5 lists them.
- 🔒 columns use `crypto` TypeDecorators; never filtered/sorted in SQL.

### 4.3 Alembic conventions

- Location `backend/migrations/`, `alembic.ini` at `backend/`. Single linear history (CI asserts exactly one head).
- **One migration per module change**; a migration touches only one module's tables. Message format
  `"<module>: <change>"`, e.g. `core: create app_settings`. `file_template =
  %%(year)d%%(month).2d%%(day).2d_%%(hour).2d%%(minute).2d_%%(rev)s_%%(slug)s`.
- `env.py` is async (`async_engine_from_config` + `connection.run_sync(do_run_migrations)`), uses `Settings().database_url`
  with the same SSL connect args as the app (§7.2), and imports every module's `models` to populate `Base.metadata`
  (`migrations/` is outside the `app` package, so the boundary contract does not apply to it).
- `render_item` hook renders `EncryptedText`/`EncryptedJSON` as `sa.Text()` and `EncryptedBytes` as `sa.LargeBinary()`;
  `compare_type` compares on `impl` so autogenerate is clean.
- Every migration implements `downgrade()`. Hand-review autogenerated output; data migrations must not contain
  personal plaintext.
- Container start: `alembic upgrade head && uvicorn app.main:app ...` (plan §13).

## 5. Public interface (`app/modules/core/__init__.py`)

```python
# config
class Settings(BaseSettings): ...  # fields in §8


def get_settings() -> Settings: ...  # @lru_cache; FastAPI dependency; overridable in tests


# db
NAMING_CONVENTION: dict[str, str]


class Base(DeclarativeBase): ...


class UUIDPkMixin: ...


class TimestampMixin: ...


type SessionFactory = async_sessionmaker[AsyncSession]


def build_engine(settings: Settings) -> AsyncEngine: ...
def build_session_factory(engine: AsyncEngine) -> SessionFactory: ...
async def get_session(request: Request) -> AsyncIterator[AsyncSession]: ...  # dependency, one tx per request
@asynccontextmanager
async def session_scope(factory: SessionFactory) -> AsyncIterator[AsyncSession]: ...  # background work
async def db_ping(engine: AsyncEngine, timeout_s: float = 3.0) -> bool: ...


# clock  (canonical, plan §4.1)
class Clock(Protocol):
    def now_utc(self) -> datetime: ...
    def today_local(self, tz: ZoneInfo) -> date: ...


class SystemClock: ...  # implements Clock


class FakeClock:  # implements Clock; for tests
    def __init__(self, start: datetime) -> None: ...  # start must be tz-aware; stored as UTC
    def set(self, at: datetime) -> None: ...
    def advance(self, delta: timedelta) -> None: ...


def get_clock(request: Request) -> Clock: ...  # returns app.state.clock


# settings service (canonical, plan §4.1)
class AppSettingsService:
    def __init__(self, session: AsyncSession) -> None: ...
    async def get(self) -> AppSettingsDTO: ...
    async def update(self, patch: AppSettingsPatch) -> AppSettingsDTO: ...
    async def tz(self) -> ZoneInfo: ...


def get_app_settings_service(session: AsyncSession = Depends(get_session)) -> AppSettingsService: ...


# errors (canonical four + AuthenticationError added for auth)
class AppError(Exception):
    status: int
    code: str
    title: str
    detail: str | None
    extra: dict
    headers: dict


class NotFoundError(AppError): ...  # 404


class ConflictError(AppError): ...  # 409


class DomainValidationError(AppError): ...  # 422


class UpstreamError(AppError): ...  # 502 (503 when retryable=True)


class AuthenticationError(AppError): ...  # 401, adds WWW-Authenticate: Bearer


def install_error_handlers(app: FastAPI) -> None: ...


# logging
def configure_logging(settings: Settings) -> None: ...
def get_logger(name: str) -> logging.Logger: ...


class RequestContextMiddleware: ...  # pure ASGI middleware
```

Every `AppError` subclass constructor: `(detail: str | None = None, *, code: str | None = None, **extra)`; `code`
defaults per class (`not_found`, `conflict`, `validation_failed`, `upstream_unavailable`, `not_authenticated`).

### 5.1 DTOs (`schemas.py`)

```python
class AppSettingsDTO(BaseModel):
    timezone: str  # IANA key
    timezone_confirmed: bool  # extra field (see §4.1)
    reminder_offsets_min: list[int]  # sorted descending, e.g. [60, 30]
    report_email: EmailStr | None
    week_start: int  # 1..7 ISO
    updated_at: datetime


class AppSettingsPatch(BaseModel):  # model_config: extra="forbid"; only fields present are applied
    timezone: str | None = None  # null not allowed when present
    reminder_offsets_min: list[int] | None = None
    report_email: EmailStr | None = None  # explicit null clears it
    week_start: int | None = None


class HealthDTO(BaseModel):
    status: Literal["ok", "degraded"]
    db: Literal["ok", "unavailable"]
    env: str
    version: str
    time: datetime


class ProblemDetails(BaseModel):
    type: str
    title: str
    status: int
    detail: str | None
    instance: str
    code: str
    request_id: str
    errors: list[FieldError] | None = None


class FieldError(BaseModel):
    loc: list[str | int]
    msg: str
    type: str
```

## 6. HTTP endpoints

| Method & path | Auth | Request | Responses |
|---|---|---|---|
| `GET /health` (root, **not** under `/api/v1`) | public | — | 200 `HealthDTO` (`status:"ok"`), 503 `HealthDTO` (`status:"degraded"`, `db:"unavailable"`) |
| `GET /api/v1/settings` | Bearer | — | 200 `AppSettingsDTO`; 401 problem |
| `PATCH /api/v1/settings` | Bearer | `AppSettingsPatch` (`application/json`) | 200 `AppSettingsDTO`; 401; 422 problem |

Examples:

```http
GET /health  →  200
{"status":"ok","db":"ok","env":"prod","version":"3f2c1ab","time":"2026-11-08T07:15:02Z"}

PATCH /api/v1/settings
{"timezone":"Europe/Bucharest","report_email":"me@example.com"}
→ 200
{"timezone":"Europe/Bucharest","timezone_confirmed":true,"reminder_offsets_min":[60,30],
 "report_email":"me@example.com","week_start":1,"updated_at":"2026-11-08T07:16:40Z"}

PATCH /api/v1/settings {"timezone":"Mars/Olympus"}
→ 422 application/problem+json
{"type":"/problems/validation-failed","title":"Validation failed","status":422,
 "detail":"Request body is invalid.","instance":"/api/v1/settings","code":"validation_failed",
 "request_id":"01J...","errors":[{"loc":["body","timezone"],"msg":"unknown IANA timezone","type":"value_error"}]}
```

PATCH validation: `timezone` loadable by `ZoneInfo` and not `"localtime"`; `reminder_offsets_min` 1–2 distinct ints
in `5..240`, stored sorted descending; `week_start` 1..7; unknown keys → 422; empty body `{}` → 200 unchanged.

## 7. Behaviour & rules

### 7.1 Configuration
- `Settings` is instantiated only by `get_settings()` (cached) — **never at import time**, so CLIs such as
  `auth.hash_password` import cleanly without env vars.
- `.env` file is read in `dev` only (`env_file=".env"` ignored when absent); `extra="ignore"`; names case-insensitive.
- `database_url` validator: `postgresql://` / `postgres://` → `postgresql+asyncpg://`; strip `sslmode`/`ssl` query
  params (asyncpg rejects `sslmode`) and map them to `database_ssl` if that was not set explicitly.
- `jwt_secret` length ≥ 32; `jwt_ttl_days` 1..365; `encryption_active_key_id` 1..255.
- Validation failure → process exits at startup with a message naming the field, **never its value**.

### 7.2 Engine & sessions (Supabase via Supavisor session pooler)
- `create_async_engine(url, pool_size=DB_POOL_SIZE(3), max_overflow=DB_MAX_OVERFLOW(2), pool_timeout=10,
  pool_recycle=1800, pool_pre_ping=True, echo=False)` — echo is never enabled (would log bound parameters).
- `connect_args`: `{"ssl": <ctx>, "timeout": 10, "command_timeout": 30,
  "server_settings": {"application_name": "daily-assistant"}}`. `DATABASE_SSL`: `require` (default; encrypted,
  no cert verification — `ssl.create_default_context()` with `check_hostname=False, verify_mode=CERT_NONE`),
  `verify-full` (default context + optional `DATABASE_SSL_ROOT_CERT` path to Supabase CA), `disable` (local/CI
  Postgres container only; rejected when `ENV=prod`).
- Pool sizing rationale: one Uvicorn worker on 512 MB; ≤ 5 concurrent DB connections is ample for one user and stays
  well under the free-tier pooler client limit (verify current Supabase limits at implementation).
- **Session mode (port 5432)** keeps a dedicated server connection per client connection, so asyncpg's prepared
  statement cache works unchanged. If ever switched to **transaction mode (port 6543)**, prepared statements break:
  set `connect_args["statement_cache_size"]=0`, `prepared_statement_cache_size=0` (SQLAlchemy asyncpg dialect arg)
  and `prepared_statement_name_func=lambda: f"__asyncpg_{uuid4()}__"`, consider `poolclass=NullPool`. Not used in v1.
- `build_session_factory`: `async_sessionmaker(engine, expire_on_commit=False, autoflush=False)`.
- `get_session`: opens a session from `request.app.state.session_factory`; yields; on normal exit `commit()`, on
  exception `rollback()` and re-raise; always `close()`. Services **never** commit. Commit must complete before the
  response is sent — FastAPI's yield-dependency exit timing is version-dependent. **Resolved (M0):** FastAPI ≥ 0.121
  supports `Depends(get_session, scope="function")`, which ends the dependency before the response is sent. Modules
  inject the exported alias `SessionDep = Annotated[AsyncSession, Depends(get_session, scope="function")]`;
  `test_write_committed_before_response` probes the DB at `http.response.start` (SQLite/aiosqlite, no Postgres needed).
- `session_scope(factory)`: same semantics for background tasks (EOD pipeline) which must not reuse the request
  session.
- `db_ping`: `SELECT 1` on a pooled connection inside `asyncio.wait_for(timeout_s)`; returns bool, never raises.

### 7.3 Clock
- `SystemClock.now_utc()` → `datetime.now(UTC)`. `today_local(tz)` → `self.now_utc().astimezone(tz).date()`.
- `FakeClock` rejects naive datetimes (`ValueError`), stores UTC, `advance` accepts negative deltas.
- All modules obtain time **only** via `Clock` (no `datetime.now()` elsewhere; ruff `DTZ` rules enabled).
- `app.state.clock` is `SystemClock()`; tests replace it with `FakeClock`.

### 7.4 AppSettingsService
- `get()`: repository get-or-create → DTO (`report_email` decrypted transparently by the TypeDecorator).
- `update(patch)`: `fields = patch.model_dump(exclude_unset=True)`; validate (§6); apply; if `timezone` in fields →
  `timezone_confirmed = True`; flush; return DTO. Setting `timezone: null` → `DomainValidationError`.
- `tz()`: `ZoneInfo(get().timezone)`; memoised on the service instance (per request).
- Changing timezone does not rewrite stored data (all UTC). The already-open `day_session.local_date` is unaffected;
  day logic uses the new tz from the next `GET /days/current` (day_cycle owns the consequences).

### 7.5 Errors → RFC 7807
`install_error_handlers` registers handlers that always return `application/problem+json`:

| Source | status | code | type |
|---|---|---|---|
| `NotFoundError` | 404 | `not_found` (or custom) | `/problems/not-found` |
| `ConflictError` | 409 | `conflict` | `/problems/conflict` |
| `DomainValidationError` | 422 | `validation_failed` | `/problems/validation-failed` |
| `UpstreamError` | 502 / 503 (`retryable`) | `upstream_unavailable` | `/problems/upstream-unavailable` |
| `AuthenticationError` | 401 + `WWW-Authenticate: Bearer` | `not_authenticated`, `invalid_credentials`, `invalid_token`, `token_expired` | `/problems/unauthorized` |
| `RequestValidationError` (FastAPI) | 422 | `validation_failed` | errors list with `loc`, `msg`, `type` — **`input` and `ctx` dropped** (they echo personal text) |
| Starlette `HTTPException` (404 route, 405) | as raised | `http_<status>` | `/problems/http-<status>` |
| `crypto.CryptoError` | 500 | `data_integrity` | `/problems/internal` (logged at ERROR, no values) |
| any other `Exception` | 500 | `internal_error` | `/problems/internal`; `detail` generic |

`instance` = request path; `request_id` = current request id. `detail` texts are written by developers and must not
interpolate user-provided text.

### 7.6 Logging
- JSON lines to stdout: `ts, level, logger, msg, request_id, env` + whitelisted extras.
- `RequestContextMiddleware`: request id from `X-Request-ID` (if ≤ 64 chars `[A-Za-z0-9-]`) else ULID/uuid4 hex;
  sets a `ContextVar`; echoes header; logs one access line `{method, route (path template), status, duration_ms}`.
  Query strings and bodies are never logged. Uvicorn access log disabled (`--no-access-log` / log config).
  The request id is also stored in `scope["state"]["request_id"]`: problem responses for *unhandled* errors are
  rendered by Starlette's outer `ServerErrorMiddleware`, where the ContextVar has already been reset.
  The `httpx`/`httpcore` loggers are set to WARNING (httpx logs full request URLs, query strings included, at INFO).
- `RedactingFilter` drops extras whose keys match `password|token|authorization|secret|key|title|notes|content|
  reason|email|recipient|narrative|label|suggestion|draft` and truncates any message > 1000 chars.
- Exceptions logged with traceback but without `locals`; SQLAlchemy `echo` off; SQLAlchemy/asyncpg loggers at WARNING.
- Rule for all modules: log ids, counts, statuses, latencies, enum values — never free text from the user or an AI.

### 7.7 Composition root (`app/main.py`)
`def create_app(settings: Settings | None = None) -> FastAPI`; module-level `app` is created **lazily on first
attribute access** (PEP 562 `__getattr__`), so importing `app.main` needs no environment variables and opens no DB
connection (connections happen in lifespan). uvicorn's `app.main:app` triggers the creation.
`create_app` stores `settings`, `clock` (`SystemClock`) and `shutdown_hooks` on `app.state` and overrides the
`get_settings` dependency with them, so tests can swap `app.state.clock` after creation. The lifespan builds the
engine and session factory.

1. `FastAPI(title="Daily Assistant", docs_url="/docs" if env != "prod" else None, redoc_url=None,
   openapi_url="/openapi.json" if env != "prod" else None, lifespan=lifespan)`.
2. Middleware: `RequestContextMiddleware`. `install_error_handlers(app)`.
3. Routers: `health_router` at root; under prefix `/api/v1`: `auth.api.router` (public); and with
   `dependencies=[Depends(current_user)]` applied **at mount time**: core `settings_router`, `schedule`, `day_cycle`,
   `feasibility`, `tasks`, `predictor`, `assistant`, `reports` routers. Modules therefore never import `auth`.
4. Lifespan startup (in order, any failure aborts start): `configure_logging` → `crypto.configure_cipher(
   FieldCipher.from_config(keys, active_id))` → `build_engine` / `build_session_factory` into `app.state` →
   `app.state.clock = SystemClock()` → in `session_scope`: `AuthService(...).ensure_owner(...)` (auth spec §7.1).
   Shutdown: close provider HTTP clients registered via `app.state.shutdown_hooks`, then `engine.dispose()`.
5. Dependency wiring: each module exports a `get_<x>_service` provider built from `get_session`, `get_clock`,
   `get_settings` and other modules' providers. Tests override via `app.dependency_overrides`.
6. **Lazy heavy imports:** `pandas`, `numpy`, `matplotlib`, `seaborn`, `sklearn`, `jinja2` (prompt rendering) are
   imported inside the functions that use them (reports/predictor), never at module top level of any file reachable
   from `app.main`. `matplotlib.use("Agg")` immediately after the lazy import.
7. Uvicorn: one worker, `--proxy-headers`.

### 7.8 Module boundary contracts (import-linter, CI step `lint-imports`)

Allowed direct dependencies (plan §4; `core` and `crypto` are implicit for every module except the reverse):

| Module | May import |
|---|---|
| crypto | — (leaf) |
| core | crypto |
| auth | core |
| schedule, tasks, ai_gateway | core, crypto |
| email | core, crypto |
| predictor | core, crypto, tasks |
| feasibility | core, crypto, tasks, schedule, predictor, ai_gateway |
| reports | core, crypto, tasks, predictor, feasibility, ai_gateway, email |
| day_cycle | core, crypto, tasks, predictor, reports |
| assistant | core, crypto, ai_gateway, tasks, schedule, day_cycle, reports |

`backend/pyproject.toml` (one `forbidden` contract per module, generated mechanically from the table; two shown):

```toml
[tool.importlinter]
root_packages = ["app"]

[[tool.importlinter.contracts]]
name = "core depends only on crypto"
type = "forbidden"
source_modules = ["app.modules.core"]
forbidden_modules = ["app.main", "app.modules.auth", "app.modules.schedule", "app.modules.tasks",
  "app.modules.day_cycle", "app.modules.ai_gateway", "app.modules.feasibility", "app.modules.predictor",
  "app.modules.assistant", "app.modules.reports", "app.modules.email"]

[[tool.importlinter.contracts]]
name = "only reports may import email (P5: nothing else can trigger a send)"
type = "forbidden"
source_modules = ["app.modules.auth", "app.modules.schedule", "app.modules.tasks", "app.modules.day_cycle",
  "app.modules.ai_gateway", "app.modules.feasibility", "app.modules.predictor", "app.modules.assistant",
  "app.modules.core", "app.modules.crypto"]
forbidden_modules = ["app.modules.email"]
allow_indirect_imports = true      # day_cycle -> reports -> email is legitimate

[[tool.importlinter.contracts]]
name = "no module imports auth (applied at mount time by app.main)"
type = "forbidden"
source_modules = ["app.modules.core", "app.modules.crypto", "app.modules.schedule", "app.modules.tasks",
  "app.modules.day_cycle", "app.modules.ai_gateway", "app.modules.feasibility", "app.modules.predictor",
  "app.modules.assistant", "app.modules.reports", "app.modules.email"]
forbidden_modules = ["app.modules.auth"]
```

All DAG contracts use `allow_indirect_imports = true` (direct edges are what the table governs; the table is acyclic).
**Root-only rule** (plan §3.1): import-linter has no concise "package root only" contract, so
`tests/core/test_boundaries.py` uses `grimp.build_graph("app")` and asserts that for every direct import
`a → b` with `a` in module X and `b` in module Y ≠ X, `b == "app.modules.Y"` exactly. `app.main` is exempt (it
imports `app.modules.*.api`).

## 8. Configuration

All from plan §12.1 unless marked *(added)*. Secrets are `SecretStr`.

| Env var | Type | Default | Required |
|---|---|---|---|
| `ENV` | `dev\|test\|prod` | `dev` | |
| `DATABASE_URL` | SecretStr | — | yes |
| `DATABASE_SSL` *(added)* | `disable\|require\|verify-full` | `require` | |
| `DATABASE_SSL_ROOT_CERT` *(added)* | path | none | |
| `DB_POOL_SIZE`, `DB_MAX_OVERFLOW` *(added)* | int | `3`, `2` | |
| `OWNER_EMAIL`, `OWNER_PASSWORD_HASH` | EmailStr, SecretStr | — | yes |
| `JWT_SECRET`, `JWT_TTL_DAYS` | SecretStr (≥32), int | —, `30` | secret yes |
| `ENCRYPTION_KEYS`, `ENCRYPTION_ACTIVE_KEY_ID` | SecretStr, int | — | yes |
| `OPENROUTER_API_KEY` | SecretStr | none | no (AI degrades) |
| `JEV_MODEL`, `JEV_DAILY_CALL_CAP` | str, int | `typesafe/jev-1.14`, `500` | |
| `GROQ_API_KEY`, `GROQ_MODEL`, `GROQ_FAST_MODEL` | SecretStr, str, str | none | no |
| `GROQ_DAILY_CALL_CAP` *(added; referenced in plan §9.3)* | int | `1000` | |
| `OPENROUTER_TEXT_FALLBACK_MODEL` | str | none | no |
| `EMAIL_PROVIDER` | `brevo\|smtp` | `brevo` | |
| `BREVO_API_KEY`, `EMAIL_FROM` | SecretStr, EmailStr | none | no (email returns `not_configured`) |
| `EMAIL_FROM_NAME`, `EMAIL_INLINE_MODE` *(added, email spec §8)* | str, `attachment\|cid` | `Daily Assistant`, `attachment` | |
| `EMAIL_MAX_TOTAL_BYTES`, `BREVO_BASE_URL` *(added, email spec §8)* | int, URL | `8388608`, `https://api.brevo.com` | |
| `SMTP_HOST`, `SMTP_PORT`, `SMTP_USER`, `SMTP_PASSWORD` | str, int, str, SecretStr | none, `587` | if smtp |
| `FEASIBILITY_WEIGHTS` | JSON → `dict[str, float] \| None` | none (feasibility owns defaults) | |
| `LOG_LEVEL` *(added)* | str | `INFO` | |
| `RENDER_GIT_COMMIT` *(Render-provided)* | str | `dev` | used as `version` (first 7 chars) |

## 9. Errors & degradation

- DB unreachable at startup → `alembic upgrade head` fails first and Render restarts the container; at runtime,
  `/health` returns 503 and request handlers fail with 500 `internal_error` (connection errors are not domain errors).
  Supabase cold/paused projects: `connect timeout=10s`, `pool_pre_ping` recovers stale connections after sleep.
- Missing optional AI/email config is not a startup error (P10); owning modules degrade.
- `app_settings` row missing → recreated with defaults (logged WARNING).

## 10. Security & privacy notes

- `/docs` and `/openapi.json` disabled in prod. No CORS middleware.
- Problem responses never include request input values, stack traces or SQL.
- `Settings.__repr__` hides secrets (`SecretStr`); never log `Settings`.
- `report_email` is encrypted at rest (P11) even though it is low-sensitivity.
- `app_settings` GET/PATCH require Bearer auth (applied at mount).

## 11. Testing plan

Fixtures (`tests/conftest.py`, shared by all modules): `settings` (ENV=test, test keys, `DATABASE_URL` from
`TEST_DATABASE_URL`, `DATABASE_SSL=disable`), `migrated_db` (session-scoped `alembic upgrade head` on the CI Postgres
service container), `db_session` (connection-level transaction + `join_transaction_mode="create_savepoint"`, rolled back
per test), `fake_clock` (`FakeClock(2026-11-08T09:00Z)`), `app` (`create_app(settings)` with overrides),
`client` (`httpx.AsyncClient(transport=ASGITransport(app))`), `auth_headers` (token for seeded test owner).

| Test | Kind |
|---|---|
| `test_settings_require_mandatory_vars`, `test_database_url_scheme_normalised`, `test_sslmode_param_stripped`, `test_settings_errors_hide_values`, `test_settings_not_instantiated_on_import` | unit |
| `test_fake_clock_rejects_naive`, `test_today_local_crosses_midnight_in_tz` (23:30Z → next day in Europe/Bucharest) | unit |
| `test_app_settings_get_creates_default_row`, `test_patch_partial_update`, `test_patch_timezone_sets_confirmed`, `test_patch_invalid_timezone_422`, `test_patch_offsets_rules_422`, `test_patch_unknown_field_422`, `test_report_email_clear_with_null`, `test_report_email_encrypted_at_rest` (raw row) | integration |
| `test_settings_requires_auth` (401 problem) | integration |
| `test_health_ok`, `test_health_db_down_returns_503` (engine pointed at closed port) | integration |
| `test_problem_json_for_each_app_error`, `test_validation_error_drops_input`, `test_unhandled_error_500_generic`, `test_request_id_echoed` | integration |
| `test_logs_are_json_and_redacted` (caplog: no sentinel personal text in any record) | unit |
| `test_write_committed_before_response`, `test_rollback_on_exception` | integration |
| `test_heavy_libs_not_imported_by_main` (subprocess `python -c "import app.main, sys; ..."` asserts `pandas`, `matplotlib`, `seaborn`, `sklearn` ∉ `sys.modules`) | unit |
| `test_boundaries_root_only` (grimp), CI `lint-imports` | static |
| `test_single_alembic_head`, `test_migrations_up_down_up`, `test_models_match_migrations` (autogenerate diff empty) | integration |

## 12. Acceptance criteria

| ID | Given / When / Then | Test |
|---|---|---|
| CORE-AC-01 | Given a running app with a reachable DB, when `GET /health`, then 200 `{"status":"ok","db":"ok"}` without auth | `test_health_ok` |
| CORE-AC-02 | Given the DB is unreachable, when `GET /health`, then 503 `status:"degraded"` within 5 s | `test_health_db_down_returns_503` |
| CORE-AC-03 | Given a fresh DB, when `GET /api/v1/settings` with a valid token, then defaults `UTC`, `[60,30]`, `null`, `1`, `timezone_confirmed=false` | `test_app_settings_get_creates_default_row` |
| CORE-AC-04 | Given settings exist, when PATCH with only `report_email`, then only that field changes and the raw DB value is a `v<id>:` envelope | `test_patch_partial_update`, `test_report_email_encrypted_at_rest` |
| CORE-AC-05 | Given an invalid timezone / offsets / unknown field, when PATCH, then 422 `application/problem+json` with `errors[].loc` and no echoed input | `test_patch_invalid_timezone_422`, `test_patch_offsets_rules_422`, `test_patch_unknown_field_422`, `test_validation_error_drops_input` |
| CORE-AC-06 | Given any `AppError` subclass raised in a handler, then the response is RFC 7807 with the mapped status, `code` and `request_id` | `test_problem_json_for_each_app_error` |
| CORE-AC-07 | Given a request carrying personal text, when it is processed and logged, then no log record contains that text | `test_logs_are_json_and_redacted` |
| CORE-AC-08 | Given `FakeClock` at 2026-11-08T22:30Z and tz `Europe/Bucharest`, when `today_local`, then 2026-11-09 | `test_today_local_crosses_midnight_in_tz` |
| CORE-AC-09 | Given `import app.main`, then pandas/matplotlib/seaborn/sklearn are not loaded | `test_heavy_libs_not_imported_by_main` |
| CORE-AC-10 | Given a module importing another module's `models`/`repository`/`api`, when CI runs, then the build fails | `test_boundaries_root_only`, `lint-imports` |
| CORE-AC-11 | Given the migration history, then there is one head, up/down/up succeeds and models match migrations | `test_single_alembic_head`, `test_migrations_up_down_up`, `test_models_match_migrations` |
| CORE-AC-12 | Given a handler that writes then raises, then nothing is persisted; given a handler that writes and returns, the row is visible to a new session as soon as the response arrives | `test_rollback_on_exception`, `test_write_committed_before_response` |
| CORE-AC-13 | Given no token, when `GET /api/v1/settings`, then 401 problem with `WWW-Authenticate: Bearer` | `test_settings_requires_auth` |

## 13. Open questions

- **Q1 (plan §7 vs §6.1):** §7 says the API lives under `/api/v1` and lists `GET /health`; §6.1 and §13 use `/health`.
  This spec mounts health at the root `/health` only. Confirm.
- **Q2 (plan §5.2):** `timezone` "default from device on first login" but `POST /auth/login` only takes
  `{email,password}`. Resolved here with `DEFAULT 'UTC'` + `timezone_confirmed`, and an optional `timezone` field on
  the login request (auth spec). Mobile `app_shell` must send it, or PATCH `/settings` after first login.
- **Q3 (plan §5.2 vs §5.3, §11):** `week_start` default `1 (Monday)` implies ISO 1..7, while `fixed_schedule_block.weekday`
  uses 0=Mon..6=Sun; and §11 hard-codes weekly reports as Mon–Sun closed on Sunday, so `week_start` is currently unused.
  Kept as ISO 1..7; recommend either aligning to 0..6 or dropping it.
- **Q4 (P5 vs §5.2):** P5 fixes reminders at T-60/T-30, yet `reminder_offsets_min` is user-editable. This spec allows
  1–2 offsets in 5..240 min (never more than two, honouring "few notifications"). Confirm whether edits are wanted.
- **Q5 (plan §9.3 vs §12.1):** `GROQ_DAILY_CALL_CAP` is used in §9.3 but missing from §12.1; added here with default
  1000 (owner: ai_gateway).
- **Q6 (plan §4):** the graph does not list crypto's own dependencies nor core → crypto (needed by
  `app_settings.report_email`). This spec makes crypto a leaf and core → crypto; and since every router needs
  `current_user` but no module depends on `auth`, auth is applied by `app.main` at mount time.
- **Q7 (constitution P2):** mentions "Neon" free tier; plan uses Supabase (ADR-005). Constitution amendment suggested.

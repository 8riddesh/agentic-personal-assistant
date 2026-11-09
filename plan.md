# Technical Plan — Personal Daily Assistant

> Global technical architecture. Module-level detail lives in each module's `spec.md`.
> This document is the **contract** between modules: data model, API surface, cross-module interfaces,
> deployment, release, CI/CD and architectural decisions. Governed by [`constitution.md`](constitution.md).
>
> Diagrams (open in VS Code with the Draw.io Integration extension, or at app.diagrams.net):
> - [`docs/architecture.drawio`](docs/architecture.drawio) — complete system architecture
> - [`docs/data-model.drawio`](docs/data-model.drawio) — database ER diagram

**Scope of this version: a functional application.** Cosmetic/advanced additions (ML algorithm selection for
end-time prediction, UI polish, …) are tracked in §18 and will be discussed later.

---

## 1. System Overview

### 1.1 Capabilities

| # | Capability | Owner module(s) |
|---|------------|-----------------|
| C1 | Email + password login (single user) | `backend/auth`, `mobile/app_shell` |
| C2 | Enter today's tasks (form or chat); mark each as **recurring** or **one-time** | `backend/tasks`, `mobile/tasks`, `mobile/chat` |
| C3 | Feasibility check on entry: score + yes/no (noul) + suggestion, to prevent over-commitment | `backend/feasibility`, `backend/ai_gateway` |
| C4 | Know my fixed weekly schedule + (on consent, per day) Google Calendar events | `backend/schedule`, `mobile/schedule`, `mobile/calendar_connect` |
| C5 | Reminders at T-60 and T-30 before each task's start | `mobile/notifications` |
| C6 | Predict each task's end time from history; **one** "Is it done?" check at predicted end | `backend/predictor`, `mobile/notifications` |
| C7 | Status lifecycle: completed / postponed / cancelled / can't do (+ auto `missed`) | `backend/tasks` |
| C8 | User-declared End of Day ("Done for the day" button or chat "EOD done for the day"); auto-close at 12 AM | `backend/day_cycle`, `mobile/reports`, `mobile/chat` |
| C9 | Daily report at EOD + weekly report on Sunday; BI charts (seaborn/matplotlib) | `backend/reports` |
| C10 | Email a report **only on explicit request** | `backend/email`, `backend/reports` |
| C11 | Conversational assistant that asks clarifying questions and routes intents | `backend/assistant`, `mobile/chat` |
| C12 | Field-level encryption of personal text by the middleware | `backend/crypto` |

### 1.2 Context Diagram (full version: [`docs/architecture.drawio`](docs/architecture.drawio))

```
┌────────────────────────── Android phone ──────────────────────────┐
│ Flutter app                                                        │
│  ├─ UI (tasks, chat, schedule, reports)                            │
│  ├─ Local notifications (T-60, T-30, completion check)  ◀── works offline
│  ├─ Google Sign-In (calendar.readonly, on demand only) ──▶ Google Calendar API
│  └─ Secure storage: backend URL + JWT                              │
└──────────────┬─────────────────────────────────────────────────────┘
               │ HTTPS (mobile data), JSON, Bearer JWT
               ▼
┌──────────── Render free web service (Docker) ────────────┐
│ FastAPI modular monolith (Python 3.12, uv)               │
│  core · auth · crypto · tasks · day_cycle · schedule     │
│  feasibility · predictor · assistant · reports · email   │
│  ai_gateway ──┬──▶ OpenRouter  /api/v1/systemone  (Jev, decisions)
│               ├──▶ Groq        chat completions   (language, fallback decisions)
│               └──▶ OpenRouter  chat completions   (:free text fallback)
│  email ──────────▶ Brevo HTTP API (or Gmail SMTP)        │
└──────────────┬───────────────────────────────────────────┘
               │ asyncpg + TLS via Supabase session pooler
               │ (all personal text AES-256-GCM encrypted before write)
               ▼
        Supabase free Postgres

GitHub: repo + Actions (CI, signed APK release, Render deploy hook)
```

---

## 2. Technology Stack

### 2.1 Backend

| Concern | Choice | Notes |
|---------|--------|-------|
| Runtime | Python 3.12 | |
| Package/env manager | **uv** | `uv sync --frozen` in CI and Docker |
| Web framework | FastAPI + Uvicorn | OpenAPI at `/docs` (disabled in prod) |
| Validation | Pydantic v2, pydantic-settings | All request/response and AI outputs are Pydantic models |
| ORM / DB | SQLAlchemy 2.0 (async) + asyncpg | **Supabase Postgres** |
| Migrations | Alembic | `alembic upgrade head` runs at container start |
| Auth | `pwdlib[argon2]` (password hash), `PyJWT` (HS256) | |
| Encryption | `cryptography` — AESGCM | Field-level, see §6 |
| HTTP client | httpx (async) | Shared client per provider, timeouts set |
| Jev | **OpenRouter Python SDK** (`from openrouter import OpenRouter`) → `open_router.alpha.decisions.create(model, state, questions)` with `OPENROUTER_API_KEY` — no TypeSafe account/SDK | Model pinned `typesafe/jev-1.14` |
| Groq | `groq` SDK (async) | |
| OpenRouter text | **OpenRouter Python SDK** → `open_router.chat.send(model, messages)` | Only `:free` models |
| Stats / ML | pandas, numpy (v1); scikit-learn (v2, deferred) | |
| Charts | matplotlib (Agg backend), seaborn | PNG @150 dpi + combined PDF |
| Templates | Jinja2 | Prompts + email HTML |
| Tests | **pytest**, pytest-asyncio, pytest-cov, respx, freezegun | Postgres service container in CI |
| Lint/type | ruff, mypy, import-linter | |

### 2.2 Mobile

| Concern | Choice |
|---------|--------|
| Framework | Flutter (stable), Dart 3, **Android only** (minSdk 26, targetSdk latest) |
| State management | flutter_riverpod |
| Routing | go_router |
| HTTP | dio (+ JWT interceptor, retry with backoff for server cold start) |
| Models | freezed + json_serializable |
| Secure storage | flutter_secure_storage |
| Local cache / outbox | drift (SQLite) — caches the open day, queues notification-action responses made offline |
| Notifications | flutter_local_notifications + timezone + flutter_timezone |
| Calendar | google_sign_in + googleapis (calendar/v3) — on demand only |
| Report display | server-rendered PNGs (`Image.memory`), fl_chart for small in-app stats |
| Tests | flutter_test, mocktail, integration_test |

### 2.3 Infrastructure (all free)

| Piece | Service | Free-tier constraint → mitigation |
|-------|---------|-----------------------------------|
| API hosting | Render free web service (Docker) | Sleeps after ~15 min idle → ~30–60 s cold start (**accepted**). 512 MB RAM → lazy-import pandas/matplotlib; render charts sequentially. No background scheduler (server may be asleep) → time-based work is done lazily on the next request (§8.3). |
| Database | **Supabase** free Postgres | 500 MB DB → chart PNGs pruned after 90 days (regenerable). Project pauses after 7 days of inactivity → daily use prevents it. Direct DB host is IPv6-only → connect through the **Supavisor session pooler** (IPv4, port 5432). Supabase Auth/REST/RLS are **not** used — FastAPI is the only DB client. |
| Decisions | Jev via OpenRouter | Free under the user's daily allowance (per-key daily limit set on OpenRouter); `JEV_DAILY_CALL_CAP` guard; Groq fallback. |
| Language | Groq free tier | Rate limits → retry w/ backoff; fallback to OpenRouter `:free` model. |
| Email | Brevo free (HTTP API, 300/day) | HTTP avoids SMTP port restrictions some free hosts apply. Gmail SMTP adapter as alternative. |
| CI/CD | GitHub Actions | Path filters keep minutes low. |
| APK distribution | GitHub Release asset + USB/local installs | Sideloaded; no Play Store (its $25 fee violates P2). See §14. |

---

## 3. Repository Layout

```
/
├── constitution.md
├── plan.md                         ← this file
├── README.md
├── render.yaml                     ← Render blueprint (free plan)
├── docs/
│   ├── architecture.drawio
│   └── data-model.drawio
├── .github/workflows/
│   ├── backend-ci.yml
│   ├── mobile-ci.yml
│   ├── deploy-backend.yml
│   └── release-apk.yml
├── backend/
│   ├── pyproject.toml / uv.lock
│   ├── Dockerfile
│   ├── alembic.ini
│   ├── migrations/
│   ├── app/
│   │   ├── main.py                 ← composition root: builds app, mounts module routers
│   │   └── modules/
│   │       ├── core/         spec.md  config, db, settings, errors, logging, clock, health
│   │       ├── auth/         spec.md  email+password login, JWT
│   │       ├── crypto/       spec.md  field-level encryption (AES-256-GCM)
│   │       ├── tasks/        spec.md  tasks, recurring templates, status lifecycle
│   │       ├── day_cycle/    spec.md  day sessions, open/close (EOD), midnight auto-close
│   │       ├── schedule/     spec.md  fixed weekly schedule, calendar import, free slots
│   │       ├── ai_gateway/   spec.md  Jev / Groq / OpenRouter clients, fallback, logging
│   │       ├── feasibility/  spec.md  over-commitment check (deterministic + Jev)
│   │       ├── predictor/    spec.md  end-time prediction (statistics v1, ML v2)
│   │       ├── assistant/    spec.md  chat, intent routing, clarifying questions
│   │       ├── reports/      spec.md  metrics, BI charts, narrative, report store
│   │       └── email/        spec.md  on-demand email delivery
│   └── tests/<module>/...
└── mobile/
    ├── pubspec.yaml
    ├── android/                    ← key.properties (git-ignored) for local release signing
    ├── lib/
    │   ├── main.dart
    │   └── features/
    │       ├── app_shell/        spec.md  bootstrap, login, routing, API client, settings
    │       ├── tasks/            spec.md  today checklist, add-task + feasibility card, status actions
    │       ├── chat/             spec.md  assistant conversation, action proposals
    │       ├── notifications/    spec.md  T-60/T-30 reminders, completion check, action handling
    │       ├── schedule/         spec.md  weekly fixed-schedule editor
    │       ├── calendar_connect/ spec.md  per-day Google Calendar consent + import
    │       └── reports/          spec.md  EOD flow, report viewer, "email this report"
    └── test/
```

### 3.1 Backend module internal layout (every module)

```
modules/<name>/
├── spec.md          # module spec (behaviour, interfaces, acceptance criteria)
├── __init__.py      # exports the module's public service interface ONLY
├── api.py           # FastAPI APIRouter (thin: validate → call service → map)
├── service.py       # business logic; the public interface other modules may call
├── repository.py    # SQLAlchemy queries (private to module)
├── models.py        # ORM tables (private to module)
├── schemas.py       # Pydantic DTOs (public ones re-exported in __init__)
└── prompts/         # (AI modules only) Jinja2 prompt templates, versioned
```

**Boundary rule (enforced by import-linter in CI):** a module may import only another module's package root
(`from app.modules.tasks import TaskService, TaskDTO`), never its `models`, `repository` or `api`.

### 3.2 Mobile feature internal layout

```
features/<name>/
├── spec.md
├── data/            # API clients, drift DAOs, DTOs
├── domain/          # pure Dart entities + use-cases (unit-tested)
└── presentation/    # widgets, screens, riverpod providers
```

---

## 4. Backend Module Dependency Graph

```
crypto (depends on nothing)
core ──▶ crypto                                   (app_settings.report_email is encrypted)
            core ◀──────────────────────────── (all modules)
            crypto ◀────────────────────────── (all modules persisting personal text)
auth ──▶ core        (no module imports auth: app/main.py attaches current_user when mounting routers)
schedule ──▶ core, crypto
tasks ──▶ core, crypto
predictor ──▶ tasks(read history), core
ai_gateway ──▶ core
feasibility ──▶ tasks(read), schedule, predictor, ai_gateway
email ──▶ core
reports ──▶ tasks(read), predictor(read accuracy), feasibility(read outcomes), ai_gateway, email, crypto
day_cycle ──▶ tasks, predictor(retrain hook), reports
assistant ──▶ ai_gateway, tasks(read), schedule(read), day_cycle(read), reports(read)
```

Dependency-inversion seams (wired in `app/main.py`, keep the graph acyclic):
- `tasks` defines `EndTimePredictorPort`; `predictor` implements it (`TaskPredictionAdapter`) so tasks can store
  `predicted_end_at` without importing predictor.
- `day_cycle` exports an `ensure_current_day` dependency that `main.py` attaches to day-scoped routers (tasks,
  feasibility, assistant) so the lazy midnight auto-close runs on any of them.

No cycles. `assistant` never mutates state — it returns **action proposals** that the app executes through
the owning module's endpoint (ADR-009).

### 4.1 Cross-module service interfaces (canonical — module specs must match these signatures)

All services are async, constructed per request via FastAPI dependencies, and receive an `AsyncSession`.
DTOs are Pydantic v2 models exported from the module's package root.

```python
# core
class Clock(Protocol):
    def now_utc(self) -> datetime: ...
    def today_local(self, tz: ZoneInfo) -> date: ...
class AppSettingsService:
    async def get(self) -> AppSettingsDTO: ...            # timezone, reminder_offsets_min, report_email, week_start
    async def update(self, patch: AppSettingsPatch) -> AppSettingsDTO: ...
    async def tz(self) -> ZoneInfo: ...
# errors (mapped to RFC 7807 by core): NotFoundError, ConflictError, DomainValidationError, UpstreamError

# auth
async def current_user(...) -> UserDTO                    # FastAPI dependency
class AuthService:
    async def login(self, email: str, password: str) -> TokenDTO: ...

# crypto
EncryptedText, EncryptedJSON, EncryptedBytes              # SQLAlchemy TypeDecorators (AAD = "table.column")
class FieldCipher:
    def encrypt(self, plaintext: bytes, aad: str) -> bytes: ...
    def decrypt(self, envelope: bytes, aad: str) -> bytes: ...

# schedule
class ScheduleService:
    async def busy_intervals(self, local_date: date) -> list[BusyInterval]: ...  # fixed blocks + calendar events, UTC
    async def free_slots(self, local_date: date) -> list[TimeInterval]: ...

# tasks
class TaskService:
    async def day_plan(self, local_date: date) -> list[TaskDTO]: ...
    async def tasks_in_range(self, start: date, end: date) -> list[TaskDTO]: ...       # inclusive; for reports
    async def history(self, *, template_id: UUID | None = None, category: str | None = None,
                      since: date | None = None) -> list[TaskOutcomeDTO]: ...          # labelled durations
    async def materialize_templates(self, local_date: date) -> int: ...                # idempotent
    async def unresolved(self, local_date: date) -> list[TaskDTO]: ...                 # status == planned
    async def mark_unresolved_missed(self, local_date: date) -> int: ...

# predictor
class PredictorService:
    async def predict(self, inp: PredictionInput) -> Prediction: ...
        # PredictionInput{title, category, start_at, estimate_min?, template_id?}
        # Prediction{predicted_end_at, duration_min, method, sample_count}
    async def on_day_closed(self, local_date: date) -> None: ...                       # v1 no-op; v2 retrain
    async def accuracy(self, start: date, end: date) -> AccuracyDTO: ...

# ai_gateway
class AIGateway:
    async def decide(self, purpose: str, state: dict, questions: dict[str, Question]) -> DecisionResult: ...
        # Question = NoulQ | ScoreQ | ChoiceQ ; DecisionResult{answers, engine, degraded}
    async def generate(self, purpose: str, template: str, context: dict, max_tokens: int = 300) -> TextResult: ...
    async def extract(self, purpose: str, schema: type[T], template: str, context: dict) -> ExtractResult[T]: ...

# feasibility
class FeasibilityService:
    async def assess(self, draft: TaskDraft) -> AssessmentDTO: ...
    async def get(self, assessment_id: UUID) -> AssessmentDTO: ...
    async def outcomes(self, start: date, end: date) -> list[AssessmentOutcomeDTO]: ...

# email
class EmailService:
    async def send(self, msg: EmailMessage) -> EmailResult: ...   # to, subject, html, inline_images, attachments

# reports
class ReportService:
    async def generate(self, kind: ReportKind, period_start: date) -> UUID: ...        # creates pending, renders
    async def email(self, report_id: UUID) -> EmailResult: ...

# day_cycle
class DayService:
    async def current(self) -> DayDTO: ...          # auto-closes stale day, opens today, materializes templates
    async def close(self, mode: CloseMode) -> CloseResultDTO: ...
    async def get(self, local_date: date) -> DayDTO: ...

# assistant
class AssistantService:
    async def handle(self, text: str) -> AssistantReplyDTO: ...    # reply + optional ActionProposal
```

`TaskDraft` (shared by tasks, feasibility, assistant) is defined in `tasks` and re-exported:
`{title, notes?, category, start_at?, estimate_min?, is_recurring, recurrence?}`.

---

## 5. Data Model (Supabase Postgres)

ER diagram: [`docs/data-model.drawio`](docs/data-model.drawio).

Conventions: UUID primary keys (`id`), `timestamptz` stored in UTC, `created_at`/`updated_at` on every table.
Columns marked 🔒 are encrypted by `crypto` (ciphertext `text`, or `bytea`). Encrypted columns are never
filtered/sorted in SQL — they are read and decrypted in the service layer (data volume is tiny).

### 5.1 auth — `user_account` (exactly one row)
| Column | Type / notes |
|---|---|
| id | uuid PK |
| email | text unique (plaintext — needed for login lookup) |
| password_hash | text (argon2id) |
| token_version | int — bump to invalidate all JWTs |
| last_login_at | timestamptz |

### 5.2 core — `app_settings` (single row)
| Column | Type / notes |
|---|---|
| timezone | text IANA, default from device on first login |
| reminder_offsets_min | int[] default `{60,30}` |
| report_email 🔒 | text nullable (to be configured) |
| week_start | smallint default 1 (Monday) |

### 5.3 schedule
`fixed_schedule_block`
| Column | Type / notes |
|---|---|
| id | uuid PK |
| weekday | smallint 0=Mon..6=Sun |
| start_local, end_local | time (end < start ⇒ crosses midnight) |
| label 🔒 | text |
| kind | enum `work, sleep, commute, meal, personal, other` |
| is_hard | bool — hard blocks can't host tasks; soft blocks only warn |
| active | bool |

`calendar_event` (per-day import, consented)
| Column | Type / notes |
|---|---|
| id | uuid PK |
| day_date | date (rows for a date replaced atomically on re-import) |
| external_id | text |
| start_at, end_at | timestamptz |
| all_day | bool |
| title 🔒 | text |
| imported_at | timestamptz |

`schedule_block_override` (per-date manual adjustment of one weekly block)
| Column | Type / notes |
|---|---|
| id | uuid PK |
| local_date | date — date of the block occurrence |
| block_id | FK → fixed_schedule_block.id ON DELETE CASCADE |
| action | enum `skip, adjust` |
| start_local, end_local | time nullable (required for `adjust`) |
| is_hard | bool nullable (per-date hardness change) |
| unique | `(local_date, block_id)` |

Soft blocks are **not** busy time: they never reduce free slots; overlapping one only triggers a warning, and the
app offers "Adjust schedule for this day" (an override) before re-checking feasibility.

### 5.4 tasks
`task_template` (recurring definitions)
| Column | Type / notes |
|---|---|
| id | uuid PK |
| title 🔒, notes 🔒 | text |
| category | text |
| start_local | time nullable |
| recurrence | jsonb `{"freq":"daily"}` \| `{"freq":"weekly","byweekday":[0,2,4]}` |
| default_estimate_min | int nullable |
| active | bool |

`task`
| Column | Type / notes |
|---|---|
| id | uuid PK |
| local_date | date — the day this task belongs to; joins `day_session.local_date` (no FK, so postponed/future tasks need no day row and `tasks` does not depend on `day_cycle`) |
| template_id | FK → task_template.id, nullable (null = one-time) |
| title 🔒, notes 🔒 | text |
| category | text |
| start_at | timestamptz nullable ("anytime" tasks → no reminders/check) |
| estimate_min | int nullable (user-provided) |
| predicted_end_at | timestamptz nullable |
| prediction_method | text nullable (e.g. `template_p60`, `ml:2026.11.20-1`) |
| actual_end_at | timestamptz nullable |
| actual_end_source | enum `notification_action, manual, eod_resolution` |
| status | enum `planned, completed, postponed, cancelled, cant_do, missed` |
| status_reason 🔒 | text nullable (required for `cant_do`) |
| postponed_to_task_id | FK → task.id nullable |
| feasibility_id | FK → feasibility_assessment.id nullable |
| feasibility_overridden | bool |
| created_via | enum `form, chat, template` |
| check_response | enum nullable `done, not_yet` |
| unique | `(local_date, template_id)` where template_id not null |

`task_status_event` (append-only audit)
| Column | Type / notes |
|---|---|
| id, task_id (FK), from_status, to_status, at | |
| source | enum `app, notification, chat, eod, system` |
| reason 🔒 | text nullable |

### 5.5 day_cycle — `day_session`
| Column | Type / notes |
|---|---|
| id | uuid PK |
| local_date | date unique |
| opened_at, closed_at | timestamptz |
| close_mode | enum `user, auto_midnight` |
| state | enum `open, closing, closed` |
| daily_report_id, weekly_report_id | FK → report.id nullable |

### 5.6 feasibility — `feasibility_assessment`
| Column | Type / notes |
|---|---|
| id, created_at | |
| draft 🔒 | encrypted JSON: the task draft assessed |
| deterministic | jsonb: overlaps, free_minutes, committed_minutes, load_ratio (no personal text) |
| jev_answers | jsonb: typed answers (nouls/scores/choices + probabilities) |
| score | real 0..1 |
| feasible_noul | real 0..1 |
| verdict | enum `go, caution, no_go` |
| recommended_action | enum `proceed, reschedule, split, shorten, drop` |
| suggestion 🔒 | text (1–2 sentences) |
| engine | enum `jev, groq_fallback, deterministic_only` |
| degraded | bool |
| latency_ms | int |

### 5.7 assistant — `chat_message`
| Column | Type / notes |
|---|---|
| id, day_id (FK), role enum `user, assistant`, created_at | |
| content 🔒 | text |
| intent, intent_confidence, in_scope_noul | routing metadata |
| proposal 🔒 | encrypted JSON nullable (action proposal returned to app) |

### 5.8 reports
`report`
| Column | Type / notes |
|---|---|
| id | uuid PK |
| kind | enum `daily, weekly` |
| period_start, period_end | date |
| status | enum `pending, ready, failed` |
| metrics 🔒 | encrypted JSON (contains titles) |
| narrative 🔒 | text |
| generated_at, emailed_at | timestamptz |

`report_asset`
| Column | Type / notes |
|---|---|
| id, report_id (FK), name (e.g. `status_donut.png`, `report.pdf`), mime | |
| blob 🔒 | bytea — pruned after 90 days, regenerable |

### 5.9 Operational logs (no personal text)
- `ai_call_log`: provider, model, purpose, status, latency_ms, input_tokens, output_tokens, cost_usd, error_code, created_at
- `email_log`: report_id (plain indexed uuid, **no FK** — email must not depend on reports), provider, status, provider_message_id, error, created_at, recipient 🔒

### 5.10 Added with predictor v2 (deferred) — `predictor_model`
| Column | Type / notes |
|---|---|
| id, version (e.g. `2026.11.20-1`), algorithm, trained_at, n_samples | |
| metrics | jsonb `{holdout_mae_min, baseline_mae_min, …}` |
| artifact 🔒 | bytea (joblib) |
| is_active | bool — at most one active; none ⇒ statistics v1 |

---

## 6. Security: Auth & Encryption

### 6.1 Login (single user, email + password)
- Account seeded at startup from `OWNER_EMAIL` + `OWNER_PASSWORD_HASH` (argon2id hash generated once via
  `uv run python -m app.modules.auth.hash_password`). If the row exists, it is left unchanged.
- `POST /api/v1/auth/login {email, password}` → `{access_token, expires_at}`; JWT HS256, `sub=user id`,
  `ver=token_version`, TTL 30 days. No refresh tokens — re-login after expiry.
- Every non-public route depends on `current_user` (validates signature, expiry, `ver`).
- Public routes: `/health`, `/api/v1/auth/login`.

### 6.2 Field-level encryption (middleware, P11)
- **AES-256-GCM** (`cryptography` AESGCM), 96-bit random nonce per value.
- Envelope (text): `v{key_id}:{base64url(nonce ‖ ciphertext ‖ tag)}`; bytea: 1-byte key_id ‖ nonce ‖ ct ‖ tag.
- AAD = `"{table}.{column}"` — ciphertexts cannot be swapped between columns.
- Keys: `ENCRYPTION_KEYS="1:<base64 32B>"`, `ENCRYPTION_ACTIVE_KEY_ID=1`. Decrypt with any listed key;
  encrypt with the active one (enables future rotation).
- Implemented as SQLAlchemy `TypeDecorator`s — `EncryptedText`, `EncryptedJSON`, `EncryptedBytes` — so
  repositories are oblivious. A CI test asserts every 🔒 column in this plan uses one of them, and an
  integration test reads raw rows to prove no plaintext is stored.
- Text sent to AI providers is plaintext over TLS by necessity; only minimal fields are sent (no notes).

---

## 7. API Surface (REST, `/api/v1`, JSON, errors as RFC 7807 `application/problem+json`)

| Method & path | Module | Purpose |
|---|---|---|
| `GET /health` (root path, **not** under `/api/v1`) | core | Liveness + DB ping (public) |
| `POST /auth/login` | auth | Email + password → JWT |
| `GET/PATCH /settings` | core | Timezone, reminder offsets, report email |
| `GET/PUT /schedule/blocks` | schedule | Replace weekly fixed schedule |
| `PUT /schedule/calendar/{date}` | schedule | Import (replace) consented Google events for a date |
| `DELETE /schedule/calendar/{date}` | schedule | Forget imported events |
| `GET /schedule/free-slots?date=` | schedule | Computed free windows (hard blocks + calendar only) |
| `GET /schedule/overrides/{date}`, `PUT/DELETE /schedule/overrides/{date}/{block_id}` | schedule | Per-date skip/adjust of a weekly block |
| `GET /days/current` | day_cycle | Get or open today's day (auto-closes a stale day, materializes recurring tasks) |
| `GET /days/{date}` | day_cycle | Day summary |
| `GET /days/current/unresolved` | day_cycle | Tasks still `planned` (EOD resolution sheet) |
| `POST /days/current/close` | day_cycle | **EOD** → 202 `{state:"closing", missed_count, …}` (reports build in the background; the app polls `GET /days/{date}` until `daily_report_id` / `weekly_report_id` are set); 200 if already closed |
| `POST /feasibility/assess` | feasibility | Assess a task draft → verdict, score, noul, suggestion, predicted_end |
| `POST /tasks` | tasks | Create task (recurring → also creates template) |
| `GET /tasks?date=` | tasks | Tasks for a day |
| `PATCH /tasks/{id}` | tasks | Edit fields |
| `POST /tasks/{id}/status` | tasks | `completed{finished_at?}`, `postponed{new_start_at}`, `cancelled{reason?}`, `cant_do{reason}` |
| `POST /tasks/{id}/check-response` | tasks | Completion-check answer: `done{finished_at}` \| `not_yet{eta_min?}` |
| `GET/PATCH/DELETE /templates[/{id}]` | tasks | Manage recurring templates |
| `POST /predictor/predict` | predictor | Predict end for a draft |
| `GET /predictor/status` | predictor | Active method / model version and accuracy |
| `POST /assistant/messages` | assistant | Chat turn → reply + optional action proposal |
| `GET /assistant/messages?date=` | assistant | History |
| `POST /assistant/greeting` | assistant | Once-per-day greeting "What do you plan to do today?" (app calls it on first open of the day) |
| `GET /reports?kind=&limit=` | reports | List |
| `GET /reports/{id}` | reports | Metrics + narrative + asset list (status may be `pending`) |
| `GET /reports/{id}/assets/{name}` | reports | PNG/PDF bytes |
| `POST /reports/{id}/email` | reports→email | **Explicit** email send to configured address |
| `POST /reports/generate` | reports | Regenerate `{kind, period_start}` |

OpenAPI schema is exported in CI to `backend/openapi.json`; mobile DTOs are checked against it.

---

## 8. Key Flows

### 8.1 Add a task (form or chat)
```
App                         Backend
 │ POST /feasibility/assess {title, start_at, estimate_min?, category?, is_recurring}
 │────────────────────────▶ feasibility
 │                           ├─ predictor.predict(draft)          → predicted_end_at
 │                           ├─ schedule.busy_intervals(date)     → fixed blocks + calendar events
 │                           ├─ tasks.day_plan(date)              → already-planned tasks
 │                           ├─ deterministic checks              → overlaps, free_min, load_ratio
 │                           ├─ ai_gateway.decide(Jev questions)  → nouls / score / choice
 │                           ├─ combine (weights in config)       → score, verdict
 │                           └─ ai_gateway.generate(suggestion)   → 1–2 sentence advice
 │◀──────────────────────── {assessment_id, verdict, score, feasible_noul, recommended_action, suggestion, predicted_end_at}
 │ verdict card → user: Add / Add anyway (override) / Adjust
 │ The app ALWAYS asks: "Recurring or one-time?" (recurring → daily or chosen weekdays)
 │ POST /tasks {..., is_recurring, recurrence?, assessment_id, overridden}
 │◀──────────────────────── task
 │ notifications: schedule T-60, T-30, completion check @ predicted_end_at
```

### 8.2 Notifications (device-local, ADR-002)
- Per task with `start_at`: reminders at `start_at − 60 min` and `start_at − 30 min` (skipped if already past).
- **One** completion check at `predicted_end_at`, actions **Done** / **Not yet**:
  - Done → `check-response done{finished_at}`; if tapped > 10 min after it fired, the app asks
    "When did you finish?" (at notification time / now / pick) so history stays accurate.
  - Not yet → no more automatic prompts. Optional quick ETA (+15/+30/+60) schedules **one** follow-up
    only because the user asked.
- A terminal status cancels that task's pending notifications; EOD cancels all remaining for the day;
  nothing is scheduled past local midnight.
- Reconciliation on app start/resume and after every mutation: cancel + reschedule all notifications for the open
  day from server state (deterministic notification IDs → idempotent).

### 8.3 End of Day & midnight auto-close
```
User taps "Done for the day" (or chat "EOD done for the day" → proposal → one tap)
 → GET /days/current/unresolved → resolution sheet (Completed / Postpone to tomorrow / Can't do / leave)
 → POST /days/current/close
     day_cycle: still-planned tasks → missed; state = closing
     background task: predictor.on_day_closed()  (v2: full retrain, §10.2)
                      → reports.generate(daily) → if local Sunday: reports.generate(weekly); state = closed
 → app cancels remaining notifications, opens report viewer (polls until ready)
 → "Email this report" button → POST /reports/{id}/email    (never automatic)
```
**Auto-close at 12 AM (local):** the server may be asleep at midnight, so the close is applied **lazily**:
the first `GET /days/current` (or any day-scoped call) after local midnight finds an open day with
`local_date < today`, closes it with `close_mode=auto_midnight` (closed_at = that day's 23:59:59 local), runs the
same pipeline, then opens the new day. The app also calls `GET /days/current` on launch/resume, and on the phone
all of the day's notifications end by midnight.

### 8.4 Day open & recurring tasks
Opening a day materializes one `task` per active `task_template` whose recurrence matches the local date
(idempotent via the unique `(local_date, template_id)`). Postponed tasks already exist on their new date.

### 8.5 Calendar (consent per day, ADR-007)
App → Google Sign-In (scope `calendar.readonly`) → Calendar API `events.list(primary, timeMin, timeMax,
singleEvents=true)` → `PUT /schedule/calendar/{date}`. The Google access token never leaves the phone and is not
persisted; no refresh token is requested.

---

## 9. AI Design

### 9.1 Roles
| Engine | Used for | Why |
|---|---|---|
| **Jev** (`typesafe/jev-1.14` via OpenRouter `POST https://openrouter.ai/api/alpha/decisions`, OpenRouter key only) | Feasibility judgments, intent routing | Typed, calibrated answers (noul/score/choice) — no JSON parsing |
| **Groq** (model configurable; verify current list at implementation) | Suggestions, clarifying questions, field extraction (JSON mode), report narratives; **fallback** for decisions | Fast, free tier |
| **OpenRouter `:free` model** (configurable) | Fallback for Groq text | Free |

### 9.2 Jev feasibility questions (atomic, combined in code)
`state` = task draft (title, category, start, estimate), predicted duration, day plan, busy intervals,
free minutes, history stats for similar tasks. Questions:

| id | type | instructions (abridged) |
|---|---|---|
| `achievable_in_window` | noul | Can this task realistically be finished between its start and the next hard commitment, given the predicted duration? |
| `day_overcommitted` | noul | After adding this task, is the day's total planned work more than the person can realistically complete? |
| `workload_realism` | score | 5 levels: "clearly unrealistic" … "comfortably realistic" |
| `history_supports` | noul | Does this person's history with similar tasks suggest they usually finish them on time? |
| `recommended_action` | choice | `proceed, reschedule, split, shorten, drop` |

`score = 0.40·achievable + 0.25·(1−overcommitted) + 0.20·workload_norm + 0.15·history_supports − penalties`
(penalties: hard-block overlap −0.30; each task overlap −0.15, max −0.30; weights configurable).
Verdict: `go ≥ 0.70 > caution ≥ 0.45 > no_go`. The yes/no shown to the user is `achievable_in_window`.

Assistant intent routing: Jev `choice` over intents + companion `noul` "message fits one of these intents".

### 9.3 Resilience
- Timeouts: Jev 8 s, Groq 15 s, OpenRouter 20 s. Retries: 2, exponential backoff + jitter on 429/5xx.
- Fallbacks: decisions `Jev → Groq (JSON schema, degraded=true) → deterministic_only`;
  text `Groq → OpenRouter :free → fixed template string`.
- Guards: `JEV_DAILY_CALL_CAP`, `GROQ_DAILY_CALL_CAP`; every call logged in `ai_call_log`.

---

## 10. End-Time Predictor

### 10.1 v1 — statistics (in scope now)
- Target: `duration = actual_end_at − start_at` for tasks with `actual_end_source ∈ {notification_action, manual}`.
- Fallback chain: **same-template p60 (≥ 3 samples) → same-category p60 (≥ 5) → user estimate → global p60
  (≥ 5) → 60 min.** The 60th percentile (not the median) makes the check land slightly after the typical
  finish, so fewer "not yet" answers.
- Every prediction stores `prediction_method`; every outcome is stored → the dataset is ready for v2.
- The predictor exposes a `Predictor` protocol, so v2 replaces v1 without touching callers.

### 10.2 v2 — ML with **full retraining** (agreed approach; algorithm choice deferred)
Data volume is small (~5–15 tasks/day ≈ 2–5k rows/year), so instead of incremental learning (`partial_fit`):
1. **Retrain from scratch on the full history at every day close** (only if ≥ 3 new labels). Sub-second on 512 MB.
2. **Time-decay `sample_weight`** (e.g. 60-day half-life) so the model adapts to changing habits.
3. **Promotion gate:** time-ordered holdout (most recent 20%). Promote only if holdout MAE beats both the active
   model and the v1 statistics baseline; otherwise keep the current one.
4. **Version registry** in `predictor_model` (§5.10) → rollback = flip `is_active`.
5. Activates only after ≥ 30 labelled samples; before that, v1 serves.

Algorithm, features and quantile target are to be decided in the enhancements phase (§18).

---

## 11. Reports (BI)

| Report | Trigger | Charts (seaborn/matplotlib → PNG, bundled into one PDF) |
|---|---|---|
| Daily | EOD close (user or auto-midnight) | status donut · planned-vs-actual minutes per task (bar) · day timeline planned vs actual (Gantt) · minutes by category (bar) · feasibility verdict vs outcome (stacked bar) |
| Weekly | close of the local **Sunday** — covers Mon–Sun | completion rate per day (line) · status mix per day (stacked bar) · time by category (pie) · completions heatmap weekday×hour · predicted vs actual duration (scatter) · most postponed / can't-do tasks (bar) |

Metrics computed with pandas; Groq writes a narrative (≤ 120 words: wins, misses, one suggestion).
Email (only via `POST /reports/{id}/email`): HTML (Jinja2) with inline CID images + PDF attachment.

---

## 12. Configuration

### 12.1 Backend env vars (Render dashboard; never committed)
| Var | Example / default |
|---|---|
| `DATABASE_URL` | `postgresql+asyncpg://postgres.<ref>:<pw>@aws-0-<region>.pooler.supabase.com:5432/postgres` (session pooler, SSL) |
| `OWNER_EMAIL`, `OWNER_PASSWORD_HASH` | seeded account |
| `JWT_SECRET`, `JWT_TTL_DAYS` | 32+ random bytes, `30` |
| `ENCRYPTION_KEYS`, `ENCRYPTION_ACTIVE_KEY_ID` | see §6.2 |
| `OPENROUTER_API_KEY` | Jev + free text models |
| `JEV_MODEL`, `JEV_DAILY_CALL_CAP` | `typesafe/jev-1.14`, `500` |
| `GROQ_API_KEY`, `GROQ_MODEL`, `GROQ_FAST_MODEL`, `GROQ_DAILY_CALL_CAP` | caps default `1000` |
| `OPENROUTER_TEXT_FALLBACK_MODEL` | a `:free` model id |
| `EMAIL_PROVIDER` | `brevo` \| `smtp` |
| `BREVO_API_KEY`, `EMAIL_FROM` / `SMTP_HOST`, `SMTP_PORT`, `SMTP_USER`, `SMTP_PASSWORD` | |
| `FEASIBILITY_WEIGHTS` | JSON, defaults in §9.2 |
| `ENV` | `dev` \| `test` \| `prod` |

The report recipient is **not** an env var — it is `app_settings.report_email`, set from the app later.

### 12.2 Mobile build-time config
`--dart-define=API_BASE_URL=https://<service>.onrender.com` (no secrets in the APK).

---

## 13. CI/CD (GitHub Actions)

| Workflow | Trigger | Steps |
|---|---|---|
| `backend-ci.yml` | PR / push touching `backend/**` | `astral-sh/setup-uv` → `uv sync --frozen` → `ruff check` + `ruff format --check` → `mypy` → `lint-imports` → `uv run pytest --cov` against a Postgres service container → export `openapi.json`, fail on uncommitted diff |
| `mobile-ci.yml` | PR / push touching `mobile/**` | `subosito/flutter-action` → `flutter pub get` → `dart run build_runner build` → `flutter analyze` → `flutter test` → `flutter build apk --debug` |
| `deploy-backend.yml` | `workflow_run` of backend-ci on `main`, success | `curl -X POST $RENDER_DEPLOY_HOOK_URL` → poll `/health` until 200 (≤ 5 min) |
| `release-apk.yml` | tag `v*` | see §14.3 |

Render (`render.yaml`): one free Docker web service, `autoDeploy: false` (deploys only after CI).
Start command: `alembic upgrade head && uvicorn app.main:app --host 0.0.0.0 --port $PORT`.

---

## 14. Android Release & Distribution

No Play Store (one-time $25 fee violates P2; single user). The app is **sideloaded**.

### 14.1 Signing
- One upload keystore generated once with `keytool` (bundled with Android Studio's JDK):
  `keytool -genkey -v -keystore daily-assistant.jks -keyalg RSA -keysize 2048 -validity 10000 -alias release`.
- Local builds read it via `mobile/android/key.properties` (git-ignored); CI reads it from GitHub Secrets:
  `ANDROID_KEYSTORE_B64`, `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS`, `ANDROID_KEY_PASSWORD`.
- **The keystore must be backed up** (e.g. password manager + Google Drive). Losing it means the next version
  cannot update in place → uninstall/reinstall (server data is safe; only on-device login/notifications reset).

### 14.2 Path A — local build (day-to-day development)
`flutter build apk --release --dart-define=API_BASE_URL=…` → install via USB (`flutter install` / `adb install -r`)
or copy the APK to the phone.

### 14.3 Path B — automated release (versioned releases)
Push tag `vX.Y.Z` → `release-apk.yml`: checkout → setup Java 17 + Flutter → decode keystore from secret →
`flutter build apk --release --build-name=X.Y.Z --build-number=$GITHUB_RUN_NUMBER --dart-define=API_BASE_URL=…`
→ upload `app-release.apk` to a GitHub Release. On the phone: open the Release page → download → install.

### 14.4 Versioning & updates
`pubspec.yaml` `version: X.Y.Z+N`; `N` (versionCode) must strictly increase. Installing a newer APK signed with
the same key updates in place and keeps app data.

### 14.5 Manifest requirements (release builds do not add these implicitly)
`INTERNET`, `POST_NOTIFICATIONS` (Android 13+), `SCHEDULE_EXACT_ALARM` / `USE_EXACT_ALARM` (on-time reminders),
`RECEIVE_BOOT_COMPLETED` (re-arm notifications after reboot). Detailed in `mobile/notifications/spec.md`.

### 14.6 Phone setup (once)
Allow "Install unknown apps" for the browser/Files app; if Play Protect warns, choose "Install anyway".
Google's developer-verification requirements for sideloaded apps must be re-checked before the first release
(O5); ADB/USB install is the guaranteed fallback.

---

## 15. Testing Strategy

| Level | Backend (pytest) | Mobile |
|---|---|---|
| Unit | services with fake repositories; pure functions (overlap math, combiners, recurrence, crypto, predictor fallbacks) | domain use-cases; notification scheduling rules with fake clock |
| Integration | API tests (httpx `AsyncClient`) on real Postgres; raw-row checks prove encryption | drift DAOs; dio interceptors with mock adapter |
| External | respx-mocked Jev / Groq / OpenRouter / Brevo with recorded response shapes | mocked API client |
| Contract | OpenAPI snapshot | DTOs ↔ `openapi.json` |
| Charts | every chart renders a non-empty PNG from fixture metrics | golden tests for key widgets |

---

## 16. Architecture Decision Records (summary)

| ADR | Decision | Rationale |
|---|---|---|
| 001 | Modular monolith (one FastAPI service) | One free Render instance; boundaries enforced by import-linter |
| 002 | Reminders/checks are device-local notifications | Free server sleeps; local notifications are on time and offline-safe |
| 003 | Jev (via OpenRouter) is the decision engine; Groq fallback | Typed, calibrated decisions; free under user's daily allowance |
| 004 | Application-level AES-256-GCM field encryption | DB never sees personal plaintext (P11) |
| 005 | Supabase Postgres via session pooler; FastAPI is the only client | Free managed Postgres; Render disk is ephemeral; pooler gives IPv4 |
| 006 | Server-side seaborn/matplotlib reports; email only on request | User requirement; same charts in-app and in email |
| 007 | Calendar read on device, short-lived token, per-day consent | P6; no Google secrets on server |
| 008 | Email via Brevo HTTP API by default, SMTP adapter optional | Avoids SMTP egress restrictions on free hosts |
| 009 | Assistant returns action proposals; app executes them | Single write path per entity; user confirms consequential actions |
| 010 | Day = user-closed session; lazy auto-close at local midnight | User decides day end; server may be asleep at midnight |
| 011 | Predictor v1 statistical; v2 ML with full retraining (no incremental learning) | Tiny dataset → full retrain is fast, more accurate, gated and reversible |
| 012 | Sideloaded APK: local builds + tagged GitHub Releases | Free; no Play Store fee |

---

## 17. Delivery Milestones

| M | Scope | Exit criterion |
|---|---|---|
| M0 | Repo scaffold, uv project, Flutter project, CI workflows, Render + Supabase provisioned, keystore created | CI green on skeleton; `/health` live; debug APK installs on phone |
| M1 | core, auth, crypto, tasks, day_cycle · mobile app_shell, tasks, notifications (T-60/T-30) | Log in, add one-time & recurring tasks, get reminders, change status |
| M2 | schedule, ai_gateway, feasibility · mobile schedule, calendar_connect | Verdict card on every new task |
| M3 | predictor v1 · completion-check notification | Predicted end shown; one check per task; outcomes recorded |
| M4 | reports, email · mobile reports + EOD flow | EOD → daily report; Sunday → weekly; email on demand |
| M5 | assistant · mobile chat | Add task / mark status / EOD / email report via chat |
| M6 | First tagged release `v1.0.0` via `release-apk.yml` | Signed APK installed from GitHub Release |

---

## 18. Deferred Enhancements (discuss later)

- Predictor v2: algorithm, features, quantile target (approach fixed in §10.2).
- UI/UX polish, themes, home-screen widget, in-app "update available" check.
- Voice input (Groq Whisper).
- Data export / backup, key-rotation tooling.

## 19. Open Items

| # | Item | Needed by |
|---|---|---|
| O1 | Report recipient email address | M4 (set in app settings) |
| O2 | Confirm Groq model ids and the OpenRouter `:free` text fallback model | M2 |
| ~~O3~~ | Resolved 2026-11-09: defaults Work, Learning, Health, Personal, Chores + my own typed categories | — |
| O4 | Repo visibility: **private (default)** vs public — affects downloading Release APKs on the phone | M6 |
| O5 | Re-check Google's sideload developer-verification rules for my device/region | M6 |

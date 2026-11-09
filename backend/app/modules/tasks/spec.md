# Module spec — `backend/tasks`

> Governed by [`constitution.md`](../../../../constitution.md) and [`plan.md`](../../../../plan.md) (§4.1, §5.4, §7, §8.1, §8.4, §10.1).
> Status: draft for M1 (prediction wiring active from M3, feasibility link from M2).

## 1. Purpose & scope

Owns the user's tasks, recurring task templates and the status lifecycle with its audit trail.

| Capability | Served by |
|---|---|
| C2 Enter tasks (form/chat), recurring or one-time | `POST /tasks`, `TaskDraft`, `task_template`, `materialize_templates` |
| C6 Store predicted end + record outcomes; one completion check | `predicted_end_at`, `POST /tasks/{id}/check-response`, `history()` |
| C7 Status lifecycle completed / postponed / cancelled / can't do / auto `missed` | `POST /tasks/{id}/status`, `mark_unresolved_missed`, `task_status_event` |
| P9 Every outcome recorded | append-only `task_status_event`; no hard deletes |

Out of scope: feasibility scoring (`feasibility`), end-time computation (`predictor`, reached only through the port in §5.3), day open/close and the decision of *when* tasks become `missed` (`day_cycle`), notification scheduling (mobile), chat parsing (`assistant`). There is **no** `DELETE /tasks/{id}` — tasks are cancelled, never deleted (P9).

## 2. Folder layout

| File | Contents |
|---|---|
| `__init__.py` | exports `TaskService`, `TaskDTO`, `TaskDraft`, `Recurrence`, `DailyRecurrence`, `WeeklyRecurrence`, `TaskOutcomeDTO`, `TemplateDTO`, `TaskStatus`, `ActualEndSource`, `EndTimePredictorPort`, `PredictionRequest`, `PredictedEnd`, `KNOWN_CATEGORIES` |
| `api.py` | `APIRouter(prefix="/api/v1")`: `/tasks…`, `/templates…` |
| `service.py` | `TaskService` (public interface + state machine), pure helpers `matches(recurrence, d)`, `normalize_category()`, `local_to_utc()` |
| `repository.py` | `TaskRepository`, `TemplateRepository`, `StatusEventRepository` (SQLAlchemy, private) |
| `models.py` | ORM: `Task`, `TaskTemplate`, `TaskStatusEvent` |
| `schemas.py` | DTOs and request bodies (§5) |
| `state_machine.py` | transition table (§7.1) as data + `assert_transition()` (pure, unit-tested) |

## 3. Dependencies

- Modules: `core` (`Clock`, `AppSettingsService`, errors, `get_session`), `crypto` (`EncryptedText`), `auth` (`current_user` dependency in `api.py` only). **No** import of `predictor`, `feasibility` or `day_cycle` (plan §4 graph: `tasks ──▶ core, crypto`).
- Predictions are obtained through `EndTimePredictorPort` (defined here, implemented by `predictor`, injected by `main.py`) — dependency inversion so no import cycle exists (see §13 Q1).
- Third-party: `sqlalchemy[asyncio]`, `pydantic>=2`, stdlib `zoneinfo`.

## 4. Data owned

Enums are stored as `varchar` + `CHECK` (`sa.Enum(native_enum=False, create_constraint=True)`) to keep Alembic migrations simple. All tables have `created_at timestamptz not null default now()` and `updated_at timestamptz not null default now()` (ORM `onupdate`).

### 4.1 `task_template`
| Column | Type | Null | Default / notes |
|---|---|---|---|
| id | uuid PK | no | `gen_random_uuid()` |
| title 🔒 | text (`EncryptedText`, AAD `task_template.title`) | no | |
| notes 🔒 | text (`EncryptedText`, AAD `task_template.notes`) | yes | |
| category | varchar(32) | no | |
| start_local | time | yes | null ⇒ "anytime" occurrences |
| recurrence | jsonb | no | `CHECK (recurrence->>'freq' IN ('daily','weekly'))` |
| default_estimate_min | int | yes | `CHECK (1..720)` |
| starts_on | date | no | *added*: first local date the series may materialize (= `local_date` of the creating task) |
| active | bool | no | `true` |

Index: `ix_task_template_active (active)`.

### 4.2 `task`
| Column | Type | Null | Default / notes |
|---|---|---|---|
| id | uuid PK | no | |
| local_date | date | no | day the task belongs to (no FK to `day_session`) |
| template_id | uuid FK → task_template.id `ON DELETE RESTRICT` | yes | set **only** for the materialized/creating occurrence of a template on that date |
| origin_template_id | uuid FK → task_template.id | yes | *added*: series membership; = `template_id` for occurrences, copied to postponed copies (which have `template_id = NULL`) |
| title 🔒 / notes 🔒 | text (`EncryptedText`, AAD `task.title` / `task.notes`) | no / yes | |
| category | varchar(32) | no | |
| start_at | timestamptz | yes | null ⇒ anytime (no reminders, no check) |
| estimate_min | int | yes | `CHECK (1..720)` |
| predicted_end_at | timestamptz | yes | |
| prediction_method | varchar(64) | yes | e.g. `template_p60`, `ml:2026.11.20-1` |
| actual_end_at | timestamptz | yes | |
| actual_end_source | varchar enum `notification_action, manual, eod_resolution` | yes | |
| status | varchar enum `planned, completed, postponed, cancelled, cant_do, missed` | no | `planned` |
| status_reason 🔒 | text (`EncryptedText`, AAD `task.status_reason`) | yes | |
| postponed_to_task_id | uuid FK → task.id | yes | |
| feasibility_id | uuid FK → feasibility_assessment.id | yes | FK constraint added by the M2 migration that creates `feasibility_assessment` |
| feasibility_overridden | bool | no | `false` |
| created_via | varchar enum `form, chat, template` | no | |
| check_response | varchar enum `done, not_yet` | yes | latest completion-check answer |
| check_responded_at | timestamptz | yes | *added* |
| check_not_yet_at | timestamptz | yes | *added*: first time `not_yet` was answered (needed for the predictor's not-yet rate) |
| check_eta_min | smallint | yes | *added*: optional ETA given with `not_yet` |
| client_request_id | uuid | yes | *added*: idempotency key for `POST /tasks` retries (cold start) |

Constraints / indexes:
- `uq_task_local_date_template UNIQUE (local_date, template_id) WHERE template_id IS NOT NULL` (plan §5.4).
- `uq_task_client_request_id UNIQUE (client_request_id) WHERE client_request_id IS NOT NULL`.
- `CHECK (status <> 'completed' OR (actual_end_at IS NOT NULL AND actual_end_source IS NOT NULL))`
- `CHECK (status <> 'postponed' OR postponed_to_task_id IS NOT NULL)`
- `CHECK (status <> 'cant_do' OR status_reason IS NOT NULL)`
- `CHECK (feasibility_overridden = false OR feasibility_id IS NOT NULL)`
- `ix_task_local_date (local_date)`, `ix_task_status_local_date (status, local_date)`, `ix_task_origin_template (origin_template_id) WHERE origin_template_id IS NOT NULL`.

### 4.3 `task_status_event` (append-only)
| Column | Type | Null | Notes |
|---|---|---|---|
| id | uuid PK | no | |
| task_id | uuid FK → task.id | no | |
| from_status | varchar enum (task statuses) | yes | null = creation event |
| to_status | varchar enum | no | |
| at | timestamptz | no | `clock.now_utc()` |
| source | varchar enum `app, notification, chat, eod, system` | no | |
| reason 🔒 | text (`EncryptedText`, AAD `task_status_event.reason`) | yes | |

Index `ix_task_status_event_task (task_id, at)`. The repository exposes insert + select only (no update/delete).

Migration notes: M1 migration creates the three tables (no FK on `feasibility_id`); the M2 feasibility migration adds `fk_task_feasibility_id`. A CI test asserts the 🔒 columns use `EncryptedText` (plan §6.2).

## 5. Public interface

### 5.1 Service (canonical, plan §4.1)
```python
class TaskService:
    def __init__(
        self,
        session: AsyncSession,
        settings: AppSettingsService,
        clock: Clock,
        predictor: EndTimePredictorPort | None = None,
    ) -> None: ...
    async def day_plan(self, local_date: date) -> list[TaskDTO]: ...
    async def tasks_in_range(self, start: date, end: date) -> list[TaskDTO]: ...  # inclusive
    async def history(
        self, *, template_id: UUID | None = None, category: str | None = None, since: date | None = None
    ) -> list[TaskOutcomeDTO]: ...  # labelled durations
    async def materialize_templates(self, local_date: date) -> int: ...  # idempotent
    async def unresolved(self, local_date: date) -> list[TaskDTO]: ...  # status == planned
    async def mark_unresolved_missed(self, local_date: date) -> int: ...
    # used by api.py (and by assistant proposals executed through the same endpoints)
    async def get(self, task_id: UUID) -> TaskDTO: ...
    async def create(self, req: CreateTaskRequest) -> CreateTaskResult: ...
    async def update(self, task_id: UUID, patch: TaskPatch) -> TaskDTO: ...
    async def change_status(self, task_id: UUID, cmd: StatusCommand) -> StatusChangeResult: ...
    async def check_response(self, task_id: UUID, cmd: CheckResponse) -> TaskDTO: ...
    async def list_templates(self, active: bool | None) -> list[TemplateDTO]: ...
    async def get_template(self, template_id: UUID) -> TemplateDTO: ...
    async def update_template(self, template_id: UUID, patch: TemplatePatch) -> TemplateDTO: ...
    async def deactivate_template(self, template_id: UUID, cancel_planned: bool) -> None: ...
```
Day-ordering in all list methods: `start_at ASC NULLS LAST, created_at ASC`. All methods flush but **do not commit**; the request-scoped session (core) commits, so `day_cycle` can mark tasks `missed` in its own transaction.

### 5.2 DTOs (`schemas.py`)
```python
KNOWN_CATEGORIES = ("Work", "Learning", "Health", "Personal", "Chores")
TaskStatus = Literal["planned","completed","postponed","cancelled","cant_do","missed"]
ActualEndSource = Literal["notification_action","manual","eod_resolution"]

class DailyRecurrence(BaseModel):  freq: Literal["daily"]
class WeeklyRecurrence(BaseModel): freq: Literal["weekly"]; byweekday: list[int]  # 1..7 unique items in 0..6 (0=Mon), stored sorted
Recurrence = Annotated[DailyRecurrence | WeeklyRecurrence, Field(discriminator="freq")]

class TaskDraft(BaseModel):            # shared with feasibility + assistant (plan §4.1)
    title: str                         # 1..200 chars after strip
    notes: str | None = None           # ≤ 2000
    category: str = "Personal"         # normalized, §7.6
    start_at: AwareDatetime | None = None
    estimate_min: int | None = None    # 1..720
    is_recurring: bool                 # required — the app always asks
    recurrence: Recurrence | None = None   # required iff is_recurring
    local_date: date | None = None     # extra field: needed for anytime tasks; derived when omitted (§7.5)

class CreateTaskRequest(TaskDraft):
    assessment_id: UUID | None = None
    overridden: bool = False
    created_via: Literal["form","chat"] = "form"
    client_request_id: UUID | None = None

class TaskDTO(BaseModel):
    id: UUID; local_date: date; template_id: UUID | None; origin_template_id: UUID | None
    is_recurring: bool                 # origin_template_id is not None
    title: str; notes: str | None; category: str
    start_at: datetime | None; estimate_min: int | None
    predicted_end_at: datetime | None; prediction_method: str | None
    actual_end_at: datetime | None; actual_end_source: ActualEndSource | None
    status: TaskStatus; status_reason: str | None
    postponed_to_task_id: UUID | None; postponed_from_task_id: UUID | None   # reverse link, derived
    feasibility_id: UUID | None; feasibility_overridden: bool
    created_via: Literal["form","chat","template"]
    check_response: Literal["done","not_yet"] | None; check_responded_at: datetime | None
    check_not_yet_at: datetime | None; check_eta_min: int | None
    created_at: datetime; updated_at: datetime

class TaskOutcomeDTO(BaseModel):       # one labelled duration (§7.7)
    task_id: UUID; local_date: date; template_id: UUID | None   # = origin_template_id
    category: str; start_at: datetime; actual_end_at: datetime; duration_min: float
    estimate_min: int | None; predicted_end_at: datetime | None; prediction_method: str | None
    actual_end_source: Literal["notification_action","manual"]
    weekday: int                       # local_date.weekday(), 0=Mon
    start_minute_local: int            # minutes since local midnight of start_at
    check_not_yet: bool                # check_not_yet_at is not None

class TemplateDTO(BaseModel):
    id: UUID; title: str; notes: str | None; category: str; start_local: time | None
    recurrence: Recurrence; default_estimate_min: int | None; starts_on: date; active: bool
    created_at: datetime; updated_at: datetime

class CreateTaskResult(BaseModel): task: TaskDTO; template: TemplateDTO | None; replayed: bool
class TaskPatch(BaseModel):            # all optional; explicit null clears notes/start_at/estimate_min
    title: str | None; notes: str | None; category: str | None; start_at: AwareDatetime | None
    estimate_min: int | None; scope: Literal["this","future"] = "this"
class StatusCommand = Annotated[Completed | Postponed | Cancelled | CantDo, Field(discriminator="status")]
    # Completed{status:"completed", finished_at: AwareDatetime|None, source: "app"|"chat"|"eod"="app"}
    # Postponed{status:"postponed", new_start_at: AwareDatetime|None, new_local_date: date|None, source}
    # Cancelled{status:"cancelled", reason: str|None (≤500), source}
    # CantDo{status:"cant_do", reason: str (1..500), source}
class StatusChangeResult(BaseModel): task: TaskDTO; created_task: TaskDTO | None
class CheckResponse = Annotated[CheckDone | CheckNotYet, Field(discriminator="response")]
    # CheckDone{response:"done", finished_at: AwareDatetime, responded_at: AwareDatetime|None}
    # CheckNotYet{response:"not_yet", eta_min: int|None (5..240), responded_at: AwareDatetime|None}
class TemplatePatch(BaseModel):
    title, notes, category, start_local: time | None, recurrence: Recurrence | None,
    default_estimate_min: int | None, active: bool | None          # all optional
```

### 5.3 Prediction port (defined here, implemented by `predictor`)
```python
class PredictionRequest(BaseModel):
    title: str
    category: str
    start_at: datetime | None
    estimate_min: int | None
    template_id: UUID | None


class PredictedEnd(BaseModel):
    predicted_end_at: datetime | None
    method: str


class EndTimePredictorPort(Protocol):
    async def predict_end(self, req: PredictionRequest) -> PredictedEnd: ...
```
`main.py` wires `predictor.TaskPredictionAdapter(PredictorService(...))`. `template_id` passed = `origin_template_id`. If `predictor is None` (M1) or the call raises, `predicted_end_at`/`prediction_method` stay null and a warning is logged (no title in logs).

## 6. HTTP endpoints

All routes: `/api/v1`, `Depends(current_user)`, and the `day_cycle.ensure_current_day` dependency attached by `main.py` (lazy midnight close). Errors are RFC 7807 (`application/problem+json`) with extension member `code`.

| Method & path | Body | Success | Errors |
|---|---|---|---|
| `POST /tasks` | `CreateTaskRequest` | 201 `{task, template}` (+`Location`); 200 on idempotent replay | 422 validation; 422 `task.unknown_assessment` (FK violation) |
| `GET /tasks?date=YYYY-MM-DD` | — (date default: today local) | 200 `[TaskDTO]` | 422 bad date |
| `GET /tasks/{id}` | — | 200 `TaskDTO` | 404 |
| `PATCH /tasks/{id}` | `TaskPatch` | 200 `TaskDTO` | 404, 409 `task.not_editable`, 422 `task.start_not_on_local_date`, 422 `task.not_recurring` |
| `POST /tasks/{id}/status` | `StatusCommand` | 200 `StatusChangeResult` | 404, 409 `task.invalid_transition`, 422 |
| `POST /tasks/{id}/check-response` | `CheckResponse` | 200 `TaskDTO` | 404, 409 `task.no_check`, 409 `task.invalid_transition`, 422 |
| `GET /templates?active=true\|false` | — (omitted = all) | 200 `[TemplateDTO]` | |
| `GET /templates/{id}` | — | 200 `TemplateDTO` | 404 |
| `PATCH /templates/{id}` | `TemplatePatch` | 200 `TemplateDTO` | 404, 422 |
| `DELETE /templates/{id}?cancel_planned=false` | — | 204 (idempotent) | 404 |

Example `POST /tasks`:
```json
{"title":"Gym","category":"health","start_at":"2026-11-09T18:00:00+01:00","estimate_min":60,
 "is_recurring":true,"recurrence":{"freq":"weekly","byweekday":[0,2,4]},
 "assessment_id":"5f0c…","overridden":false,"created_via":"form","client_request_id":"9b1e…"}
```
→ `201`
```json
{"task":{"id":"c1…","local_date":"2026-11-09","template_id":"t7…","origin_template_id":"t7…","is_recurring":true,
  "title":"Gym","category":"Health","start_at":"2026-11-09T17:00:00Z","estimate_min":60,
  "predicted_end_at":"2026-11-09T18:10:00Z","prediction_method":"category_p60","status":"planned",
  "feasibility_id":"5f0c…","feasibility_overridden":false,"created_via":"form","check_response":null, "…":"…"},
 "template":{"id":"t7…","recurrence":{"freq":"weekly","byweekday":[0,2,4]},"start_local":"18:00:00",
  "starts_on":"2026-11-09","active":true,"…":"…"}}
```
Example `POST /tasks/{id}/status` `{"status":"postponed","new_start_at":"2026-11-10T09:00:00+01:00","source":"eod"}` → `200 {"task":{…"status":"postponed","postponed_to_task_id":"d2…"},"created_task":{…"id":"d2…","local_date":"2026-11-10","status":"planned"}}`.

Example problem:
```json
{"type":"https://errors.daily-assistant/task.invalid_transition","title":"Invalid status transition",
 "status":409,"detail":"cancelled → completed is not allowed","code":"task.invalid_transition"}
```

## 7. Behaviour & rules

### 7.1 Status state machine
Terminal statuses: `completed, postponed, cancelled, cant_do`. `missed` is semi-terminal (user may still record what really happened). Same-status requests are 409 except the idempotent replays noted in §7.2.

| From → To | Trigger | Required fields | Side effects | Event (`source`) |
|---|---|---|---|---|
| — → planned | create / materialize / postpone copy | §7.5 | prediction via port | `from=NULL`, source `app`/`chat`/`system` (materialize) |
| planned → completed | `status` cmd | `finished_at` (default now) | `actual_end_at=finished_at`; `actual_end_source` = `eod_resolution` if source `eod`, else `manual` | `app`/`chat`/`eod` |
| planned → completed | `check-response done` | `finished_at` | `actual_end_source=notification_action`, `check_response=done` | `notification` |
| planned → postponed | `status` cmd | `new_start_at` xor/and `new_local_date` (§7.3) | creates new planned task; `postponed_to_task_id` set | original + creation event of copy |
| planned → cancelled | `status` cmd | `reason` optional | `status_reason=reason` | with reason |
| planned → cant_do | `status` cmd | `reason` 1..500 chars (422 if blank) | `status_reason=reason` | with reason |
| planned → missed | `mark_unresolved_missed` only (API → 422) | — | none | `system` |
| missed → completed | `status` cmd or `check-response done` (offline outbox replay after midnight) | `finished_at` | as planned → completed | as above |
| missed → postponed | `status` cmd | as above | as above | as above |
| any other | — | — | 409 `task.invalid_transition` | — |

`finished_at` validation: aware; `≤ now + 2 min`; if `start_at` set then `finished_at > start_at` and `finished_at − start_at ≤ 24 h`; otherwise `finished_at ≥ local midnight of local_date`. Violations → 422. On every terminal transition the client cancels that task's notifications (mobile spec); server has no notification state.

### 7.2 Completion check (`check-response`)
- Task must have `start_at` (otherwise 409 `task.no_check`).
- `done{finished_at}`: if status ∈ {planned, missed} → transition to `completed` (row above), `check_response=done`, `check_responded_at=responded_at or now`. If status = completed and `check_response = done` → idempotent 200, no change. If status = completed via another path → set `check_response=done` only, `actual_end_*` untouched. Other statuses → 409.
- `not_yet{eta_min?}`: only from `planned`; sets `check_response=not_yet`, `check_responded_at`, `check_eta_min=eta_min`, and `check_not_yet_at` if null. No status change, no event. Identical replay (already `not_yet`, same eta) → 200. Non-planned → 409.
- The server never schedules anything; "one check per task" is enforced on device (P5).

### 7.3 Postponement
1. Resolve target: `new_start_at` given → `new_local_date := local date of new_start_at in tz`; if `new_local_date` also given it must match (422). Only `new_local_date` → anytime copy (`start_at=NULL`). Neither → 422.
2. `new_local_date ≥ today_local`, `≤ today + 365 d`; `new_start_at > now` (422). Target must differ from the current `(local_date, start_at)` (422 `task.postpone_noop`).
3. Copy: `title, notes, category, estimate_min, origin_template_id, created_via`; `template_id=NULL` (so the unique series constraint never collides with that date's own occurrence — both may coexist); `feasibility_id=NULL`, `feasibility_overridden=false`; `status=planned`; new prediction via port.
4. Original: `status=postponed`, `postponed_to_task_id=copy.id`, reason none. Two events written in the same transaction.

### 7.4 Recurrence & materialization
- `matches(r, d)`: `daily` → true; `weekly` → `d.weekday() in r.byweekday` (Python numbering **0=Mon … 6=Sun**, same as `fixed_schedule_block.weekday`).
- `materialize_templates(d)`: `tz = settings.tz()`; select `active` templates with `starts_on ≤ d`; for each matching, `INSERT … ON CONFLICT (local_date, template_id) WHERE template_id IS NOT NULL DO NOTHING RETURNING id` with `template_id = origin_template_id = template.id`, title/notes/category copied, `estimate_min = default_estimate_min`, `start_at = local_to_utc(d, start_local, tz)` (or NULL), `created_via=template`, status planned + creation event (source `system`) for inserted rows only; then predict for inserted rows. Returns number inserted. Re-running is a no-op because the occurrence row persists whatever its status (cancelled/postponed occurrences are **not** recreated).
- `local_to_utc(d, t, tz)`: `datetime.combine(d, t).replace(tzinfo=tz, fold=0).astimezone(UTC)`. Non-existent local times (spring-forward gap) therefore shift forward by the gap (02:30 → 03:30); ambiguous times (fall-back) take the first occurrence.
- Creating a recurring task (`is_recurring=true`): one transaction inserts the template (`starts_on = task.local_date`, `start_local` = local time of `start_at` or NULL, `default_estimate_min = estimate_min`) and the task with `template_id = origin_template_id = template.id` (even if `local_date` does not match the recurrence — it is the series' first instance). Future days get occurrences when `day_cycle` opens them. Days that are never opened are not back-filled.

### 7.5 Creation, dates and time zones
- `tz = AppSettingsService.tz()`, `today = clock.today_local(tz)`. Naive datetimes are rejected (Pydantic `AwareDatetime`) and stored as UTC.
- `local_date` resolution: given → used; else `start_at` given → `start_at.astimezone(tz).date()`; else `today`. If both given, `start_at.astimezone(tz).date() == local_date` else 422 `task.start_not_on_local_date`.
- `today ≤ local_date ≤ today + 365 d` (422 otherwise). `start_at` earlier than now is allowed (logging a started task).
- `is_recurring` ⇔ `recurrence is not None` (422). `overridden=true` requires `assessment_id` (422). `assessment_id` is stored as `feasibility_id`; its existence is enforced by the FK only (tasks cannot read feasibility) → `IntegrityError` mapped to 422 `task.unknown_assessment`. The verdict is not re-checked (P7: advise, don't block).
- Idempotency: when `client_request_id` matches an existing task → return it with `replayed=true`, HTTP 200, no new rows.
- Overlaps with other tasks or schedule blocks are **not** validated here (feasibility advises).

### 7.6 Categories
Free text allowed. Normalization: strip, collapse internal whitespace, length 1..32, regex `^[\w][\w &/+-]*$` (Unicode `\w`); if it equals a `KNOWN_CATEGORIES` entry case-insensitively, the canonical spelling is stored (`"health"` → `"Health"`); otherwise stored as given. Category is plaintext by plan design (used for grouping in SQL); the UI should offer the known list first. `history(category=…)` compares with `casefold()`.

### 7.7 History labelling (`history()`)
A task is a **labelled duration** iff all hold: `status = completed`; `start_at IS NOT NULL`; `actual_end_at IS NOT NULL`; `actual_end_source IN ('notification_action','manual')` (`eod_resolution` excluded — times guessed at EOD, plan §10.1); `1 ≤ duration_min ≤ 1440` where `duration_min = (actual_end_at − start_at).total_seconds()/60`. Filters: `template_id` → `origin_template_id = :id` (postponed copies count for their series); `category` → casefold equality (in Python after load is fine; category is plaintext so SQL `lower()` also allowed); `since` → `local_date ≥ since`. Ordered by `actual_end_at ASC`. Titles are not decrypted (not needed).

### 7.8 Editing (`PATCH /tasks/{id}`)
- Allowed only when status = `planned`; for other statuses only `notes` may be patched (else 409 `task.not_editable`).
- `start_at` must stay on the task's `local_date` (422 → use postpone). Null clears to anytime.
- If `start_at`, `estimate_min` or `category` changed → re-predict. If `start_at` changed → clear `check_response`, `check_responded_at`, `check_eta_min`, `check_not_yet_at` (a new check will be scheduled).
- Scope semantics for recurring tasks:

| scope | Effect |
|---|---|
| `this` (default) | Only this occurrence row. Template and other occurrences unchanged. |
| `future` | This row **and** the template (`origin_template_id`): `title→title`, `notes→notes`, `category→category`, `estimate_min→default_estimate_min`, `start_at→start_local = local time of start_at` (null → null). Applies to every date not yet materialized (in practice from tomorrow). Other already-existing rows (e.g. postponed copies) are untouched. 422 `task.not_recurring` if `origin_template_id` is null. Recurrence itself is changed only via `PATCH /templates/{id}`. |

### 7.9 Templates
- `PATCH /templates/{id}` changes affect only dates not yet materialized; existing occurrences are never rewritten. `recurrence` validated as in §5.2. Setting `active=true` re-enables the series from the next materialization (no back-fill).
- `DELETE /templates/{id}` = soft deactivate (`active=false`); rows are never hard-deleted (FKs from tasks, P9). With `cancel_planned=true`, occurrences with `origin_template_id = id`, `local_date ≥ today`, `status = planned` are cancelled (event source `app`, reason null). Repeated DELETE → 204.

### 7.10 `unresolved` / `mark_unresolved_missed`
`unresolved(d)` = tasks on `d` with status `planned`. `mark_unresolved_missed(d)` = `UPDATE task SET status='missed' WHERE local_date=:d AND status='planned' RETURNING id`, one event per row (`from=planned, to=missed, source=system`); returns row count; idempotent (second call returns 0).

## 8. Configuration
| Setting | Default | Meaning |
|---|---|---|
| `TASKS_MAX_FUTURE_DAYS` | 365 | furthest `local_date` accepted |
| `TASKS_FINISH_SKEW_S` | 120 | allowed clock skew for `finished_at` in the future |
| `TASKS_MAX_TITLE_LEN` / `TASKS_MAX_NOTES_LEN` / `TASKS_MAX_REASON_LEN` | 200 / 2000 / 500 | |
Timezone comes from `app_settings.timezone` only.

## 9. Errors & degradation
- `NotFoundError` → 404; `ConflictError` → 409 (`task.invalid_transition`, `task.not_editable`, `task.no_check`); `DomainValidationError` → 422 (codes above). Unknown `assessment_id` FK violation → 422.
- Predictor port failure/timeout (2 s budget) → task saved with null prediction (P10); mobile then schedules no completion check for that task.
- Decryption failure (wrong key) → 500 via core, logged with task id only.

## 10. Security & privacy
- 🔒 `title`, `notes`, `status_reason`, event `reason`, template `title`/`notes` are encrypted by `crypto` TypeDecorators; they are never used in SQL `WHERE`/`ORDER BY`.
- Logs contain ids, statuses, categories — never titles, notes or reasons.
- `PredictionRequest.title` goes to `predictor` in-process only (no external call in v1).
- All endpoints require the JWT; ids are UUIDv4 (no enumeration).

## 11. Testing plan
Fixtures: `db_session` (Postgres container, per-test transaction rollback), `fake_clock` (`core` `FakeClock`, settable `now_utc`), `tz_berlin` (app_settings tz `Europe/Berlin`), `fake_predictor` (records `PredictionRequest`s, returns fixed `PredictedEnd`), `failing_predictor`, `api_client` (httpx `AsyncClient`, `current_user` overridden), `raw_conn` for ciphertext checks.

Unit (`tests/tasks/unit/`): `test_matches_daily`, `test_matches_weekly_monday_is_zero`, `test_recurrence_validation_rejects_empty_or_dup_weekdays`, `test_state_machine_table_all_pairs` (parametrized over 6×6), `test_normalize_category_canonicalizes_known`, `test_normalize_category_rejects_invalid`, `test_local_to_utc_spring_gap_shifts_forward`, `test_local_to_utc_fall_back_first_occurrence`, `test_local_date_resolution`.

Integration (`tests/tasks/integration/`): `test_create_one_time_anytime_task`, `test_create_recurring_creates_template_and_links`, `test_create_requires_is_recurring`, `test_create_rejects_start_not_on_local_date`, `test_create_rejects_past_local_date`, `test_create_links_assessment_and_override`, `test_create_override_without_assessment_422`, `test_create_unknown_assessment_422`, `test_create_idempotent_client_request_id`, `test_create_prediction_stored`, `test_create_survives_predictor_failure`, `test_complete_manual_sets_actual_end`, `test_complete_eod_source`, `test_finished_before_start_422`, `test_postpone_creates_linked_copy`, `test_postpone_recurring_occurrence_no_unique_clash`, `test_postpone_anytime_to_date`, `test_cant_do_requires_reason`, `test_missed_not_settable_via_api`, `test_missed_to_completed_allowed`, `test_terminal_transition_409`, `test_check_done_completes_with_notification_source`, `test_check_done_replay_idempotent`, `test_check_not_yet_then_done`, `test_check_on_anytime_task_409`, `test_patch_this_scope_leaves_template`, `test_patch_future_scope_updates_template`, `test_patch_start_off_date_422`, `test_patch_start_resets_check`, `test_materialize_idempotent`, `test_materialize_weekly_only_on_matching_days`, `test_materialize_respects_starts_on_and_active`, `test_materialize_does_not_recreate_cancelled_occurrence`, `test_materialize_dst_gap_start`, `test_deactivate_template_cancel_planned`, `test_history_labelling_rules`, `test_history_template_includes_postponed_copies`, `test_mark_unresolved_missed_idempotent_with_events`, `test_encrypted_columns_raw_rows_have_no_plaintext`, `test_status_events_append_only`.

## 12. Acceptance criteria
| ID | Given / When / Then | Test |
|---|---|---|
| TASKS-AC-01 | Given tz Europe/Berlin, When I POST a one-time task with `start_at` 2026-11-09T18:00+01:00, Then it is stored with `local_date` 2026-11-09, status `planned`, a creation event, and `predicted_end_at` from the predictor | `test_create_prediction_stored` |
| TASKS-AC-02 | Given a POST without `is_recurring`, Then 422 | `test_create_requires_is_recurring` |
| TASKS-AC-03 | Given a recurring weekly [0,2,4] task created on Mon, When Tue/Wed are materialized, Then Wed has one occurrence and Tue none; re-materializing Wed returns 0 | `test_materialize_weekly_only_on_matching_days`, `test_materialize_idempotent` |
| TASKS-AC-04 | Given `start_at` whose local date ≠ `local_date`, Then 422 `task.start_not_on_local_date` | `test_create_rejects_start_not_on_local_date` |
| TASKS-AC-05 | Given an assessment and `overridden=true`, Then `feasibility_id` and `feasibility_overridden=true` are stored; `overridden=true` without assessment → 422 | `test_create_links_assessment_and_override`, `test_create_override_without_assessment_422` |
| TASKS-AC-06 | Given a planned task, When postponed to tomorrow 09:00, Then original is `postponed` with `postponed_to_task_id` = new planned task on tomorrow | `test_postpone_creates_linked_copy` |
| TASKS-AC-07 | Given a recurring occurrence postponed to a day that has its own occurrence, Then both tasks exist without constraint error | `test_postpone_recurring_occurrence_no_unique_clash` |
| TASKS-AC-08 | When `cant_do` is sent without reason, Then 422; with reason, Then reason stored encrypted | `test_cant_do_requires_reason`, `test_encrypted_columns_raw_rows_have_no_plaintext` |
| TASKS-AC-09 | When `check-response done{finished_at}` arrives, Then status `completed`, `actual_end_at=finished_at`, `actual_end_source=notification_action`; replay → no change | `test_check_done_completes_with_notification_source`, `test_check_done_replay_idempotent` |
| TASKS-AC-10 | When `not_yet` then later `done`, Then `check_not_yet_at` stays set and task is completed | `test_check_not_yet_then_done` |
| TASKS-AC-11 | When the API tries to set `missed`, Then 422; `mark_unresolved_missed` marks only `planned` tasks and is idempotent | `test_missed_not_settable_via_api`, `test_mark_unresolved_missed_idempotent_with_events` |
| TASKS-AC-12 | Given a completed task, When cancel is requested, Then 409 | `test_terminal_transition_409` |
| TASKS-AC-13 | PATCH scope `this` changes only the row; scope `future` also updates the template | `test_patch_this_scope_leaves_template`, `test_patch_future_scope_updates_template` |
| TASKS-AC-14 | `history()` returns only completed timed tasks with source notification_action/manual and 1–1440 min durations | `test_history_labelling_rules` |
| TASKS-AC-15 | DELETE template deactivates it (no hard delete); next materialization creates nothing | `test_deactivate_template_cancel_planned`, `test_materialize_respects_starts_on_and_active` |
| TASKS-AC-16 | Predictor failure does not prevent task creation | `test_create_survives_predictor_failure` |
| TASKS-AC-17 | Same `client_request_id` twice → one task, second response 200 `replayed=true` | `test_create_idempotent_client_request_id` |

## 13. Open questions
1. **Prediction wiring vs dependency graph.** Plan §4 says `tasks ──▶ core, crypto` and `predictor ──▶ tasks`, yet tasks stores `predicted_end_at` for form, chat, postponed and materialized tasks. Resolved here with the `EndTimePredictorPort` (dependency inversion, wired in `main.py`). Plan should mention it.
2. **Cross-module FK** `task.feasibility_id → feasibility_assessment` couples tasks' schema to a module that depends on tasks; accepted at DB level only (added in M2 migration).
3. **Added columns** (`origin_template_id`, `starts_on`, `check_*`, `client_request_id`) are not in plan §5.4; needed for postponed-series history, no-back-fill, not-yet rate and retry idempotency. Plan §5.4 and the ER diagram should be updated.
4. Plan §7 lists `postponed{new_start_at}` only; this spec adds `new_local_date` for anytime tasks ("Postpone to tomorrow" in the EOD sheet).
5. Converting an existing one-time task into a recurring one is not supported (create a new recurring task). Confirm.
6. O3: initial categories Work, Learning, Health, Personal, Chores + free text — confirm; free-text categories are stored in plaintext.
7. Tasks added to a day after it was closed stay `planned` until `day_cycle`'s next sweep marks them `missed` (tasks cannot see day state without a cycle). Mobile should block adding tasks to a closed day.

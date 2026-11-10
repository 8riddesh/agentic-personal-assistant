# Module spec — `backend/day_cycle`

> Governed by [`constitution.md`](../../../../constitution.md) and [`plan.md`](../../../../plan.md) (§4.1, §5.5, §7, §8.3, §8.4, ADR-010).
> Status: **M1 implemented** (2026-11-09); the report/predictor steps become real in M3/M4. Covered by `tests/day_cycle/`.
> Notes on the implementation:
> - `predictor` and `reports` do not exist yet, so the pipeline talks to them through ports defined here
>   (`PredictorHook`, `ReportGenerator` with an `enabled` flag) with `NullPredictorHook` / `NullReportGenerator` wired by
>   `app.main`. With `enabled = False` the report steps and the weekly-pending rule are skipped, so a closed day is never
>   re-scheduled forever. M3/M4 replace the null ports with adapters (the report adapter opens its own session).
> - The per-date pipeline lock is a session-level advisory lock held on a **dedicated** connection for the whole run
>   (the pooled session connection is released after each commit and would lose it). Postgres only.
> - A pipeline failure on the last allowed attempt closes the day immediately (`DAY_CLOSE_MAX_ATTEMPTS` real attempts);
>   closed days owed a weekly report are bounded by the same counter.
> - `ensure_current_day` memoises `(tz, today, checked_at)` and re-checks when the local date changes, so the midnight
>   close is never delayed by the memo. The memo is also refreshed by the `/days` routes.
> - `DAY-AC-06` (concurrent close) runs only against Postgres (CI); locally it is skipped.

## 1. Purpose & scope

Owns the notion of a **day session**: opening today, the user-declared End of Day, the lazy auto-close at local midnight, and the close pipeline that feeds the predictor and reports.

| Capability | Served by |
|---|---|
| C8 User-declared EOD (button or chat proposal) + auto-close at 12 AM | `POST /days/current/close`, `DayService.current()` catch-up |
| C7 auto `missed` | close pipeline step 1 → `TaskService.mark_unresolved_missed` |
| C9 daily report at EOD, weekly on Sunday | pipeline → `ReportService.generate` |
| C6 / §10.2 retrain hook | pipeline → `PredictorService.on_day_closed` |
| §8.4 recurring tasks appear each day | `current()` → `TaskService.materialize_templates(today)` |

Out of scope: report rendering/content (`reports`), training logic (`predictor`), task status rules (`tasks`), notification cancellation (mobile), parsing "EOD done for the day" (`assistant` returns a proposal; the app calls `POST /days/current/close`). Re-opening a closed day is not supported.

## 2. Folder layout

| File | Contents |
|---|---|
| `__init__.py` | exports `DayService`, `DayDTO`, `DaySummary`, `CloseMode`, `CloseResultDTO`, `DayState`, `ensure_current_day` |
| `api.py` | router `/api/v1/days…` |
| `service.py` | `DayService` (current / close / get), catch-up algorithm |
| `pipeline.py` | `ClosePipeline.run(local_date)` (background job, own DB session), `PipelineScheduler` protocol + FastAPI `BackgroundTasks` implementation, in-process running set |
| `dependencies.py` | `ensure_current_day` FastAPI dependency (lazy midnight close for other day-scoped routers) |
| `repository.py` | `DaySessionRepository` (row locks, advisory lock helpers) |
| `models.py` | ORM `DaySession` |
| `schemas.py` | DTOs |

## 3. Dependencies

- Modules: `core` (`Clock`, `AppSettingsService`, errors, `get_session`, `session_factory`), `tasks` (`TaskService`), `predictor` (`PredictorService.on_day_closed`), `reports` (`ReportService.generate`, `ReportKind`), `auth` (`current_user`, api only). Plan §4: `day_cycle ──▶ tasks, predictor, reports`.
- No dependency on `crypto`: `day_session` holds no personal text.
- Third-party: `sqlalchemy[asyncio]`, `pydantic`, FastAPI `BackgroundTasks`, stdlib `zoneinfo`.

## 4. Data owned — `day_session`

| Column | Type | Null | Default / notes |
|---|---|---|---|
| id | uuid PK | no | |
| local_date | date | no | `UNIQUE` |
| opened_at | timestamptz | no | time the row was created |
| closed_at | timestamptz | yes | user close: `now`; auto: local `23:59:59` of `local_date` → UTC |
| close_mode | varchar enum `user, auto_midnight` | yes | |
| state | varchar enum `open, closing, closed` | no | `open` |
| daily_report_id | uuid FK → report.id | yes | set by pipeline |
| weekly_report_id | uuid FK → report.id | yes | set by pipeline |
| auto_created | bool | no | `false` — *added*: row created by catch-up for a never-opened date that had tasks |
| missed_marked_at | timestamptz | yes | *added*: pipeline checkpoint |
| predictor_done_at | timestamptz | yes | *added*: pipeline checkpoint |
| weekly_due | bool | no | `false` — *added*: weekly report must be produced from this session |
| close_started_at | timestamptz | yes | *added*: lease start of the current pipeline attempt |
| close_attempts | smallint | no | `0` — *added* |
| last_error | varchar(200) | yes | *added*: exception class + short code, never personal text |
| created_at, updated_at | timestamptz | no | `now()` |

Constraints: `CHECK (state = 'open' OR (closed_at IS NOT NULL AND close_mode IS NOT NULL))`; index `ix_day_session_state (state) WHERE state <> 'closed'`; partial index `ix_day_session_weekly_pending (local_date) WHERE weekly_due AND weekly_report_id IS NULL`. FKs to `report` are added by the M4 reports migration (M1 creates the columns without FK).

## 5. Public interface

```python
class CloseMode(StrEnum): USER = "user"; AUTO_MIDNIGHT = "auto_midnight"
DayState = Literal["open", "closing", "closed"]

class DayService:
    def __init__(self, session: AsyncSession, settings: AppSettingsService, clock: Clock,
                 tasks: TaskService, scheduler: PipelineScheduler) -> None: ...
    async def current(self) -> DayDTO: ...        # auto-closes stale day(s), opens today, materializes templates
    async def close(self, mode: CloseMode) -> CloseResultDTO: ...   # closes TODAY's session
    async def get(self, local_date: date) -> DayDTO: ...
    async def unresolved(self) -> list[TaskDTO]: ...                # extra helper for the API

class PipelineScheduler(Protocol):
    def schedule(self, dates: list[date]) -> None: ...  # FastAPI impl: background_tasks.add_task(run_pipelines, dates)

async def ensure_current_day(background_tasks: BackgroundTasks, ...) -> None   # FastAPI dependency
```
`predictor` and `reports` are not constructor arguments of `DayService`: they are only used by `ClosePipeline`, which builds its own `AsyncSession` from `core.session_factory` and constructs `TaskService`, `PredictorService`, `ReportService` itself (the request session is closed when background tasks run).

```python
class DaySummary(BaseModel):
    total: int
    by_status: dict[TaskStatus, int]  # all six keys present, zeros included


class DayDTO(BaseModel):
    id: UUID
    local_date: date
    state: DayState
    is_today: bool
    opened_at: datetime
    closed_at: datetime | None
    close_mode: CloseMode | None
    daily_report_id: UUID | None
    weekly_report_id: UUID | None
    weekly_due: bool
    auto_created: bool
    summary: DaySummary


class CloseResultDTO(BaseModel):
    local_date: date
    state: DayState
    close_mode: CloseMode
    missed_count: int  # tasks marked missed by THIS call (0 on replay)
    daily_report_id: UUID | None  # null while state == closing (see §13 Q1)
    weekly_report_id: UUID | None
    weekly_expected: bool  # = weekly_due
    already_closed: bool
```

## 6. HTTP endpoints

All routes `Depends(current_user)`; problems are RFC 7807 with `code`.

| Method & path | Response | Codes |
|---|---|---|
| `GET /days/current` | `DayDTO` for today (any state) | 200 |
| `GET /days/{date}` | `DayDTO` | 200; 404 `day.not_found` (no session for date); 422 bad date |
| `GET /days/current/unresolved` | `{"local_date": "...", "tasks": [TaskDTO]}` (status `planned`; empty when today is closed/closing) | 200 |
| `POST /days/current/close` | `CloseResultDTO` | 202 close started or in progress; 200 already closed |

`GET /days/{date}`, `/days/current/unresolved` and `/days/current/close` run the catch-up first (they call `current()` internally).

Example `POST /days/current/close` (no body) → `202`:
```json
{"local_date":"2026-11-08","state":"closing","close_mode":"user","missed_count":2,
 "daily_report_id":null,"weekly_report_id":null,"weekly_expected":true,"already_closed":false}
```
Polling `GET /days/2026-11-08` → `{"state":"closed","daily_report_id":"r1…","weekly_report_id":"r2…",…}`. Repeat close after that → `200 {…"state":"closed","already_closed":true,"missed_count":0,"daily_report_id":"r1…"}`.

Example `GET /days/current`:
```json
{"id":"8c…","local_date":"2026-11-09","state":"open","is_today":true,"opened_at":"2026-11-09T06:40:12Z",
 "closed_at":null,"close_mode":null,"daily_report_id":null,"weekly_report_id":null,"weekly_due":false,
 "auto_created":false,"summary":{"total":6,"by_status":{"planned":6,"completed":0,"postponed":0,"cancelled":0,"cant_do":0,"missed":0}}}
```

## 7. Behaviour & rules

### 7.1 "Today"
`tz = await settings.tz()` (IANA from `app_settings.timezone`), `today = clock.today_local(tz)`, `now = clock.now_utc()`. Local Sunday ⇔ `d.weekday() == 6`; week = Monday `d − d.weekday()` … Sunday (fixed Mon–Sun per user decision; see §13 Q3). `local_end(d) = local_to_utc(d, time(23,59,59), tz)` (same DST rule as tasks: `fold=0`).

### 7.2 State machine
| From | To | Trigger | Writes |
|---|---|---|---|
| (none) | open | `current()` for today; catch-up for a never-opened date with tasks (`auto_created=true`) | `opened_at=now` |
| open | closing | `close(USER)` (today) or catch-up (`AUTO_MIDNIGHT`, date < today) | `mark_unresolved_missed(d)` **in the same transaction**, `missed_marked_at`, `close_mode`, `closed_at`, `weekly_due |= d is Sunday`, `close_started_at=now` |
| closing | closing | pipeline attempt (resume) | `close_attempts += 1`, `close_started_at=now`, checkpoints |
| closing | closed | pipeline finished, or `close_attempts ≥ DAY_CLOSE_MAX_ATTEMPTS` | `state=closed`, `last_error` kept |
| closed | closed | weekly catch-up step only (§7.5) | `weekly_report_id` |
No transition leaves `closed`. A session with `local_date > today` (only possible after a timezone change westwards) is left untouched.

### 7.3 `current()` algorithm
Runs in the request transaction:
1. `SELECT pg_advisory_xact_lock(DAY_CYCLE_LOCK_KEY)` — serializes all catch-up/close transitions (single user ⇒ negligible contention; Supavisor **session** mode keeps the lock on one backend).
2. `lo = today − DAY_CATCHUP_MAX_DAYS`. Load sessions with `local_date ∈ [lo, today]` plus any session with `state <> 'closed'` and `local_date < lo` (stale beyond the window is still closed).
3. **Never-opened dates with tasks**: `tasks.tasks_in_range(lo, today − 1)`; for each date with ≥ 1 task and no session → insert session (`auto_created=true`, `state=open`). No template materialization for these dates (only dates actually opened get recurring occurrences).
4. **Stale sessions**: for each session with `local_date < today` and `state = open`, ascending: transition open → closing with `AUTO_MIDNIGHT`, `closed_at = local_end(d)`.
5. **Stragglers**: for closed/closing sessions with `local_date < today` that still have `planned` tasks (from step 3's list — e.g. a task added after the user closed that day), call `mark_unresolved_missed(d)` (reports are not regenerated).
6. **Weekly catch-up**: for every week W with Sunday ∈ [lo, today − 1] that has ≥ 1 session, where no session in W has `weekly_due` or `weekly_report_id`: set `weekly_due=true` on W's latest session (covers weeks whose Sunday was never opened or was closed before this rule ran).
7. **Today**: `INSERT INTO day_session (local_date, state, opened_at) VALUES (today,'open',now) ON CONFLICT (local_date) DO NOTHING`, then `SELECT … FOR UPDATE`. If `state = open` → `tasks.materialize_templates(today)` (idempotent and cheap, so it runs on every `current()`; template changes made during the day therefore apply to today if not yet materialized).
8. Commit (core commits at request end; `DayService` flushes and the API layer returns after commit).
9. **Pending work** = sessions where `state = closing AND (close_started_at IS NULL OR close_started_at < now − DAY_CLOSE_STALE_AFTER_S OR newly transitioned in this call)` **or** `state = closed AND weekly_due AND weekly_report_id IS NULL`, excluding dates in the in-process running set → `scheduler.schedule(sorted dates)`.
10. Return `DayDTO(today)` with `summary` from `tasks.day_plan(today)`.

### 7.4 `close(mode)`
1. Run `current()` steps 1–8 (same transaction, lock held).
2. `s = today's session FOR UPDATE`.
3. `closed` → return `already_closed=true`, HTTP 200. `closing` → return current state, HTTP 202 (re-schedule if stale per §7.3 step 9).
4. `open` → `missed = tasks.mark_unresolved_missed(today)`; set `state=closing`, `close_mode=mode`, `closed_at = now` (USER) or `local_end(today)` (AUTO_MIDNIGHT), `missed_marked_at=now`, `weekly_due = today.weekday() == 6`, `close_started_at=now`. Commit, then `scheduler.schedule([today])`, return 202 with `missed_count=missed`.
The API always passes `CloseMode.USER`. Closing with unresolved tasks is allowed (the EOD sheet's "leave" option ⇒ `missed`).

### 7.5 Close pipeline (`ClosePipeline.run(d)`, background)
`run_pipelines(dates)` processes dates **sequentially in ascending order** (one chart render at a time — 512 MB RAM). For each `d`:
1. If `d` is in the in-process running set → skip; else add (removed in `finally`).
2. New `AsyncSession` from `core.session_factory`; `SELECT pg_try_advisory_lock(DAY_PIPELINE_LOCK_CLASS, d.toordinal())` (session-level, released in `finally`); not acquired → skip (another worker owns it).
3. Load session; if not pending work (§7.3 step 9 predicate minus staleness) → return. If `state = closing`: `close_attempts += 1`, `close_started_at = now`; commit.
4. Step `missed`: if `missed_marked_at IS NULL` → `tasks.mark_unresolved_missed(d)`; set; commit.
5. Step `predictor`: if `predictor_done_at IS NULL` → `await predictor.on_day_closed(d)`; on exception log + `last_error`, continue (predictor problems never block reports); set `predictor_done_at`; commit.
6. Step `daily`: if `daily_report_id IS NULL` and `state = closing` → `daily_report_id = await reports.generate(ReportKind.DAILY, d)`; commit immediately.
7. Step `weekly`: if `weekly_due AND weekly_report_id IS NULL` → `weekly_report_id = await reports.generate(ReportKind.WEEKLY, d − timedelta(d.weekday()))`; commit.
8. `state = closed`; commit.
On an exception in steps 6–7: rollback, record `last_error` (class name), leave `state = closing`; it is resumed by the next request after `DAY_CLOSE_STALE_AFTER_S`. If `close_attempts ≥ DAY_CLOSE_MAX_ATTEMPTS` at step 3, skip remaining steps and set `state = closed` (reports can be regenerated via `POST /reports/generate`). Every step is idempotent via its checkpoint, so a process killed at any point (Render restart, OOM) resumes correctly. Residual risk: death between `reports.generate` returning and the commit of its id → one orphan report row; reports module should de-duplicate on `(kind, period_start)` (§13 Q2).

### 7.6 `ensure_current_day` dependency
Attached by `main.py` to the `tasks`, `feasibility` and `assistant` routers (and used internally by this module's routes). Fast path: a process-local memo `(today, checked_at)`; if `today` equals the memo date, no pipeline is running-but-stale, and `checked_at` is within `DAY_ENSURE_MEMO_S`, it returns immediately. Otherwise it calls `DayService.current()` (same request session) and refreshes the memo. Cost on the slow path: one advisory lock, ≤ 3 small queries.

### 7.7 `get(d)` and `unresolved()`
`get(d)`: session for `d` → `DayDTO` (404 if none; future dates usually have none). `unresolved()`: today's session `open` → `tasks.unresolved(today)`; otherwise `[]`.

### 7.8 Concurrency summary
- Transitions: transaction-scoped advisory lock `DAY_CYCLE_LOCK_KEY` + `ON CONFLICT` insert + `FOR UPDATE` row lock ⇒ two concurrent `close` calls (double tap, retry after cold start) produce exactly one open→closing transition; the second sees `closing`/`closed`.
- Pipelines: in-process running set + per-date session advisory lock + checkpoints ⇒ no double report even if two requests schedule the same date.
- Uvicorn runs one worker on Render free; the design stays correct with more.

## 8. Configuration
| Setting | Default | Meaning |
|---|---|---|
| `DAY_CATCHUP_MAX_DAYS` | 14 | look-back window for never-opened dates, stragglers, weekly catch-up |
| `DAY_CLOSE_STALE_AFTER_S` | 300 | a `closing` session older than this is resumed |
| `DAY_CLOSE_MAX_ATTEMPTS` | 3 | after this, force `closed` |
| `DAY_ENSURE_MEMO_S` | 60 | fast-path memo for `ensure_current_day` |
| `DAY_CYCLE_LOCK_KEY` | `0x5DA1C1C1` (bigint constant) | advisory xact lock |
| `DAY_PIPELINE_LOCK_CLASS` | `0x5DA1` (int4) | advisory lock class for per-date pipeline |

## 9. Errors & degradation
- Reports or Groq down → reports module returns a report id (status `failed`/degraded) — the day still closes (P10).
- Predictor retrain failure → logged, day closes, v1 keeps serving.
- DB error during `current()` → 503 via core; nothing partially applied (single transaction).
- Unknown/invalid tz in settings → core raises at `tz()`; 500 (configuration bug).
- `NotFoundError` (404) only from `get`.

## 10. Security & privacy
No personal text stored. `last_error` holds exception class names only (never messages that may contain titles). Background jobs run with no request context and must not log task content. All endpoints require JWT.

## 11. Testing plan
Fixtures: `db_session` (Postgres container), `fake_clock` (settable; tests jump across midnight), `tz_berlin`, `fake_tasks` (unit) / real `TaskService` (integration), `fake_predictor` (records `on_day_closed` dates; can raise), `fake_reports` (returns UUIDs, records `(kind, period_start)`; can raise), `recording_scheduler` (captures scheduled dates; test then awaits `run_pipelines` explicitly), `api_client`. freezegun only for code paths outside `Clock` (none expected).

Unit: `test_week_monday_of`, `test_local_end_dst`, `test_pending_work_predicate`, `test_weekly_catchup_selects_latest_session`.

Integration: `test_current_opens_today_and_materializes`, `test_current_is_idempotent`, `test_current_autocloses_yesterday_after_midnight`, `test_autoclose_closed_at_is_local_2359`, `test_autoclose_several_missed_days`, `test_never_opened_date_with_tasks_gets_auto_session`, `test_never_opened_empty_date_gets_no_session`, `test_straggler_task_after_close_marked_missed`, `test_close_marks_planned_missed_and_returns_202`, `test_close_twice_returns_already_closed`, `test_concurrent_close_single_transition` (two `asyncio.gather` calls, two sessions), `test_pipeline_order_predictor_then_daily_then_weekly`, `test_pipeline_weekly_only_on_sunday`, `test_pipeline_resume_after_crash_skips_done_steps`, `test_stale_closing_rescheduled_after_timeout`, `test_pipeline_max_attempts_forces_closed`, `test_predictor_failure_does_not_block_reports`, `test_weekly_catchup_for_skipped_sunday`, `test_unresolved_empty_when_closed`, `test_get_unknown_date_404`, `test_ensure_dependency_triggers_autoclose_on_tasks_route`, `test_tz_change_west_leaves_future_session`.

## 12. Acceptance criteria
| ID | Given / When / Then | Test |
|---|---|---|
| DAY-AC-01 | Given no session today, When `GET /days/current`, Then an `open` session exists and today's matching templates are materialized | `test_current_opens_today_and_materializes` |
| DAY-AC-02 | Given an open day 2026-11-09 and the clock at 2026-11-10 00:05 local, When any day-scoped request arrives, Then 11-09 becomes `closing`→`closed` with `close_mode=auto_midnight`, `closed_at` = 11-09 23:59:59 local, its planned tasks `missed`, and 11-10 is opened | `test_current_autocloses_yesterday_after_midnight`, `test_autoclose_closed_at_is_local_2359`, `test_ensure_dependency_triggers_autoclose_on_tasks_route` |
| DAY-AC-03 | Given the app unused for 3 days, Then every stale open session and every never-opened date with tasks is closed in date order and gets a daily report | `test_autoclose_several_missed_days`, `test_never_opened_date_with_tasks_gets_auto_session` |
| DAY-AC-04 | When the user closes today with 2 planned tasks, Then 202, `missed_count=2`, pipeline runs predictor → daily report | `test_close_marks_planned_missed_and_returns_202`, `test_pipeline_order_predictor_then_daily_then_weekly` |
| DAY-AC-05 | Given today is Sunday, When closed, Then a weekly report for Mon–Sun is generated (period_start = Monday) | `test_pipeline_weekly_only_on_sunday` |
| DAY-AC-06 | Given two simultaneous close requests, Then exactly one transition and one daily report | `test_concurrent_close_single_transition` |
| DAY-AC-07 | Given the process died after the predictor step, When the next request arrives after 5 min, Then the pipeline resumes at the report step without re-running completed steps | `test_pipeline_resume_after_crash_skips_done_steps`, `test_stale_closing_rescheduled_after_timeout` |
| DAY-AC-08 | Given reports keeps failing, Then after 3 attempts the day is `closed` with `last_error` set | `test_pipeline_max_attempts_forces_closed` |
| DAY-AC-09 | Given a closed day, When close is called again, Then 200 `already_closed=true` and nothing changes | `test_close_twice_returns_already_closed` |
| DAY-AC-10 | Given a week whose Sunday was never opened, When the next week's first request arrives, Then a weekly report for that week is produced once | `test_weekly_catchup_for_skipped_sunday` |
| DAY-AC-11 | Predictor failure at close does not prevent the daily report | `test_predictor_failure_does_not_block_reports` |

## 13. Open questions
1. **Close response vs background generation.** Plan §7 says `POST /days/current/close → {daily_report_id, weekly_report_id?}`, but §8.3 runs `reports.generate` in a background task and `ReportService.generate` returns the id only after creating+rendering. Ids are therefore `null` in the 202 response and the app polls `GET /days/{date}`. Proposal: add `ReportService.create_pending(kind, period_start) -> UUID` + `render(id)` so close can return ids immediately.
2. `reports` should make `generate` idempotent per `(kind, period_start)` (return the existing id) to avoid orphan duplicates on pipeline resume.
3. `app_settings.week_start` (default `1` = Monday) uses 1-based numbering while weekdays elsewhere are 0=Mon; weeks are fixed Mon–Sun here and `week_start` is ignored. Decide whether to drop the column or define its numbering.
4. Plan §8.3 handles "an open day with local_date < today" only; this spec also creates sessions for never-opened dates that hold tasks (postponed-to or future tasks) so they become `missed` and are reported, and adds a weekly catch-up. Confirm.
5. Should a Sunday auto-closed together with later days still produce its weekly report before the following days' daily reports? (Current order: strictly by date, so yes.)

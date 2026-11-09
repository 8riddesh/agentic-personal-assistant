# mobile/tasks — Spec

> Governed by `constitution.md` (P5, P7, P9, P10) and `plan.md` (§4.1 `TaskDraft`, §5.4, §7, §8.1, §8.3, §8.4).
> Owns the Today checklist, the add/edit task flow with the feasibility verdict card, status actions, recurring
> templates management and the drift cache of the open day.

## 1. Purpose & scope

| Capability | Contribution |
|---|---|
| C2 | Enter tasks via form; always ask "Recurring or one-time?" |
| C3 | Show feasibility verdict card before saving; Add / Add anyway (override) / Adjust |
| C6 | Show predicted end on each task |
| C7 | Status actions: completed / postponed / cancelled / can't do (`missed` is server-only) |
| C8 | Hosts the "Done for the day" entry point (widget owned by reports) |

Out of scope: chat entry (chat reuses `AddTaskFlow`), notification scheduling (notifications listens to this
feature's state), EOD resolution and close (reports), calendar import (calendar_connect), weekly schedule (schedule),
undoing a terminal status (no endpoint — Q4).

## 2. Folder layout

```
features/tasks/
├── data/
│   ├── dto/                    # TaskDto, DayDto, TaskCreateDto, TaskPatchDto, StatusChangeDto,
│   │                           # CheckResponseDto, AssessRequestDto, AssessmentDto, TemplateDto, TemplatePatchDto
│   ├── tasks_api.dart          # /tasks, /tasks/{id}, /tasks/{id}/status, /tasks/{id}/check-response
│   ├── day_api.dart            # GET /days/current, GET /days/{date}
│   ├── feasibility_api.dart    # POST /feasibility/assess
│   ├── templates_api.dart      # GET/PATCH/DELETE /templates[/{id}]
│   ├── db/
│   │   ├── cached_tables.dart  # CachedDays, CachedTasks (registered in AppDatabase)
│   │   └── day_cache_dao.dart  # replaceDay(day, tasks), readDay(date), upsertTask(task)
│   └── tasks_repository.dart   # API + cache; maps DTO ↔ entity; outbox fallback for status
├── domain/
│   ├── entities.dart           # Task, Day, TaskStatus, Recurrence, TaskDraft, Assessment, Template, enums
│   ├── task_draft_validator.dart   # pure validation → Map<Field, String>
│   ├── start_at_resolver.dart  # (LocalDate, TimeOfDay?, tz.Location) → DateTime? UTC
│   ├── today_sorter.dart       # ordering + sections
│   ├── override_rule.dart      # isOverride(verdict) → bool
│   └── status_change.dart      # sealed StatusChange + validation
└── presentation/
    ├── today_screen.dart
    ├── task_tile.dart
    ├── add_task/
    │   ├── add_task_screen.dart       # form
    │   ├── recurrence_question.dart   # "Recurring or one-time?"
    │   ├── verdict_card.dart
    │   └── add_task_controller.dart
    ├── edit_task_screen.dart
    ├── status_sheet.dart
    ├── templates_screen.dart
    ├── template_edit_sheet.dart
    └── providers.dart
```

## 3. Dependencies

Features (public API only):
| Feature | Used |
|---|---|
| app_shell | `apiClientProvider`, `appDatabaseProvider`, `outboxServiceProvider`, `clockProvider`, `appLocationProvider`, `settingsControllerProvider`, `LocalDate`, `AppError`, `AsyncValueView`, `LifecycleHook` |
| notifications | `followUpServiceProvider` (ETA follow-up from the status sheet) |
| calendar_connect | `CalendarConsentCard` widget (Today header) |
| reports | `DoneForTheDayButton` widget, route `/reports/:id` |

Notifications depends on this feature's `currentDayControllerProvider` (not the reverse) for reconcile.

Packages: flutter_riverpod, go_router, dio (via ApiClient), freezed, json_serializable, drift, timezone, intl.

## 4. Local data (drift, registered in `AppDatabase`)

`cached_days`: `local_date text PK`, `json text` (DayDto), `fetched_at datetime`.
`cached_tasks`: `id text PK`, `local_date text` (indexed), `json text` (TaskDto), `fetched_at datetime`,
`pending_status text nullable` (optimistic status awaiting outbox sync).

Only the open day (and at most the previous day) is cached; `replaceDay` deletes rows of other dates older than
yesterday. Cache is cleared on logout. Titles are personal text stored in app-private storage (see Q6).

## 5. Public interface

```dart
enum TaskStatus { planned, completed, postponed, cancelled, cantDo, missed }   // json: cant_do
enum CheckResponse { done, notYet }                                            // json: not_yet
enum CreatedVia { form, chat, template }
enum Verdict { go, caution, noGo }                                              // json: no_go
enum RecommendedAction { proceed, reschedule, split, shorten, drop }
enum DayState { open, closing, closed }

sealed class Recurrence { }  // Daily() | Weekly(Set<int> byWeekday /*0=Mon..6=Sun*/)

@freezed class Task { String id; LocalDate localDate; String? templateId; String title; String? notes;
  String category; DateTime? startAt; int? estimateMin; DateTime? predictedEndAt; String? predictionMethod;
  DateTime? actualEndAt; TaskStatus status; String? statusReason; String? postponedToTaskId;
  String? feasibilityId; bool feasibilityOverridden; CreatedVia createdVia; CheckResponse? checkResponse;
  bool get isTerminal => status != TaskStatus.planned; bool get isTimed => startAt != null; }

@freezed class Day { String id; LocalDate localDate; DayState state; DateTime openedAt; DateTime? closedAt;
  String? closeMode; String? dailyReportId; String? weeklyReportId; }

@freezed class TaskDraft { String title; String? notes; String category; LocalDate localDate;
  DateTime? startAt; int? estimateMin; bool? isRecurring; Recurrence? recurrence; }   // isRecurring null = not yet answered

@freezed class Assessment { String assessmentId; Verdict verdict; double score; double feasibleNoul;
  RecommendedAction recommendedAction; String suggestion; DateTime? predictedEndAt; String? engine; bool degraded; }

sealed class StatusChange { }
//   Completed({DateTime? finishedAt}) | Postponed(DateTime newStartAt) | Cancelled({String? reason}) | CantDo(String reason)

@freezed class TodayState { Day day; List<Task> tasks; DateTime fetchedAt; bool fromCache; }

// Providers
final currentDayControllerProvider = AsyncNotifierProvider<CurrentDayController, TodayState>(...);
//   Future<void> refresh();                 // GET /days/current → GET /tasks?date=
//   void applyTask(Task t);                 // replace/insert in state + cache
//   Future<void> markDayClosed(Day d);      // used by reports after close
final tasksRepositoryProvider = Provider<TasksRepository>(...);
//   Future<Day> currentDay(); Future<Day> day(LocalDate d); Future<List<Task>> tasksFor(LocalDate d);
//   Future<Assessment> assess(TaskDraft d); Future<Task> create(TaskDraft d, {String? assessmentId,
//     required bool overridden, required CreatedVia via}); Future<Task> patch(String id, TaskPatch p);
//   Future<Task> setStatus(String id, StatusChange c, {StatusSource source = StatusSource.app});
//   Future<void> checkResponse(String id, {required CheckResponse r, DateTime? finishedAt, int? etaMin});
final templatesControllerProvider = AsyncNotifierProvider<TemplatesController, List<Template>>(...);
final categoriesProvider = Provider<List<String>>((_) => const ['Work','Learning','Health','Personal','Chores']);

// Flows reusable by chat / reports
abstract final class AddTaskFlow {
  static Future<Task?> start(BuildContext c, {TaskDraft? prefill, CreatedVia via = CreatedVia.form});
}   // pushes /today/new with prefill; resolves with created Task or null
abstract final class StatusSheet {
  static Future<Task?> show(BuildContext c, Task t, {StatusKind? preselect, StatusChange? prefill});
}
final class CurrentDayLifecycleHook implements LifecycleHook { int order = 30; }   // refresh()
```

## 6. Backend endpoints used

| Method & path | Request | Response |
|---|---|---|
| `GET /days/current` | — | Day `{id, local_date, state, opened_at, closed_at?, close_mode?, daily_report_id?, weekly_report_id?}` |
| `GET /days/{date}` | — | Day (used once after a date change to find the auto-closed day's report) |
| `GET /tasks?date=YYYY-MM-DD` | — | `[Task]` (fields per plan §5.4, snake_case) |
| `POST /feasibility/assess` | `{title, notes?, category, local_date, start_at?, estimate_min?, is_recurring, recurrence?}` | `{assessment_id, verdict, score, feasible_noul, recommended_action, suggestion, predicted_end_at, engine, degraded}` |
| `POST /tasks` | `{local_date, title, notes?, category, start_at?, estimate_min?, is_recurring, recurrence?, assessment_id?, overridden, created_via}` | Task (instance for `local_date`; Q2 for recurring) |
| `PATCH /tasks/{id}` | subset `{title, notes, category, start_at, estimate_min}` | Task |
| `POST /tasks/{id}/status` | `{status:"completed", finished_at?}` \| `{status:"postponed", new_start_at}` \| `{status:"cancelled", reason?}` \| `{status:"cant_do", reason}` + `source:"app"` | Task (Q3 for the new postponed task) |
| `POST /tasks/{id}/check-response` | `{response:"done", finished_at}` \| `{response:"not_yet", eta_min?}` | Task (repository method used by notifications/in-app ETA) |
| `GET /templates` | — | `[{id, title, notes?, category, start_local?, recurrence, default_estimate_min?, active}]` |
| `PATCH /templates/{id}` | subset of the above (no id) | Template |
| `DELETE /templates/{id}` | — | 204 |

`recurrence` JSON: `{"freq":"daily"}` or `{"freq":"weekly","byweekday":[0,2,4]}`. All instants ISO-8601 UTC (`Z`).

## 7. Screens & UX flow

### 7.1 TodayScreen (`/today`)
Header: "Today · Sun 8 Nov" (open day's `local_date`, app tz), progress "3 of 7 done", `CalendarConsentCard`
(calendar_connect), templates icon → `/today/templates`. FAB "Add task" → `/today/new`. Bottom: `DoneForTheDayButton`
(reports) when `day.state == open`.

| State | UI |
|---|---|
| loading / waking | `AsyncValueView` (waking text after 3 s) |
| cached + refreshing | cached list + top progress bar |
| offline with cache | cached list + "Offline · last updated 14:05"; FAB disabled (creation needs feasibility) |
| error, no cache | ErrorView + Retry |
| empty (open day, 0 tasks) | "Nothing planned yet" + "Add task" button |
| content | sections below |
| day closed (`state ∈ {closing, closed}`) | banner "Day closed at 21:40 · View report" → `/reports/{daily_report_id}`; list read-only; FAB and Done-for-the-day hidden (Q5) |

Sections: **Planned** — timed tasks by `start_at` asc, then anytime tasks by title; **Finished** (collapsible,
collapsed by default) — terminal tasks by `start_at`/title. Pull-to-refresh → `refresh()` (bypasses throttle).
On date change (refreshed `local_date` ≠ previous cached date): if `GET /days/{previous}` returns
`close_mode == auto_midnight` and `daily_report_id` → snackbar "Yesterday closed automatically · View report".

### 7.2 TaskTile
```
[14:00]  Write project report                 [Planned]
         Work · ends ~15:10                    (Not yet)
```
- Leading: start time `HH:mm` or "Anytime".
- Title (1 line, ellipsis), subtitle: category · "ends ~HH:mm" (`predicted_end_at`, if present) · "postponed to
  Tue 10:00" / reason for cant_do.
- Trailing status chip (colours from app_shell). Extra small chip "Not yet" when `check_response == not_yet`;
  sync icon when `pending_status != null`.
- Tap: planned → `StatusSheet`; terminal → read-only details sheet. Long press / overflow menu: Edit (planned only).

### 7.3 AddTaskScreen (`/today/new`, extra: `TaskDraft? prefill`, `CreatedVia via`)
Fields:
| Field | Control | Rules |
|---|---|---|
| Title | text | required, trimmed 1–200 chars |
| Category | autocomplete field: suggestions = `categoriesProvider` (Work, Learning, Health, Personal, Chores) + categories already used (from today's tasks and templates); **free typing allowed** to create my own | required; default `Personal`; 1–32 chars; server normalizes case for known names |
| Date | date picker | default open day; range open day … +60 days |
| Start time | time picker + "Anytime" switch | optional; anytime ⇒ no reminders/check (hint text) |
| Estimate | number (minutes) + chips 15/30/60/90 | optional; 5–720 |
| Notes | multiline | optional; ≤ 1000 chars |
| **Recurring or one-time?** | `SegmentedButton` [One-time] [Recurring], **no default selection** (prefill may preselect) | required |
| Repeat | (if Recurring) [Every day] [Chosen weekdays] + Mon…Sun chips | weekly ⇒ ≥ 1 weekday |

Primary button "Check & add". Flow:
```
validate → (errors? show inline, stop)
→ state: assessing ("Checking your day…"; waking text after 3 s)
→ POST /feasibility/assess
→ state: verdict → VerdictCard (bottom sheet, not dismissible by swipe while saving)
     go          : [Add]        [Adjust]
     caution     : [Add anyway] [Adjust]
     no_go       : [Add anyway] [Adjust]
   Add / Add anyway → state: saving → POST /tasks {assessment_id, overridden: isOverride(verdict)}
                    → applyTask(task) → pop(task) → snackbar "Added"
   Adjust → close card, keep all field values, focus the field implied by recommended_action
            (reschedule → Start time; split/shorten → Estimate; drop → Title)
   Adjust schedule for this day (shown when any conflict has adjustable == true, i.e. a hard/soft block)
            → schedule.BlockOverrideSheet.show(context, date, conflict) — skip the block that day, or change its
              times that day, or open the weekly editor
            → on save: re-run POST /feasibility/assess with the same draft → new VerdictCard
→ assess failure (ServerWakingTimeout / 5xx / degraded unavailability):
     card "Feasibility check unavailable" : [Add without check] [Retry] [Adjust]
     Add without check → POST /tasks {assessment_id: null, overridden: false}
```

### 7.4 VerdictCard
| Element | Source |
|---|---|
| Badge "Go" / "Caution" / "No-go" (green/amber/red) | `verdict` |
| "Feasibility 72%" + linear bar | `score` |
| "Fits before your next commitment: Yes (84%)" / "No (31%)" | `feasible_noul` ≥ 0.5 → Yes |
| "Recommended: Go ahead / Reschedule / Split into parts / Shorten it / Drop it" | `recommended_action` |
| Suggestion (1–2 sentences) | `suggestion` |
| "Predicted to end ~15:10" (omitted for anytime) | `predicted_end_at` |
| "Basic check only — AI unavailable" | `degraded == true` |
| Conflicts list: "Overlaps Lunch (soft) 12:30–13:15 · 30 min" — soft blocks shown as a **warning** (amber), hard blocks/calendar/tasks as conflicts (red); block rows have an "Adjust for this day" link | `conflicts[]` |
| Recurrence summary "Repeats Mon, Wed, Fri" / "One-time" | draft |

### 7.5 EditTaskScreen (`/today/task/:id/edit`)
Same fields minus Date and the recurring question (instance only; template edits via Templates). Planned tasks only.
Save → `PATCH /tasks/{id}` with changed fields only → `applyTask`. No re-assessment in v1 (Q1).

### 7.6 StatusSheet (planned tasks only)
Four options (radio list), then option-specific inputs and "Confirm":
| Option | Inputs | Validation | Request |
|---|---|---|---|
| Completed | "Finished at": [Now] [At predicted end] [Pick…] | `start_at` ≤ t ≤ now (if timed); t ≤ now | `completed{finished_at}` |
| Postponed | date picker (open day … +60) + time picker | `new_start_at > now`; must not equal current `start_at` | `postponed{new_start_at}` |
| Cancelled | reason (optional, ≤ 500) | — | `cancelled{reason?}` |
| Can't do | reason (**required**, 1–500) | non-blank | `cant_do{reason}` |
When `check_response == not_yet` an extra row is shown above: "Ask me again in [+15] [+30] [+60] min" →
`followUpServiceProvider.request(task, etaMin)` (notifications) — explicitly user-requested.
`missed` is never offered.

### 7.7 TemplatesScreen (`/today/templates`)
List from `GET /templates`: title, recurrence summary, start time, estimate, `active` switch (PATCH `{active}` with
optimistic toggle + rollback on error). Tap → `TemplateEditSheet` (title, category, start time/anytime, estimate,
notes, recurrence daily/weekdays) → PATCH changed fields. Delete (trailing menu) → confirm "Delete template? Today's
already-created task stays." → DELETE. States: loading/waking, empty ("No recurring tasks — add one with
'Recurring' on a new task"), error, content. Templates are not created here (only via POST /tasks).

## 8. Behaviour & rules

1. **Recurring question is mandatory**: "Check & add" stays disabled until One-time or Recurring is chosen; chat
   prefill may preselect but the control is always visible on the form before assessment.
2. **start_at resolution**: `TZDateTime(appLocation, d.year, d.month, d.day, h, m).toUtc()`; nonexistent DST local
   times are shifted forward by the tz package and the resolved time is displayed. start_at always lies within
   `[d.startOf, d.endExclusive)`.
3. **Assessment validity**: an `Assessment` is bound to a draft hash (all fields incl. recurrence). Any field
   change after assessment discards it; saving requires re-assessment (or "Add without check" after failure).
4. **Override rule**: `isOverride(verdict) = verdict != Verdict.go` when the user chooses Add anyway (Q7).
5. **created_via**: `form` from TodayScreen, `chat` when started by chat's proposal.
6. **After every successful mutation** (create, patch, status, check-response, template change affecting today):
   `applyTask(returnedTask)` → state emits → notifications' listener reconciles; then a background `refresh()` to
   pick up server-side side effects (e.g. postponed creates a new task; template patch). Template mutations only
   trigger `refresh()`.
7. **Postponed**: if the new date equals the open day, the new task appears in Planned after refresh; otherwise only
   the original shows "postponed to …".
8. **Optimistic offline status**: `setStatus` with `Completed/Cancelled/CantDo` on `NetworkError` or
   `ServerWakingTimeout` → enqueue in outbox (`label: "Mark '<title>' completed"`), set `pending_status` in cache,
   reflect in UI with sync icon. Postponed requires the server (needs the new task) → error "You're offline".
9. **Refresh algorithm**: `GET /days/current` → `GET /tasks?date=day.local_date` → `replaceDay` in one drift
   transaction → state `fromCache=false`. On launch, cache is emitted first (`fromCache=true`) if present for the
   device's current local date or the last open date.
10. **Day closed**: when `day.state != open` the controller exposes no mutations (UI hides them); notifications
    derives an empty desired set.
11. **Edit constraints**: PATCH `start_at` must stay within the task's `local_date`; to move days use Postponed.

## 9. Platform configuration
None beyond app_shell.

## 10. Errors & offline behaviour
| Case | Behaviour |
|---|---|
| Assess slow (cold start + AI) | "Checking your day…" → waking text; 120 s budget |
| Assess fails | "Feasibility check unavailable" card (P7/P10) |
| POST /tasks 422 | map `fieldErrors` onto form fields; generic snackbar otherwise |
| POST /tasks network error | keep form + card; "Couldn't save — Retry" (no outbox: creation must be confirmed online) |
| Status 409 (already terminal) | refresh; snackbar "This task was already updated" |
| Status 404 | refresh; snackbar "Task no longer exists" |
| Offline Today | cached list read-only except outbox-capable status changes |

## 11. Testing plan
Unit (mocktail, fake `Clock`, `tz` initialised with Europe/Bucharest and UTC):
- `task_draft_validator_test`: title blank/201 chars; estimate 4/5/720/721; recurring unanswered; weekly with 0 days;
  date before open day / > +60; notes 1001.
- `start_at_resolver_test`: normal; DST spring-forward 03:30 → 04:30; DST fall-back 03:30 picks first occurrence;
  anytime → null.
- `today_sorter_test`: timed asc, anytime after, terminal in Finished.
- `override_rule_test`: go false; caution/no_go true.
- `status_change_test`: completed finished_at < start_at rejected; postponed in past rejected; cant_do blank rejected.
- `dto_mapping_test`: JSON ↔ entity for every enum value (`cant_do`, `no_go`, `not_yet`); recurrence variants;
  round-trip against fixtures copied from `backend/openapi.json` examples.
- `tasks_repository_test`: offline completed → outbox enqueued + pending_status; postponed offline → throws.
- `current_day_controller_test`: cache-first emission then server; date change triggers `GET /days/{prev}`;
  `applyTask` replaces by id.
- `day_cache_dao_test` (in-memory drift): replaceDay atomic, prune older than yesterday.
Widget:
- `today_screen_test`: loading, waking, empty, error, content, offline banner, closed-day banner.
- `task_tile_test`: anytime label, predicted end, not-yet chip, pending sync icon.
- `add_task_screen_test`: button disabled until recurrence answered; weekly chips; validation messages; assess →
  card → Add sends `overridden:false` + assessment_id; caution → "Add anyway" sends `overridden:true`; Adjust keeps
  values and invalidates assessment; failure → "Add without check" sends `assessment_id:null`.
- `verdict_card_test`: each verdict, degraded note, anytime without predicted end.
- `status_sheet_test`: four options only (no missed); can't-do requires reason; postponed picker; ETA row only when
  `not_yet`.
- `templates_screen_test`: toggle active optimistic + rollback; delete confirm.
Golden: `task_tile` (each status), `verdict_card` (go/caution/no_go).
Integration (`integration_test`, mocked ApiClient): add one-time task end-to-end → visible on Today; add recurring
weekly task → POST body contains recurrence.

## 12. Acceptance criteria
- **M-TASKS-AC-01** Given the app is open, When Today loads, Then `GET /days/current` then `GET /tasks?date=<day>` are
  called and tasks are listed with time, title, category, predicted end and status chip.
- **M-TASKS-AC-02** Given the add-task form, When the recurring question is unanswered, Then "Check & add" is disabled.
- **M-TASKS-AC-03** Given Recurring → Chosen weekdays with Mon/Wed/Fri, When saved, Then the request contains
  `is_recurring:true, recurrence:{freq:"weekly", byweekday:[0,2,4]}`.
- **M-TASKS-AC-04** Given a valid draft, When I tap "Check & add", Then `POST /feasibility/assess` is called and the
  verdict card shows verdict, score, yes/no, recommended action, suggestion and predicted end before anything is
  saved.
- **M-TASKS-AC-05** Given verdict `go`, When I tap Add, Then `POST /tasks` contains the `assessment_id` and
  `overridden:false`.
- **M-TASKS-AC-06** Given verdict `no_go` or `caution`, When I tap Add anyway, Then `POST /tasks` contains
  `overridden:true` (never blocked).
- **M-TASKS-AC-07** Given the verdict card, When I tap Adjust, Then the form keeps my values and a new assessment is
  required before saving.
- **M-TASKS-AC-08** Given the assess call fails, When I choose "Add without check", Then the task is created with
  `assessment_id:null`.
- **M-TASKS-AC-09** Given a planned task, When I choose Can't do without a reason, Then Confirm is disabled; with a
  reason, `POST /tasks/{id}/status {status:"cant_do", reason}` is sent.
- **M-TASKS-AC-10** Given a planned task, When I postpone to a future date/time, Then `postponed{new_start_at}` is
  sent and the tile shows "postponed to …".
- **M-TASKS-AC-11** The status sheet never offers `missed`.
- **M-TASKS-AC-12** Given any task mutation succeeds, Then `currentDayControllerProvider` emits the updated task (which
  triggers notification reconcile).
- **M-TASKS-AC-13** Given I'm offline, When I mark a task Completed, Then the change is queued in the outbox, shown with
  a sync icon, and sent on reconnect.
- **M-TASKS-AC-14** Given templates exist, When I toggle one inactive, Then `PATCH /templates/{id} {active:false}` is
  sent; on error the toggle reverts.
- **M-TASKS-AC-15** Given the open day is closed, Then the Today list is read-only and shows "View report".

## 13. Open questions
| # | Question | Proposed default |
|---|---|---|
| Q1 | Should editing `start_at`/`estimate_min` re-run feasibility and re-predict? | server re-predicts on PATCH; no re-assessment in v1 |
| Q2 | `POST /tasks` for a recurring task: does it create today's instance if the date doesn't match the recurrence? What does it return? | server creates template + instance only if the rule matches `local_date`; returns the instance or `{template}`; app refreshes |
| Q3 | Response of `postponed` — original task only, or `{task, new_task}`? | app refreshes regardless |
| Q4 | No undo for terminal statuses | out of scope v1 |
| Q5 | Adding tasks after the user closed today (state closed, before midnight) | hidden; allow adding for tomorrow later |
| Q6 | Local drift cache stores plaintext titles (P11 covers the server DB only) | accept (app-private storage); SQLCipher deferred |
| Q7 | Is "Add" on a `caution` verdict an override? | yes — any non-`go` add is recorded as override |
| Q8 | `TaskDraft` in plan §4.1 has no `local_date`; anytime tasks need one | send `local_date` in assess and create |
| Q9 | Postponing an anytime task requires `new_start_at` (a time) | require picking a time; or backend adds `new_local_date` |

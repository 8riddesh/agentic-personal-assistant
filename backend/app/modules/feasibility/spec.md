# Module Spec — `feasibility`

> Backend module · Governed by [`constitution.md`](../../../../constitution.md) and [`plan.md`](../../../../plan.md) §8.1, §9.2.
> Answers "can I realistically do this task at this time?" before a task is saved — deterministic checks first,
> Jev judgment second, Groq phrasing last. Advice only; never blocks (P7).

## 1. Purpose & scope

| Capability | Role |
|---|---|
| C3 | `POST /feasibility/assess` → verdict, score, yes/no (noul), recommended action, suggestion, predicted end |
| C9 | `outcomes()` feeds the "verdict vs outcome" report chart |

Out of scope: saving the task (tasks), scheduling notifications (mobile), predicting duration (predictor).

## 2. Folder layout

```
feasibility/
├── spec.md
├── __init__.py        # exports FeasibilityService, AssessmentDTO, AssessmentOutcomeDTO, Verdict, RecommendedAction
├── api.py             # POST /feasibility/assess, GET /feasibility/{id}
├── service.py         # FeasibilityService (orchestration)
├── deterministic.py   # pure functions: overlaps, free/committed minutes, load ratio, penalties
├── jev_questions.py   # build_state(), QUESTIONS (texts below)
├── combine.py         # pure: score formula, verdict thresholds, fallback scoring
├── prompts/suggestion.v1.j2
├── models.py          # feasibility_assessment ORM
├── repository.py
└── schemas.py
```

## 3. Dependencies

- Modules: `core`, `crypto` (EncryptedJSON/EncryptedText), `tasks` (`TaskDraft`, `TaskService.day_plan`,
  `TaskService.history`, `TaskService.tasks_in_range`), `schedule` (`ScheduleService.busy_intervals`, `day_window`),
  `predictor` (`PredictorService.predict`, `PredictionInput`), `ai_gateway` (`AIGateway`, question/answer models).
- Packages: `pydantic`, `jinja2` (via ai_gateway).

## 4. Data owned — `feasibility_assessment`

| Column | Type | Notes |
|---|---|---|
| id | uuid PK | |
| local_date | date | day assessed (index) |
| draft 🔒 | EncryptedJSON (`feasibility_assessment.draft`) | the TaskDraft as submitted |
| predicted_end_at | timestamptz null | from predictor |
| prediction_method | text null | |
| deterministic | jsonb | see §7.2 output (no personal text: uses indexes/kinds, not labels) |
| jev_answers | jsonb | raw typed answers (nouls/scores/choices) or `{}` |
| score | real | 0..1 |
| feasible_noul | real null | `achievable_in_window` value; null when deterministic_only |
| verdict | text | `go` \| `caution` \| `no_go` |
| recommended_action | text | `proceed` \| `reschedule` \| `split` \| `shorten` \| `drop` |
| suggestion 🔒 | EncryptedText (`feasibility_assessment.suggestion`) | 1–2 sentences |
| engine | text | `jev` \| `groq_fallback` \| `deterministic_only` |
| degraded | bool | |
| latency_ms | int | |
| created_at, updated_at | timestamptz | |

The FK `task.feasibility_id → feasibility_assessment.id` (ON DELETE SET NULL) is added by this module's M2 migration.
Assessments not linked to any task after 7 days are deleted opportunistically (on each assess, ≤ 50 rows).

## 5. Public interface

```python
class Verdict(StrEnum):
    GO = "go"
    CAUTION = "caution"
    NO_GO = "no_go"


class RecommendedAction(StrEnum):
    PROCEED = "proceed"
    RESCHEDULE = "reschedule"
    SPLIT = "split"
    SHORTEN = "shorten"
    DROP = "drop"


class ConflictDTO(BaseModel):
    kind: Literal["hard_block", "soft_block", "calendar", "task"]
    label: str  # decrypted, for display only (not stored)
    start_at: datetime
    end_at: datetime
    overlap_min: int
    ref_id: UUID  # block id / calendar event id / task id
    adjustable: bool  # true for hard_block/soft_block → app offers "Adjust schedule for this day"
    # (PUT /schedule/overrides/{date}/{block_id}), then re-assesses


class AssessmentDTO(BaseModel):
    id: UUID
    local_date: date
    verdict: Verdict
    score: float  # 0..1
    feasible: bool | None  # feasible_noul >= 0.5 ; None if deterministic_only
    feasible_noul: float | None
    recommended_action: RecommendedAction
    suggestion: str
    predicted_end_at: datetime | None
    predicted_duration_min: int
    prediction_method: str
    conflicts: list[ConflictDTO]
    free_minutes: int
    committed_minutes: int
    load_ratio: float
    engine: str
    degraded: bool
    created_at: datetime


class AssessmentOutcomeDTO(BaseModel):
    assessment_id: UUID
    task_id: UUID
    local_date: date
    verdict: Verdict
    score: float
    overridden: bool
    final_status: str  # task status at query time


class FeasibilityService:
    async def assess(self, draft: TaskDraft) -> AssessmentDTO: ...
    async def get(self, assessment_id: UUID) -> AssessmentDTO: ...
    async def outcomes(self, start: date, end: date) -> list[AssessmentOutcomeDTO]: ...
```
`outcomes()` joins via `TaskService.tasks_in_range(start, end)` (tasks with `feasibility_id` set) — no SQL join
across module tables.

## 6. HTTP endpoints

| Method & path | Body / params | Response | Errors |
|---|---|---|---|
| `POST /api/v1/feasibility/assess` | `TaskDraft` | 200 `AssessmentDTO` | 422 invalid draft; 409 day closed (`local_date` ≤ a closed day) |
| `GET /api/v1/feasibility/{id}` | — | 200 `AssessmentDTO` (conflicts recomputed: empty list) | 404 |

Example request / response:
```json
POST /api/v1/feasibility/assess
{"title":"Finish API module","category":"Work","start_at":"2026-11-09T09:30:00Z",
 "estimate_min":120,"is_recurring":false}

200
{"id":"5f…","local_date":"2026-11-09","verdict":"caution","score":0.58,"feasible":true,"feasible_noul":0.61,
 "recommended_action":"split","suggestion":"Your 3 PM stand-up cuts this short; do 3:00–5:00 PM? Or split it into two 60-min blocks around the meeting.",
 "predicted_end_at":"2026-11-09T12:10:00Z","predicted_duration_min":160,"prediction_method":"category_p60",
 "conflicts":[{"kind":"calendar","label":"Stand-up","start_at":"2026-11-09T10:30:00Z","end_at":"2026-11-09T11:00:00Z","overlap_min":30}],
 "free_minutes":310,"committed_minutes":420,"load_ratio":0.82,"engine":"jev","degraded":false,
 "created_at":"2026-11-09T04:01:12Z"}
```

## 7. Behaviour & rules

### 7.1 Inputs (gathered concurrently with `asyncio.gather`)
1. `local_date` = `draft.local_date` or local date of `draft.start_at` (app timezone).
2. `prediction = predictor.predict(PredictionInput(title, category, start_at, estimate_min, template_id=None))`.
   For anytime tasks (`start_at` null) the duration is still predicted; window checks are skipped.
3. `busy = schedule.busy_intervals(local_date)` (hard/soft blocks + consented calendar events, UTC, labelled).
4. `plan = tasks.day_plan(local_date)` filtered to `status == planned`.
5. `hist = tasks.history(category=draft.category, since=today − 60 days)` → stats:
   `n`, `on_time_rate` (share where actual_end ≤ predicted_end, or ≤ start+estimate when no prediction),
   `median_overrun_min`.

### 7.2 Deterministic layer (`deterministic.py`, pure)
- `window = [start_at, predicted_end_at]` (only when `start_at` set).
- **Overlaps**: for each busy interval and each planned task's `[start_at, predicted_end_at or start_at+estimate or +60m]`,
  `overlap_min = minutes(intersection)`; keep > 0. Kind = `hard_block` / `soft_block` / `calendar` / `task`.
- **day_window** = local 00:00–24:00 (from schedule). `free_minutes` = minutes of day window minus union(busy
  hard+calendar, planned tasks), counted from `max(now, day start)`.
- `committed_minutes` = sum of planned task durations (predicted or estimate or 60) + this task's predicted duration.
- `available_minutes` = day window minutes from `max(now, day start)` minus hard blocks minus calendar.
- `load_ratio = committed_minutes / max(available_minutes, 1)` (rounded 2 dp).
- **Penalties**: any `hard_block` or `calendar` overlap → −0.30 (once); each `task` overlap → −0.15, total task
  penalty capped at −0.30; `soft_block` overlaps → −0.05 each, cap −0.10.
- `start_in_past`: `start_at < now − 5 min` → flag (suggestion mentions it; no penalty).
- Stored `deterministic` JSON: `{overlaps:[{kind, overlap_min}], free_minutes, committed_minutes, available_minutes,
  load_ratio, penalty, start_in_past}` (no labels/titles).

### 7.3 Jev state & questions (`jev_questions.py`)
State (no notes, no emails — ai_gateway deny-list enforces):
```json
{"now_local":"2026-11-09 09:01","task":{"title":"Finish API module","category":"Work",
  "start_local":"09:30","user_estimate_min":120,"predicted_duration_min":160,"predicted_end_local":"12:10"},
 "already_planned":[{"title":"Gym","start_local":"18:00","duration_min":60}],
 "busy":[{"kind":"calendar","label":"Stand-up","start_local":"10:30","end_local":"11:00","hard":true}],
 "next_hard_commitment_local":"10:30",
 "free_minutes_left_today":310,"committed_minutes_incl_this":420,"load_ratio":0.82,
 "history_same_category":{"samples":14,"on_time_rate":0.57,"median_overrun_min":25}}
```
Questions (exact texts, version `v1`):

| id | type | instructions | criteria |
|---|---|---|---|
| `achievable_in_window` | noul | "Can this task realistically be finished between its start time and the next hard commitment (or end of day if none), given its predicted duration?" | true: "It fits fully before the next hard commitment / end of day." false: "It would be cut short or run into a commitment." |
| `day_overcommitted` | noul | "Including this task, is today's total planned work more than this person can realistically complete in the free time left?" | true: "The day is overcommitted." false: "The day's plan is realistic." |
| `workload_realism` | score | "How realistic is it to complete this task as planned today?" | `["clearly unrealistic", "unlikely", "possible but tight", "realistic", "comfortably realistic"]` |
| `history_supports` | noul | "Based on the history for this category, does this person usually finish such tasks within the predicted time?" | true: "History shows they usually finish on time." false: "History shows frequent overruns, or there is too little history to tell." |
| `recommended_action` | choice | "What is the single best action for this task plan?" | proceed: "Keep the plan as is." reschedule: "Move it to a freer time." split: "Break it into smaller blocks." shorten: "Reduce scope to fit the window." drop: "Remove it from today." |

For anytime tasks, `achievable_in_window` instructions use "before the end of the day".

### 7.4 Combination (`combine.py`, pure)
```
workload_norm = score / 4                               # 0..1
raw = 0.40*achievable + 0.25*(1 - overcommitted) + 0.20*workload_norm + 0.15*history_supports
score = clamp(raw + penalty, 0, 1)                      # penalty ≤ 0 from §7.2
verdict = go if score >= 0.70 else caution if score >= 0.45 else no_go
```
Weights/thresholds come from `FEASIBILITY_WEIGHTS` (JSON; defaults above). `recommended_action` = Jev choice;
overrides: if verdict `go` and choice is `drop` → `proceed`; if a hard/calendar overlap exists and choice is
`proceed` → `reschedule`.
**deterministic_only** (AI unavailable): `achievable = 1 if no hard/calendar/task overlap and predicted_end ≤
next hard commitment else 0`; `overcommitted = 1 if load_ratio > 1.0 else 0`; `workload_norm = clamp(1.2 −
load_ratio, 0, 1)`; `history_supports = on_time_rate if n ≥ 5 else 0.5`; `recommended_action` = `reschedule` if
overlap else `shorten` if load_ratio > 1 else `proceed`; `feasible_noul = null`.

### 7.5 Suggestion (`prompts/suggestion.v1.j2`, via `ai_gateway.generate`, `max_tokens=120`, `max_chars: 280`)
Context: verdict, score, recommended_action, task (title, start/end local), conflicts (labels + times), free slots
(top 3 from `schedule.free_slots`, local HH:MM), load_ratio, history stats.
Rules in prompt: ≤ 2 sentences; mention concrete local times; if `go`, a short encouragement + one tip; no
moralising; no invented facts. Fallback text when generation fails (deterministic templates), e.g.
- go: "Looks doable — predicted to finish by {end}."
- caution/no_go with overlap: "This overlaps {label} at {time}. Try {first_free_slot} instead."
- overload: "Today is already {pct}% booked; consider moving or shortening this."

### 7.6 Persist & return
Insert row (draft encrypted), commit, return `AssessmentDTO`. Total latency recorded. Target ≤ 4 s warm.

### 7.7 Linking & override (owned by tasks, recorded here for clarity)
`POST /tasks` passes `assessment_id` and `overridden`. Tasks stores them; `overridden=true` is valid only when the
verdict is `caution` or `no_go` (tasks validates via `FeasibilityService.get`). Report charts use `outcomes()`.

## 8. Configuration

`FEASIBILITY_WEIGHTS` (JSON: `{"achievable":0.40,"not_overcommitted":0.25,"workload":0.20,"history":0.15,
"go":0.70,"caution":0.45}`), `FEASIBILITY_HISTORY_DAYS` (60).

## 9. Errors & degradation

| Case | Behaviour |
|---|---|
| Predictor fails | duration = estimate or 60, `prediction_method="fallback_default"` |
| Schedule fails | treat busy = [] and set `degraded=true` |
| Jev fails | ai_gateway Groq emulation (`engine=groq_fallback`) |
| All AI fails | deterministic_only scoring + template suggestion; `degraded=true` |
| Draft invalid | 422 problem+json (from TaskDraft validation) |

The endpoint never returns 5xx because of AI failures.

## 10. Security & privacy

Draft and suggestion encrypted at rest. Jev state excludes notes. Conflict labels are returned to the app but not
stored in `deterministic`.

## 11. Testing plan

Unit (pure): `test_overlap_minutes_hard_soft_task`, `test_free_and_committed_minutes`, `test_load_ratio`,
`test_penalties_caps`, `test_combine_formula_and_thresholds`, `test_action_overrides`,
`test_deterministic_only_scoring`, `test_state_has_no_notes`, `test_anytime_task_skips_window_checks`.
Service (fakes for tasks/schedule/predictor/ai_gateway): `test_assess_happy_path_jev`,
`test_assess_ai_down_uses_deterministic`, `test_assess_predictor_failure_defaults`,
`test_suggestion_fallback_template_when_generate_empty`, `test_outcomes_join_final_status`.
Integration: `test_post_assess_persists_encrypted_draft` (raw row has no plaintext title),
`test_post_assess_closed_day_409`.

## 12. Acceptance criteria

| ID | Given / When / Then | Tests |
|---|---|---|
| FEAS-AC-01 | Given a task that overlaps a calendar meeting, When assessed, Then the conflict is listed, penalty applied and action ≠ proceed | `test_overlap_minutes_hard_soft_task`, `test_action_overrides` |
| FEAS-AC-02 | Given Jev answers, Then score = formula §7.4 and verdict per thresholds | `test_combine_formula_and_thresholds` |
| FEAS-AC-03 | Given all AI providers are down, When assessed, Then a verdict is still returned with `degraded=true` and `engine=deterministic_only` | `test_assess_ai_down_uses_deterministic` |
| FEAS-AC-04 | The response always contains `feasible` (yes/no) or null when deterministic_only, a score, a suggestion and predicted end | `test_assess_happy_path_jev` |
| FEAS-AC-05 | The stored draft and suggestion are ciphertext in the DB | `test_post_assess_persists_encrypted_draft` |
| FEAS-AC-06 | `outcomes()` returns verdict + final status + overridden for reports | `test_outcomes_join_final_status` |

## 13. Open questions

1. ~~Soft blocks~~ — resolved 2026-11-09: soft blocks are not busy time (not in `available_minutes`/free slots); an overlap gives a small penalty and a warning. Block conflicts (hard or soft) are `adjustable`: the app offers a per-date schedule override and re-runs the assessment.

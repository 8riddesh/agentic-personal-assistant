# Module spec — `backend/predictor`

> Governed by [`constitution.md`](../../../../constitution.md) and [`plan.md`](../../../../plan.md) (§4.1, §5.10, §10, ADR-011).
> Status: v1 (statistics) draft for M3. v2 (ML) section is an **agreed process with deferred algorithm** — not implemented in this version.

## 1. Purpose & scope

Predicts when a task will end so the app can fire **one** completion check at `predicted_end_at` (C6, P5), and measures how good those predictions are (feeds reports, C9).

| Capability | Served by |
|---|---|
| C6 predicted end per task | `PredictorService.predict`, `POST /predictor/predict`, `TaskPredictionAdapter` (tasks port) |
| C3 input (predicted duration) | `predict` called by `feasibility` |
| C9 accuracy metrics | `accuracy()` (read by `reports`), `GET /predictor/status` |
| P9 learn from data | v1 statistics over `tasks.history()`; v2 full retraining hook `on_day_closed` |

Out of scope: storing predictions on tasks (tasks does it), scheduling the check (mobile), v2 algorithm/features/quantile target (plan §18).

## 2. Folder layout

| File | Contents |
|---|---|
| `__init__.py` | exports `PredictorService`, `PredictionInput`, `Prediction`, `AccuracyDTO`, `Predictor`, `TaskPredictionAdapter`, `PredictionMethod` |
| `api.py` | router `/api/v1/predictor…` |
| `service.py` | `PredictorService` (selects implementation, clamps, fallback on error) |
| `statistics.py` | `StatisticsPredictor` (v1) + pure `percentile()` |
| `accuracy.py` | pure metric functions over `TaskDTO` lists |
| `adapter.py` | `TaskPredictionAdapter` implementing `tasks.EndTimePredictorPort` |
| `ml/` | *(v2, deferred)* `registry.py`, `trainer.py`, `ml_predictor.py`; `models.py`/`repository.py` for `predictor_model` |
| `schemas.py` | DTOs |

## 3. Dependencies

- Modules: `tasks` (`TaskService.history`, `tasks_in_range`, `TaskDTO`, `TaskOutcomeDTO`, `EndTimePredictorPort`, `PredictionRequest`, `PredictedEnd`) — read only; `core` (`Clock`, `AppSettingsService`, errors); `auth` (`current_user`, api only). v2 adds `crypto` (`EncryptedBytes` for the artifact) — plan §4 lists `predictor ──▶ tasks, core`; see §13 Q1.
- Third-party v1: none beyond stdlib (`math`, `statistics`) — pure Python keeps memory low. v2 (deferred): `scikit-learn`, `numpy`, `pandas`, `joblib` imported lazily inside training/inference functions only.

## 4. Data owned

v1 owns **no tables** (predictions live on `task.predicted_end_at` / `prediction_method`).
v2 (deferred) adds `predictor_model` — see §7.8.

## 5. Public interface

```python
class PredictorService:  # canonical (plan §4.1)
    def __init__(
        self,
        session: AsyncSession,
        tasks: TaskService,
        settings: AppSettingsService,
        clock: Clock,
        config: PredictorConfig,
    ) -> None: ...
    async def predict(self, inp: PredictionInput) -> Prediction: ...
    async def on_day_closed(self, local_date: date) -> None: ...  # v1 no-op; v2 retrain
    async def accuracy(self, start: date, end: date) -> AccuracyDTO: ...
    async def status(self) -> PredictorStatusDTO: ...  # for GET /predictor/status


class Predictor(Protocol):  # swap point v1 ↔ v2
    name: str  # "statistics_v1" | "ml"

    async def predict_duration(self, inp: PredictionInput, ctx: PredictionContext) -> RawPrediction: ...


class TaskPredictionAdapter:  # implements tasks.EndTimePredictorPort
    def __init__(self, service: PredictorService) -> None: ...
    async def predict_end(self, req: PredictionRequest) -> PredictedEnd: ...  # maps fields 1:1
```

```python
PredictionMethod = (
    Literal["template_p60", "category_p60", "user_estimate", "global_p60", "default_60"] | str
)  # or "ml:{version}"


class PredictionInput(BaseModel):
    title: str  # 1..200; unused by v1 (reserved for v2 features)
    category: str
    start_at: AwareDatetime | None = None
    estimate_min: int | None = None  # 1..720
    template_id: UUID | None = None  # series id (task.origin_template_id)


class Prediction(BaseModel):
    predicted_end_at: datetime | None  # None when start_at is None
    duration_min: int  # after [min,max] clamp
    method: str  # PredictionMethod
    sample_count: int  # samples behind the chosen step (0 for user_estimate/default_60)
    capped_at_midnight: bool = False  # extra field


class PredictionContext(BaseModel):  # built once per predict()
    history: list[TaskOutcomeDTO]
    tz: ZoneInfo
    now: datetime


class RawPrediction(BaseModel):
    duration_min: float
    method: str
    sample_count: int


class MethodAccuracy(BaseModel):
    n: int
    mae_min: float | None


class AccuracyDTO(BaseModel):
    start: date
    end: date
    n_labelled: int  # labelled tasks with a prediction
    mae_min: float | None  # mean |actual_end − predicted_end|
    median_abs_error_min: float | None
    mean_signed_error_min: float | None  # actual − predicted; > 0 ⇒ tasks end later than predicted
    within_15_min_pct: float | None  # share with |error| ≤ 15 min, 0..100
    checks_answered: int  # tasks with any check response
    not_yet_count: int
    not_yet_pct: float | None  # not_yet_count / checks_answered · 100
    by_method: dict[str, MethodAccuracy]


class PredictorStatusDTO(BaseModel):
    engine: Literal["statistics_v1", "ml"]
    model_version: str | None
    labelled_samples: int
    v2_enabled: bool
    v2_min_samples: int
    accuracy_7d: AccuracyDTO
    accuracy_30d: AccuracyDTO
```

## 6. HTTP endpoints

All `Depends(current_user)`; RFC 7807 errors.

| Method & path | Request | Response | Errors |
|---|---|---|---|
| `POST /predictor/predict` | `PredictionInput` | 200 `Prediction` | 422 |
| `GET /predictor/status` | — | 200 `PredictorStatusDTO` | — |

Example:
```json
POST /api/v1/predictor/predict
{"title":"Write report","category":"Work","start_at":"2026-11-09T14:00:00+01:00","estimate_min":45,"template_id":null}
→ 200 {"predicted_end_at":"2026-11-09T14:12:00Z","duration_min":72,"method":"category_p60","sample_count":11,"capped_at_midnight":false}
```
```json
GET /api/v1/predictor/status
→ 200 {"engine":"statistics_v1","model_version":null,"labelled_samples":84,"v2_enabled":false,"v2_min_samples":30,
       "accuracy_7d":{"n_labelled":23,"mae_min":14.2,"median_abs_error_min":9.0,"not_yet_pct":17.4,"…":"…"},
       "accuracy_30d":{"…":"…"}}
```

## 7. Behaviour & rules

### 7.1 `predict()` pipeline
1. `tz = settings.tz()`, `now = clock.now_utc()`, `today = clock.today_local(tz)`.
2. `history = tasks.history(since=today − PREDICTOR_V1_LOOKBACK_DAYS)` (one query; labelled per tasks §7.7: completed, timed, source `notification_action|manual`, 1–1440 min).
3. Select implementation: v2 `MLPredictor` iff `PREDICTOR_V2_ENABLED` and an active `predictor_model` exists; else `StatisticsPredictor`. If the ML call raises → log and use `StatisticsPredictor` (P10).
4. `raw = impl.predict_duration(inp, ctx)`.
5. Clamp: `duration_min = min(max(ceil(raw.duration_min), PREDICTOR_MIN_DURATION_MIN), PREDICTOR_MAX_DURATION_MIN)`.
6. End time (only if `start_at`): `end = start_at + duration_min`; `cap = local_to_utc(start_local_date + 1 day, 00:00) − 1 min` (23:59 local of the start's local day). If `end > cap` and `cap > start_at` → `end = cap`, `capped_at_midnight = true`. If `start_at ≥ cap` → keep `end` uncapped (mobile never schedules past midnight anyway). Result in UTC, seconds truncated.
7. No `start_at` ("anytime"): `predicted_end_at = None`; `duration_min` still returned (feasibility uses it for load).

### 7.2 v1 fallback chain (exact, plan §10.1)
Samples within each group are the **most recent** `PREDICTOR_V1_MAX_SAMPLES` (by `actual_end_at`) of `history`.

| # | Condition | duration | method | sample_count |
|---|---|---|---|---|
| 1 | `template_id` set and samples with `outcome.template_id == template_id` ≥ **3** | p60 of those | `template_p60` | n |
| 2 | samples with `outcome.category.casefold() == inp.category.casefold()` ≥ **5** | p60 | `category_p60` | n |
| 3 | `estimate_min` is not None | `estimate_min` | `user_estimate` | 0 |
| 4 | all samples ≥ **5** | p60 | `global_p60` | n |
| 5 | otherwise | 60 | `default_60` | 0 |

Thresholds are config (§8) but default to the plan's values. Title is not used in v1.

### 7.3 Percentile method
Linear interpolation between closest ranks (Hyndman–Fan type 7, equals `numpy.percentile(..., method="linear")`):
```python
def percentile(xs: Sequence[float], q: float) -> float:  # q in [0, 100]
    s = sorted(xs)
    h = (len(s) - 1) * q / 100
    lo = floor(h)
    return s[lo] if lo + 1 >= len(s) else s[lo] + (h - lo) * (s[lo + 1] - s[lo])
```
`q = PREDICTOR_V1_PERCENTILE` (60). Result rounded **up** to whole minutes in §7.1 step 5 so the check lands slightly after the typical finish. Example: durations `[30, 35, 40, 50, 90]` → h = 2.4 → 40 + 0.4·10 = 44 → 44 min.

### 7.4 `accuracy(start, end)`
`tasks = tasks_in_range(start, end)` (inclusive local dates).
- Labelled-with-prediction set `L`: `status = completed`, `start_at`, `actual_end_at`, `predicted_end_at` not null, `actual_end_source ∈ {notification_action, manual}`.
- `e_i = (actual_end_at − predicted_end_at)` in minutes (float). `mae = mean(|e|)`, `median_abs_error = median(|e|)` (statistics.median), `mean_signed_error = mean(e)`, `within_15_min_pct = 100·|{|e| ≤ 15}|/|L|`. All `None` when `|L| = 0`; values rounded to 1 decimal.
- `checks_answered = |{t : check_response is not None or check_not_yet_at is not None}|` (over all tasks in range, any status); `not_yet_count = |{t : check_not_yet_at is not None}|`; `not_yet_pct = 100·not_yet_count/checks_answered` (None if 0).
- `by_method`: group `L` by `prediction_method` (null → `"none"`), `n` and `mae_min` per group.

### 7.5 `on_day_closed(local_date)`
v1: no-op (returns immediately; logs `labelled_samples` at debug). Must be idempotent and safe to call repeatedly (day_cycle pipeline may retry). v2: §7.8.

### 7.6 `status()`
`engine`/`model_version` from §7.1 step 3 selection; `labelled_samples = len(tasks.history())`; `accuracy_7d = accuracy(today−6, today)`, `accuracy_30d = accuracy(today−29, today)`.

### 7.7 Wiring into tasks
`main.py` builds `PredictorService` with a `TaskService` that has **no** predictor port (history reads only) and passes `TaskPredictionAdapter(predictor_service)` to the request's main `TaskService`. Adapter: `PredictionRequest → PredictionInput`, returns `PredictedEnd(predicted_end_at, method)`. Adapter enforces a 2 s timeout (`asyncio.wait_for`) so a slow prediction never blocks task creation.

### 7.8 v2 — ML with full retraining (**deferred**: process agreed, algorithm open)
Not implemented now; documented so v1 code leaves the right seams (`Predictor` protocol, `on_day_closed`, `prediction_method` strings, labelled history).

**Table `predictor_model`** (plan §5.10; created by the v2 migration only):

| Column | Type | Notes |
|---|---|---|
| id | uuid PK | |
| version | varchar(32) unique | `YYYY.MM.DD-N` (closed local date + sequence) → method string `ml:{version}` |
| algorithm | varchar(64) | e.g. `hgb_quantile` (TBD) |
| trained_at | timestamptz | |
| n_samples | int | rows used for the final fit |
| metrics | jsonb | `{holdout_mae_min, baseline_mae_min, incumbent_mae_min, n_train, n_holdout, half_life_days, feature_set}` (no personal text) |
| artifact 🔒 | bytea (`EncryptedBytes`, AAD `predictor_model.artifact`) | joblib bytes; nullable after pruning |
| is_active | bool | `UNIQUE (is_active) WHERE is_active` ⇒ at most one active; none ⇒ v1 |
| created_at, updated_at | timestamptz | |

**Retraining process in `on_day_closed(d)`** (runs inside the day_cycle background pipeline):
1. Return if `PREDICTOR_V2_ENABLED` is false.
2. `H = tasks.history()` (full history). If `len(H) < PREDICTOR_V2_MIN_SAMPLES` (30) → return (v1 serves).
3. `new = |{h ∈ H : h.actual_end_at > active.trained_at}|` (or all if no model). If `new < PREDICTOR_V2_MIN_NEW_LABELS` (3) → return.
4. Sort `H` by `actual_end_at`. Holdout = most recent `max(5, ceil(0.2·n))` rows; train = the rest (time-ordered, no shuffling).
5. Sample weights on train: `w_i = 0.5 ** (age_days_i / PREDICTOR_V2_HALF_LIFE_DAYS)`, age measured from the newest train row (60-day half-life).
6. Fit candidate from scratch on train (no `partial_fit`, no warm start). Evaluate unweighted MAE on holdout.
7. Baselines on the same holdout: (a) v1 statistics computed **only from train rows** (no leakage); (b) incumbent: the active model's algorithm/hyper-parameters **refit on the same train split** (its stored artifact has seen holdout rows, so it is not evaluated directly).
8. **Promotion gate:** promote iff `cand_mae < v1_mae` and (`no incumbent` or `cand_mae < incumbent_mae`). On promotion refit the candidate configuration on **all** rows with weights, serialize, and in one transaction insert the row and flip `is_active` (old → false, new → true). Otherwise insert the row with `is_active = false` (metrics kept for auditing).
9. Rollback = set `is_active` on a previous version (manual DB/admin op; API deferred); deactivating all ⇒ v1.
10. Retention: keep artifacts of the active model + last 5 versions; older rows keep metrics, `artifact = NULL`.

**Memory (Render 512 MB):** lazy-import sklearn/numpy/pandas inside the trainer; `n_jobs=1`; float32 feature matrices; ≤ ~5k rows/year → sub-second fit; delete frames and `gc.collect()` before returning; the trainer runs before report rendering in the pipeline (never concurrently). Loaded model cached per process by version; cache cleared on version change. Artifact is loaded only from our own encrypted, AAD-authenticated column (pickle risk contained).

## 8. Configuration
| Setting | Default | Meaning |
|---|---|---|
| `PREDICTOR_V1_PERCENTILE` | 60 | |
| `PREDICTOR_V1_MIN_TEMPLATE_SAMPLES` / `_CATEGORY_` / `_GLOBAL_` | 3 / 5 / 5 | fallback thresholds |
| `PREDICTOR_V1_MAX_SAMPLES` | 50 | most recent samples per group |
| `PREDICTOR_V1_LOOKBACK_DAYS` | 365 | history window |
| `PREDICTOR_DEFAULT_DURATION_MIN` | 60 | last fallback |
| `PREDICTOR_MIN_DURATION_MIN` / `PREDICTOR_MAX_DURATION_MIN` | 5 / 720 | clamp |
| `PREDICTOR_V2_ENABLED` | `false` | v2 deferred |
| `PREDICTOR_V2_MIN_SAMPLES` / `_MIN_NEW_LABELS` / `_HALF_LIFE_DAYS` / `_HOLDOUT_FRACTION` | 30 / 3 / 60 / 0.2 | v2 process |

## 9. Errors & degradation
- `predict` never raises for data reasons: empty history ⇒ `user_estimate` or `default_60`.
- `tasks.history` DB failure → error propagates (503 via core); the tasks adapter catches it and stores a null prediction.
- v2 failure at inference ⇒ v1; at training ⇒ logged, active model unchanged, `on_day_closed` returns normally.

## 10. Security & privacy
- v1 is in-process statistics; no data leaves the server. `title` is accepted but unused; never logged.
- Logs: method, sample_count, durations — no titles/categories beyond the category label.
- v2 artifact encrypted (`EncryptedBytes`); features must not include raw title text unless separately approved.

## 11. Testing plan
Fixtures: `fake_tasks` (returns fixture `TaskOutcomeDTO` / `TaskDTO` lists), `fake_clock`, `tz_berlin`, `outcome(template=…, category=…, minutes=…, days_ago=…)` factory, `api_client`; integration uses real `TaskService` on Postgres.

Unit: `test_percentile_type7_examples` (incl. n=1, n=2), `test_chain_template_p60_with_3_samples`, `test_chain_template_needs_3_falls_to_category`, `test_chain_category_case_insensitive`, `test_chain_user_estimate_before_global`, `test_chain_global_p60`, `test_chain_default_60_empty_history`, `test_max_samples_most_recent_only`, `test_clamp_min_5`, `test_clamp_max_720`, `test_cap_at_local_2359`, `test_no_start_at_returns_duration_only`, `test_ceil_rounding`, `test_accuracy_metrics_known_values`, `test_accuracy_not_yet_pct`, `test_accuracy_empty_is_none`, `test_accuracy_excludes_eod_resolution`, `test_on_day_closed_v1_noop_idempotent`, `test_ml_failure_falls_back_to_v1` (fake `Predictor`).

Integration: `test_predict_endpoint`, `test_status_endpoint`, `test_adapter_used_by_tasks_create`, `test_adapter_timeout_returns_null_prediction`, `test_history_driven_prediction_end_to_end` (complete 3 recurring occurrences via check-response, 4th materialized occurrence gets `template_p60`).

## 12. Acceptance criteria
| ID | Given / When / Then | Test |
|---|---|---|
| PRED-AC-01 | Given 3 labelled samples of a template (30, 40, 50 min), When predicting for that template, Then method `template_p60`, duration 42 min | `test_chain_template_p60_with_3_samples` |
| PRED-AC-02 | Given 2 template samples and 5 category samples, Then `category_p60` | `test_chain_template_needs_3_falls_to_category` |
| PRED-AC-03 | Given < 5 category samples and an estimate of 45, Then `user_estimate`, 45 min | `test_chain_user_estimate_before_global` |
| PRED-AC-04 | Given no estimate and ≥ 5 samples overall, Then `global_p60`; with empty history, Then `default_60` / 60 min | `test_chain_global_p60`, `test_chain_default_60_empty_history` |
| PRED-AC-05 | Given start 23:30 local and duration 60, Then `predicted_end_at` = 23:59 local, `capped_at_midnight=true` | `test_cap_at_local_2359` |
| PRED-AC-06 | Given an anytime input, Then `predicted_end_at=null` and `duration_min` returned | `test_no_start_at_returns_duration_only` |
| PRED-AC-07 | Given known errors, Then MAE, median abs error and not-yet % equal hand-computed values; EOD-resolved tasks are excluded | `test_accuracy_metrics_known_values`, `test_accuracy_not_yet_pct`, `test_accuracy_excludes_eod_resolution` |
| PRED-AC-08 | `on_day_closed` in v1 changes nothing and can be called twice | `test_on_day_closed_v1_noop_idempotent` |
| PRED-AC-09 | A failing ML predictor degrades to v1 | `test_ml_failure_falls_back_to_v1` |
| PRED-AC-10 | Creating a task through `tasks` stores the predictor's end and method; a predictor timeout stores null | `test_adapter_used_by_tasks_create`, `test_adapter_timeout_returns_null_prediction` |

## 13. Open questions
1. Plan §4 lists `predictor ──▶ tasks, core`; v2's encrypted artifact needs `crypto` too (crypto is allowed for "all modules persisting personal text" — the artifact is arguably personal data). Add `crypto` to the predictor edge.
2. `tasks` must call the predictor although `predictor` depends on `tasks`; resolved via `tasks.EndTimePredictorPort` + `TaskPredictionAdapter` wired in `main.py` (see tasks spec §13 Q1).
3. Plan §10.1 measures duration (`actual_end − start`) while accuracy is reported on end times; these differ only when the prediction was capped at midnight. Accept.
4. v2 incumbent comparison: plan says "beats the active model"; this spec evaluates the incumbent configuration refit on the same train split to avoid leakage. Confirm when v2 is designed.
5. Should `title` similarity (one-time tasks repeated without a template) enter the v1 chain? Plan's chain excludes it; left for v2 features.

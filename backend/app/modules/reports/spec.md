# Module Spec — `reports`

> Backend module · Governed by [`constitution.md`](../../../../constitution.md) and [`plan.md`](../../../../plan.md) §8.3, §11.
> Builds the daily (EOD) and weekly (Sunday) BI reports: pandas metrics → seaborn/matplotlib charts → PDF →
> Groq narrative. Emails a report **only** when explicitly asked (P5).

## 1. Purpose & scope

| Capability | Role |
|---|---|
| C9 | `ReportService.generate(kind, period_start)` — called by day_cycle's close pipeline; regenerate endpoint |
| C10 | `POST /reports/{id}/email` → `ReportService.email` → `email.EmailService.send` |

Out of scope: deciding *when* to generate (day_cycle), scheduling, auto-emailing (forbidden).

## 2. Folder layout

```
reports/
├── spec.md
├── __init__.py          # exports ReportService, ReportKind, ReportDTO, ReportSummaryDTO
├── api.py               # endpoints §6
├── service.py           # ReportService (lifecycle, idempotency, email, pruning)
├── metrics.py           # pure pandas metric functions (daily / weekly)
├── charts/
│   ├── style.py         # matplotlib Agg setup, seaborn theme, palette, fonts, figure helpers
│   ├── daily.py         # 5 daily charts
│   ├── weekly.py        # 6 weekly charts
│   └── pdf.py           # PdfPages bundle (cover page + charts)
├── narrative.py         # Groq narrative + deterministic fallback
├── templates/email_report.html.j2
├── prompts/narrative.v1.j2
├── models.py            # report, report_asset ORM
├── repository.py
└── schemas.py
```

## 3. Dependencies

- Modules: `core`, `crypto`, `tasks` (`tasks_in_range`), `predictor` (`accuracy`), `feasibility` (`outcomes`),
  `ai_gateway` (`generate`), `email` (`EmailService`, `EmailMessage`).
- Packages: `pandas`, `numpy`, `matplotlib`, `seaborn`, `jinja2`. All imported lazily inside `generate()`
  (keeps cold-start memory low on Render 512 MB).

## 4. Data owned

`report`
| Column | Type | Notes |
|---|---|---|
| id | uuid PK | |
| kind | text | `daily` \| `weekly` |
| period_start, period_end | date | daily: same date; weekly: Monday..Sunday |
| status | text | `pending` \| `ready` \| `failed` |
| metrics 🔒 | EncryptedJSON (`report.metrics`) | §7.2 structure |
| narrative 🔒 | EncryptedText (`report.narrative`) | |
| narrative_degraded | bool | |
| error | text null | failure reason (no personal text) |
| attempts | int default 0 | |
| generated_at, emailed_at | timestamptz null | |
| created_at, updated_at | timestamptz | |
| unique | `(kind, period_start)` | idempotency |

`report_asset`
| Column | Type | Notes |
|---|---|---|
| id | uuid PK | |
| report_id | uuid FK → report.id ON DELETE CASCADE | index |
| name | text | e.g. `status_donut.png`, `report.pdf` (unique per report) |
| mime | text | `image/png` \| `application/pdf` |
| blob 🔒 | EncryptedBytes (`report_asset.blob`) null | null after pruning |
| size_bytes | int | plaintext size |
| order_idx | smallint | display order |
| created_at, updated_at | timestamptz | |

Migration (M4) also adds FKs `day_session.daily_report_id / weekly_report_id → report.id` (owned by day_cycle's
migration ordering, executed in M4).

## 5. Public interface

```python
class ReportKind(StrEnum):
    DAILY = "daily"
    WEEKLY = "weekly"


class AssetDTO(BaseModel):
    name: str
    mime: str
    size_bytes: int
    available: bool
    url: str  # /api/v1/reports/{id}/assets/{name}


class ReportSummaryDTO(BaseModel):
    id: UUID
    kind: ReportKind
    period_start: date
    period_end: date
    status: str
    completion_rate: float | None
    handled_rate: float | None
    generated_at: datetime | None
    emailed_at: datetime | None


class ReportDTO(ReportSummaryDTO):
    metrics: dict | None
    narrative: str | None
    narrative_degraded: bool
    assets: list[AssetDTO]
    error: str | None


class ReportService:
    async def generate(self, kind: ReportKind, period_start: date, *, force: bool = False) -> UUID: ...
    async def email(self, report_id: UUID) -> EmailResult: ...
    async def get(self, report_id: UUID) -> ReportDTO: ...
    async def list(self, kind: ReportKind | None, limit: int = 30) -> list[ReportSummaryDTO]: ...
    async def latest_ready(self, kind: ReportKind) -> ReportSummaryDTO | None: ...  # used by assistant
```

## 6. HTTP endpoints

| Method & path | Body / params | Response | Errors |
|---|---|---|---|
| `GET /api/v1/reports?kind=daily&limit=30` | | 200 `[ReportSummaryDTO]` newest first | 422 |
| `GET /api/v1/reports/{id}` | | 200 `ReportDTO` (`status` may be `pending`) | 404 |
| `GET /api/v1/reports/{id}/assets/{name}` | | 200 bytes, `Content-Type` = mime, `Cache-Control: private, max-age=86400` | 404 unknown; 410 pruned (regenerate) |
| `POST /api/v1/reports/{id}/email` | — | 200 `{status, sent_at}` | 404; 409 `report-not-ready`; 409 `report-email-not-configured`; 502 `email-failed` |
| `POST /api/v1/reports/generate` | `{"kind":"daily","period_start":"2026-11-09"}` | 202 `{id, status}` (rendered in a BackgroundTask) | 422 weekly period_start not Monday; 409 period not closed yet |

Problem types: `…/problems/report-email-not-configured` (detail: "Set a report email in Settings first"), the app
deep-links to Settings on this type.

## 7. Behaviour & rules

### 7.1 `generate(kind, period_start, force=False)` lifecycle
1. Validate: weekly `period_start.weekday() == 0`; period_end = start (daily) or start+6 (weekly).
2. Upsert `report` row on `(kind, period_start)`:
   - exists `ready` and not `force` → return id (idempotent; day_cycle may retry).
   - exists `pending` with `updated_at` < 10 min ago → return id (another run in progress).
   - else set `status=pending`, `attempts += 1`, commit.
3. Load data: `tasks = tasks_in_range(start, end)`, `acc = predictor.accuracy(start, end)`,
   `outs = feasibility.outcomes(start, end)` (feasibility absent in early milestones → `[]`).
   For weekly also load the previous week's tasks for week-over-week deltas.
4. `metrics = metrics.daily(...) | metrics.weekly(...)` (pure, §7.2).
5. Render charts sequentially (§7.3); after each: `buf = BytesIO(); fig.savefig(buf, format="png", dpi=150,
   bbox_inches="tight"); plt.close(fig)`; store asset. Then build `report.pdf` (§7.4).
6. Narrative (§7.5).
7. `status=ready`, `generated_at=now`, commit. Prune old assets (§7.7).
8. Any exception → `status=failed`, `error=<ExceptionClass: short msg without titles>`, commit, re-raise to the
   caller's logging (day_cycle records the failure and can retry; `generate` with an existing failed row retries).

Memory: peak target < 250 MB; never hold more than one open figure; DataFrames limited to the period.

### 7.2 Metrics (`metrics.py`)
Definitions (T = tasks in period; statuses from tasks):
| Metric | Formula |
|---|---|
| `counts` | per status: planned, completed, postponed, cancelled, cant_do, missed |
| `completion_rate` | **Completed** = completed / total; null if total = 0 (decided 2026-11-09) |
| `handled_rate` | **Handled** = (completed + cancelled + postponed) / total; null if total = 0 — cancelling/postponing is a conscious decision, so only missed and can't-do count against it (decided 2026-11-09). Both rates are always shown side by side. |
| `planned_minutes` | Σ predicted duration (predicted_end−start) or estimate or 60, for tasks with start_at |
| `actual_minutes` | Σ (actual_end − start) for completed tasks with both |
| `per_task` | list: title, category, start_local, planned_min, actual_min, status, verdict |
| `minutes_by_category` | Σ actual minutes (fallback planned) grouped by category |
| `estimate_accuracy` | from `predictor.accuracy`: n, mae_min, median_abs_error_min, not_yet_rate |
| `feasibility` | counts per verdict × outcome (completed vs not), override count and override completion rate |
| `streak_days` | consecutive closed days (ending at period end) with completion_rate ≥ 0.8 |
| weekly: `daily_completion` | per day Mon..Sun: completion_rate and handled_rate (null for days without tasks) |
| weekly: `status_by_day` | counts per status per day |
| weekly: `completions_heatmap` | 7×24 matrix: completed tasks by local weekday × actual_end hour |
| weekly: `top_slipped` | top 5 titles by (postponed + cant_do + missed) count, ties by title |
| weekly: `wow_delta` | `{completion, handled}`: each rate − previous week's |

Stored in `report.metrics` (encrypted because titles appear).

### 7.3 Charts (`charts/`)
Common style: `matplotlib.use("Agg")`; `sns.set_theme(style="whitegrid", context="notebook")`; status palette
fixed: completed `#2e7d32`, planned `#9e9e9e`, postponed `#f9a825`, cancelled `#757575`, cant_do `#c62828`,
missed `#6a1b9a`; category palette `sns.color_palette("Set2")` assigned in sorted category order; figure size
8×4.5 in (donut 6×6); titles include the date range; times in local tz. Empty data → placeholder figure with
centred text "No data for this period" (still a valid PNG).

Daily (`order_idx` 1–5):
| Name | Chart | Data / encoding |
|---|---|---|
| `status_donut.png` | donut (pie, wedge width 0.4) | counts by status, centre text = "Completed 50% · Handled 83%" |
| `planned_vs_actual.png` | grouped horizontal bar | per task: planned vs actual minutes, sorted by start time |
| `timeline.png` | Gantt (`barh` with `left`) | y = task; light bar planned [start, predicted_end], solid bar actual [start, actual_end]; x = local hours; vertical line at close time |
| `minutes_by_category.png` | vertical bar | minutes by category, sorted desc |
| `verdict_vs_outcome.png` | stacked bar | x = verdict (go/caution/no_go/none), stacks = completed vs not completed; hatching on overridden |

Weekly (`order_idx` 1–6):
| Name | Chart | Data / encoding |
|---|---|---|
| `completion_trend.png` | two lines with markers | Mon..Sun Completed % and Handled % (0–100 %), dashed line at last week's average Completed % |
| `status_by_day.png` | stacked bar | per day counts by status (status palette) |
| `time_by_category.png` | pie | weekly minutes by category (≤ 6 slices, rest "Other") |
| `completions_heatmap.png` | `sns.heatmap` | 7×24, hours 05–24 shown, cmap `Greens`, annot off |
| `predicted_vs_actual.png` | scatter + y=x line | x predicted min, y actual min, colour by category; text box with MAE |
| `top_slipped.png` | horizontal bar | top 5 slipped tasks (counts) |

### 7.4 PDF (`charts/pdf.py`)
`matplotlib.backends.backend_pdf.PdfPages`: page 1 = cover (title "Daily report — Mon 9 Nov 2026" / "Weekly report —
2–8 Nov 2026", key metrics table, narrative text wrapped), then one chart per page (re-plot from metrics, not
from PNG). Stored as `report.pdf`.

### 7.5 Narrative (`narrative.py`, `prompts/narrative.v1.j2`)
`ai_gateway.generate("narrative", "reports/narrative.v1.j2", ctx, max_tokens=220)`, `{# max_chars: 800 #}`.
ctx: kind, period, counts, completion_rate, handled_rate, wow_delta (weekly), top 3 completed titles, slipped titles, estimate MAE,
streak. Prompt rules: ≤ 120 words; three short parts — Wins, Misses, One suggestion for tomorrow (daily) / next
week (weekly); second person; no invented facts; no moralising.
Fallback (empty text): template, e.g. "You completed {completed} of {denominator} tasks ({pct}%). {missed} missed,
{postponed} postponed. Suggestion: {rule-based tip}" where tip = first matching rule: many missed → "plan fewer
tasks"; MAE > 30 → "add estimates to new tasks"; else "keep the same rhythm". `narrative_degraded=true`.

### 7.6 Email (`email(report_id)`)
1. Report must be `ready` → else 409 `report-not-ready`.
2. `settings.report_email` must be set → else 409 `report-email-not-configured`.
3. Load assets (if pruned → regenerate with `force=True` first).
4. Render `email_report.html.j2`: header, key metrics, narrative, `<img src="cid:{name}">` for each PNG in order.
5. `EmailService.send(EmailMessage(to=report_email, subject="Daily report — Mon 9 Nov" | "Weekly report — 2–8 Nov",
   html=…, inline_images={name: png}, attachments=[EmailAttachment("report.pdf","application/pdf",pdf)],
   report_id=id))`. (Inline vs attachment handling per `EMAIL_INLINE_MODE` in the email module.)
6. Success → `emailed_at=now`. Failure → 502 `email-failed` with the email error code. Re-sending is allowed
   (explicit user action each time). **Nothing in this module calls `email()` automatically.**

### 7.7 Pruning
At the end of each successful `generate`, set `blob=NULL` for assets of reports with `period_end < today − 90 days`
(≤ 200 rows per run). Metrics and narrative are kept forever; assets are regenerable via `POST /reports/generate`
with `force`.

## 8. Configuration

`REPORT_ASSET_RETENTION_DAYS` (90), `REPORT_CHART_DPI` (150), `REPORT_NARRATIVE_MAX_WORDS` (120).
Reads `app_settings.report_email` and timezone via `AppSettingsService`.

## 9. Errors & degradation

| Case | Behaviour |
|---|---|
| Narrative AI fails | template narrative, `narrative_degraded=true`, report still `ready` |
| One chart raises | that asset replaced by placeholder PNG; error logged; report still `ready` |
| Data load / PDF fails | `status=failed`; retried on next `generate` call |
| Email not configured | 409 with actionable problem type |
| Email provider fails | 502; `emailed_at` unchanged |

## 10. Security & privacy

Metrics (contain titles), narrative and chart/PDF bytes encrypted at rest. Asset endpoint requires JWT (the app
loads images with the auth header). Email only on explicit request, only to the configured address.
Logs never include titles or narrative.

## 11. Testing plan

Unit (pure, fixture tasks): `test_completion_rate_is_completed_over_total`, `test_handled_rate_counts_cancelled_and_postponed`, `test_planned_actual_minutes`,
`test_minutes_by_category_fallback_planned`, `test_streak_days`, `test_weekly_heatmap_shape`,
`test_top_slipped_ordering`, `test_wow_delta`.
Charts: `test_each_daily_chart_renders_png` / `test_each_weekly_chart_renders_png` (PNG magic bytes, size > 1 KB),
`test_empty_data_placeholder`, `test_figures_closed_after_render` (`plt.get_fignums() == []`), `test_pdf_has_cover_plus_charts`.
Service: `test_generate_idempotent_ready`, `test_generate_pending_recent_returns_same_id`,
`test_generate_failure_marks_failed_then_retry`, `test_narrative_fallback_sets_degraded`,
`test_email_requires_ready`, `test_email_not_configured_409`, `test_email_builds_cid_html_and_pdf_attachment`,
`test_email_never_called_by_generate`, `test_pruning_nulls_old_blobs`.
Integration: `test_assets_encrypted_at_rest`, `test_asset_endpoint_requires_auth`, `test_generate_endpoint_weekly_requires_monday`.

## 12. Acceptance criteria

| ID | Given / When / Then | Tests |
|---|---|---|
| REP-AC-01 | Given a closed day, When `generate(daily, d)`, Then a `ready` report with 5 PNGs + `report.pdf` + narrative exists | `test_each_daily_chart_renders_png`, `test_pdf_has_cover_plus_charts` |
| REP-AC-02 | Given a closed Sunday, When `generate(weekly, monday)`, Then 6 weekly charts covering Mon–Sun exist | `test_each_weekly_chart_renders_png` |
| REP-AC-03 | Calling `generate` twice for the same period returns the same id without re-rendering | `test_generate_idempotent_ready` |
| REP-AC-04 | No report is ever emailed unless `POST /reports/{id}/email` is called | `test_email_never_called_by_generate` |
| REP-AC-05 | Given no report email configured, When emailing, Then 409 `report-email-not-configured` | `test_email_not_configured_409` |
| REP-AC-06 | Given AI is down, Then the report is still `ready` with a template narrative | `test_narrative_fallback_sets_degraded` |
| REP-AC-07 | Metrics, narrative and assets are ciphertext at rest | `test_assets_encrypted_at_rest` |
| REP-AC-08 | No matplotlib figures remain open after generation | `test_figures_closed_after_render` |

## 13. Open questions

1. ~~Completion-rate definition~~ — resolved 2026-11-09: show both Completed % and Handled %.
2. Should the weekly report also be generated when the user closes Saturday and skips Sunday entirely? (day_cycle spec already covers a never-opened Sunday via catch-up.)

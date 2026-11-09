# Feature Spec — `reports` (mobile)

> Flutter feature · Governed by [`constitution.md`](../../../../constitution.md) P5 and [`plan.md`](../../../../plan.md) §8.3, §11.
> Owns the End-of-Day flow ("Done for the day"), the report viewer/list, and the explicit "Email this report" action.

## 1. Purpose & scope

| Capability | Role |
|---|---|
| C8 | `DoneForTheDayButton` + `EodFlow`: resolve open tasks → close day → cancel notifications → open report |
| C9 | Reports tab: daily/weekly lists, report viewer with narrative, metric tiles and chart PNGs |
| C10 | `ReportEmailAction`: emails a report only when I tap the button (or confirm a chat proposal) |

Out of scope: generating reports (backend), PDF viewing/sharing (deferred — needs extra packages).

## 2. Folder layout

```
features/reports/
├── spec.md
├── data/
│   ├── reports_api.dart        # GET /reports, GET /reports/{id}, GET assets, POST email, POST generate
│   ├── day_close_api.dart      # GET /days/current/unresolved, POST /days/current/close, GET /days/{date}
│   └── dto.dart
├── domain/
│   ├── eod_flow.dart           # EodFlow orchestration (§8.1)
│   ├── report_poller.dart      # pure backoff schedule + polling loop (§8.2)
│   └── email_action.dart       # ReportEmailAction (§8.4)
└── presentation/
    ├── done_for_the_day_button.dart
    ├── resolution_sheet.dart   # per-task quick actions before closing
    ├── closing_screen.dart     # "Wrapping up your day…" while reports generate
    ├── reports_list_screen.dart  # /reports (tabs Daily / Weekly)
    ├── report_screen.dart      # /reports/:id
    ├── chart_image.dart        # authenticated PNG loader + pinch zoom
    └── providers.dart
```

## 3. Dependencies

- Features: `app_shell` (`apiClientProvider`, `AppError`/`ConflictError`, `serverStatusProvider`, `LocalDate`,
  router), `tasks` (`currentDayControllerProvider` incl. `markDayClosed`, `tasksRepositoryProvider.setStatus`,
  `StatusSheet`, `Task`, `Day`, `StatusChange`), `notifications` (`cancelAllForDay()`).
- Packages: flutter_riverpod, go_router, freezed/json_serializable, (InteractiveViewer from Flutter SDK for zoom).

## 4. Local data

None persisted beyond the drift cache owned by tasks. Chart bytes cached in memory (LRU, 20 images).

## 5. Public interface

```dart
class DoneForTheDayButton extends ConsumerWidget {}            // used on Today screen (tasks)
abstract final class EodFlow { static Future<void> start(BuildContext c); }          // used by chat close_day proposal
abstract final class ReportEmailAction {
  static Future<bool> send(BuildContext c, String reportId);   // used by chat email_report proposal
}
final reportsRepositoryProvider = Provider<ReportsRepository>(...);
//   Future<List<ReportSummary>> list({ReportKind? kind, int limit = 30});
//   Future<ReportSummary?> latest(ReportKind kind);            // newest with status ready
//   Future<Report> get(String id);  Future<Uint8List> asset(String id, String name);
//   Future<EmailSent> email(String id);
final reportProvider = FutureProvider.autoDispose.family<Report, String>(...);   // with polling while pending
enum ReportKind { daily, weekly }
```
Routes: `/reports` (tab), `/reports/:id`.

## 6. Backend endpoints used

| Endpoint | Use |
|---|---|
| `GET /api/v1/days/current/unresolved` | tasks still `planned` for the resolution sheet |
| `POST /api/v1/days/current/close` | 202 `{local_date, state:"closing", missed_count, daily_report_id:null, …}`; 200 if already closed |
| `GET /api/v1/days/{date}` | poll until `state == closed` and `daily_report_id` (and `weekly_report_id` on Sundays) present |
| `GET /api/v1/reports?kind=&limit=` | lists |
| `GET /api/v1/reports/{id}` | report (may be `pending`/`failed`) |
| `GET /api/v1/reports/{id}/assets/{name}` | PNG bytes (auth header); 410 → offer regenerate |
| `POST /api/v1/reports/{id}/email` | explicit email; 409 `report-email-not-configured` / `report-not-ready`; 502 `email-failed` |
| `POST /api/v1/reports/generate` | "Regenerate" on failed/pruned reports |

## 7. Screens & UX flow

**DoneForTheDayButton** (Today screen bottom, only when `day.state == open`) → `EodFlow.start`.

**Resolution sheet** — title "Before you wrap up" · list of unresolved tasks, each with quick actions:
Done (sets finished time = now, editable), Tomorrow (postpone to tomorrow same time; anytime tasks → tomorrow
anytime), Can't do (reason field required), Leave (will become *missed*). Footer: "N tasks will be marked missed"
+ **Close day** button. If no unresolved tasks, the sheet shows "Everything is resolved." with **Close day**. Cancel returns to Today with nothing changed.

**Closing screen** — "Wrapping up your day…" with steps (Saving day ✓, Building report…). Polls (§8.2).
Ready → replaces itself with the report screen. Takes > 90 s → "Your report is still being built — we'll show it in
Reports" + button to Reports tab.

**Report screen** — header (Daily · Mon 9 Nov / Weekly · 2–8 Nov), metric tiles (**Completed %** and **Handled %** side by side, completed/total,
planned vs actual hours, estimate error, streak), narrative card (with "basic summary" label when
`narrative_degraded`), charts in server order (each card: title + image, tap → full-screen pinch zoom),
bottom bar: **Email this report**. `pending` → skeleton + polling; `failed` → message + **Regenerate**.

**Reports list** — tabs Daily / Weekly; rows: period, Completed % · Handled %, status chip, "Emailed" badge if `emailed_at`.

## 8. Behaviour & rules

### 8.1 EodFlow
1. Guard: day must be `open` (re-fetch `currentDay`); otherwise open the existing report.
2. `GET /days/current/unresolved` → show resolution sheet.
3. Apply chosen actions sequentially via `tasksRepositoryProvider.setStatus(..., source: eod)`; failures stay in the
   sheet with an inline error; Close is disabled until all chosen actions succeed.
4. `POST /days/current/close`.
5. Immediately `notifications.cancelAllForDay()` and `currentDayController.markDayClosed(day)` (Today becomes read-only).
6. Push closing screen → poll `GET /days/{date}` (§8.2) → when `daily_report_id` present (and weekly if
   `local_date.weekday == Sunday`) → navigate to `/reports/{daily_report_id}`; on Sundays the report screen shows a
   "Weekly report ready" banner linking to the weekly one.
Nothing is emailed in this flow.

### 8.2 Polling (`report_poller.dart`, pure schedule)
Delays: 2, 2, 3, 5, 5, 8, 8, 10 s…, capped at 10 s; stop after 90 s total (closing screen) or when the screen is
disposed. Same schedule for `reportProvider` while `status == pending`. Poll requests don't trigger the
WakingServer retries beyond ApiClient defaults.

### 8.3 Chart images
`chart_image.dart` fetches bytes with the auth header via `reportsRepository.asset()`, displays `Image.memory`
with `gaplessPlayback`, placeholder while loading, error tile with retry; 410 → "Chart expired — Regenerate".

### 8.4 ReportEmailAction
1. Confirmation dialog: "Email this report to {masked email}?" (email from settings; if not set → step 4 directly).
2. `POST /reports/{id}/email` → success snackbar "Report emailed" and update `emailed_at`.
3. 409 `report-not-ready` → snackbar "Report is still being built".
4. 409 `report-email-not-configured` (or no email in settings) → dialog "Add a report email in Settings" → button
   navigates to Settings with the email field focused.
5. 502 → "Couldn't send the email. Try again later."
Never invoked automatically (only from the button or a confirmed chat proposal).

## 9. Platform configuration

None beyond app_shell.

## 10. Errors & offline behaviour

Offline: Done-for-the-day disabled with "Needs internet" (close must reach the server); reports list shows cached
summaries if available, otherwise error state. Close request network failure after step 3 → retry button; server
close is idempotent (200 if already closed). Polling errors are swallowed until the time cap.

## 11. Testing plan

Unit: `poller_schedule_caps_at_10s_and_90s`, `eod_flow_blocks_close_until_actions_succeed`,
`eod_flow_cancels_notifications_after_close`, `eod_flow_waits_for_weekly_on_sunday`,
`email_action_not_configured_navigates_to_settings`, `email_action_success_updates_emailed_at`.
Widget: `resolution_sheet_actions_and_missed_count`, `closing_screen_timeout_message`, `report_screen_pending_then_ready`,
`report_screen_failed_regenerate`, `chart_image_auth_and_410`, `degraded_narrative_label`, `done_button_hidden_when_closed`.
Integration (mock API): full EOD: resolve 2 tasks → close (202) → poll → report screen; email button → POST once.

## 12. Acceptance criteria

- **M-REP-AC-01** Given an open day with 2 planned tasks, When I tap Done for the day, Then the resolution sheet lists both and states how many will be marked missed.
- **M-REP-AC-02** When I tap Close day, Then `POST /days/current/close` is called, all notifications for the day are cancelled, and Today becomes read-only.
- **M-REP-AC-03** Given the close returned 202, Then the app polls until the daily report id exists and opens the report screen.
- **M-REP-AC-04** On a Sunday close, the weekly report is also linked when ready.
- **M-REP-AC-05** The report screen shows narrative, metric tiles and every chart PNG returned by the server.
- **M-REP-AC-06** A report is emailed only after I tap Email this report and confirm; no other path sends email.
- **M-REP-AC-07** Given no report email configured, When I tap Email, Then I am directed to Settings.
- **M-REP-AC-08** Given a failed report, When I tap Regenerate, Then `POST /reports/generate` is called and the screen polls again.

## 13. Open questions

1. Open/share the PDF on the phone (needs `open_filex`/`share_plus`) — deferred to the cosmetic phase.

# Feature Spec — `calendar_connect` (mobile)

> Flutter feature · Governed by [`constitution.md`](../../../../constitution.md) P6 and [`plan.md`](../../../../plan.md) §8.5, ADR-007.
> Reads Google Calendar **only when I tap "Use Google Calendar for today"**, for that one day, on the phone.
> The Google token is never sent to the backend and never stored; no refresh token is requested.

## 1. Purpose & scope

| Capability | Role |
|---|---|
| C4 | Per-day consented import of Google Calendar events → `PUT /schedule/calendar/{date}`; forget → `DELETE` |

Out of scope: background sync, writing to Google Calendar, other calendar providers, multi-day import.

## 2. Folder layout

```
features/calendar_connect/
├── spec.md
├── data/
│   ├── google_calendar_source.dart   # google_sign_in + googleapis CalendarApi (events.list)
│   └── calendar_import_api.dart      # PUT/DELETE /schedule/calendar/{date}
├── domain/
│   ├── normalize.dart                # pure: Google Event → CalendarEventIn JSON (§8.2)
│   └── import_use_case.dart          # orchestration (§8.1)
└── presentation/
    ├── calendar_consent_card.dart    # widget on Today header (exported to tasks)
    └── providers.dart
```

## 3. Dependencies

- Features: `app_shell` (`apiClientProvider`, `AppError`, `appLocationProvider`, `LocalDate`, `clockProvider`),
  `tasks` (`currentDayControllerProvider.refresh()` after import).
- Packages: `google_sign_in`, `googleapis` (calendar/v3), `extension_google_sign_in_as_googleapis_auth`
  (authenticated http client from the sign-in), flutter_riverpod.

## 4. Local data

Secure storage key `calendar.imported.<yyyy-mm-dd>` = `{count, imported_at}` (no titles) — only to show
"Calendar used today · 3 events" after restarts. Cleared by "Forget". No Google tokens persisted (the plugin's own
session is signed out after each import, §8.1 step 7).

## 5. Public interface

```dart
class CalendarConsentCard extends ConsumerWidget { const CalendarConsentCard({required this.date}); final LocalDate date; }

final calendarImportProvider = AsyncNotifierProvider.family<CalendarImportController, CalendarImportState, LocalDate>(...);
//   Future<void> importToday();   Future<void> forget();
sealed class CalendarImportState {}   // NotImported | Importing(step) | Imported(count, importedAt) | ImportFailed(AppError|GoogleAuthError)
```

## 6. Backend endpoints used

| Endpoint | Request | Response |
|---|---|---|
| `PUT /api/v1/schedule/calendar/{date}` | `{"events":[{external_id, title, all_day, start_at?, end_at?, start_date?, end_date?, show_as_free}]}` (0..200) | 200 import result (count) |
| `DELETE /api/v1/schedule/calendar/{date}` | — | 204 |

## 7. Screens & UX flow

`CalendarConsentCard` on the Today header (only for the open day, state `open`):
- **NotImported:** "Use Google Calendar for today?" · subtitle "Reads today's events once to check for clashes. Nothing
  is stored with Google access." · button **Use calendar**.
- **Importing:** progress with step text ("Signing in…", "Reading today's events…", "Saving…").
- **Imported:** "Calendar used · 3 events (imported 09:12)" · actions **Refresh** (re-import, same consent flow) and
  **Forget** (DELETE + clear local marker).
- **ImportFailed:** short message + Retry.
Closed day → card hidden.

## 8. Behaviour & rules

### 8.1 Import use case (each tap = fresh consent)
1. `GoogleSignIn(scopes: ['https://www.googleapis.com/auth/calendar.readonly'])` — no `serverClientId`, no
   server auth code (so no refresh token reaches anyone).
2. `signIn()` → account picker / consent screen. Cancel → back to NotImported (no error toast).
3. `authenticatedClient()` → `CalendarApi(client)`.
4. Day bounds from `appLocationProvider`: `timeMin = local 00:00`, `timeMax = next local 00:00` (RFC 3339 with offset).
5. `events.list('primary', timeMin, timeMax, singleEvents: true, orderBy: 'startTime', maxResults: 250,
   showDeleted: false)`; follow `nextPageToken` up to 2 pages.
6. Normalize (§8.2) → `PUT /schedule/calendar/{date}` → on success store the local marker, refresh Today data
   (feasibility now sees the events).
7. **Always** `googleSignIn.disconnect()` (revokes the grant) in a `finally`, falling back to `signOut()` if
   disconnect fails. Next import shows consent again — this is intentional per P6.

### 8.2 Normalization (`normalize.dart`, pure)
| Google event | Result |
|---|---|
| `status == cancelled` | skip |
| attendee `self == true` with `responseStatus == declined` | skip |
| `start.dateTime` present | `all_day=false`, `start_at/end_at` = ISO with offset |
| `start.date` present | `all_day=true`, `start_date`, `end_date` (exclusive) |
| `transparency == transparent` | `show_as_free=true` |
| `summary` missing | `title = ""` (server stores encrypted) |
| `external_id` | `event.id` |
Events partly outside the day are clipped server-side; duplicates by id removed client-side. Max 200 events sent.
Only title, times and ids leave the phone — no attendees, descriptions, locations.

### 8.3 Forget
`DELETE /schedule/calendar/{date}` → clear marker → refresh Today.

## 9. Platform configuration (Google Cloud — one-time, free)

1. Create a Google Cloud project → enable **Google Calendar API**.
2. OAuth consent screen: External, **Testing** mode, add your own Google account as test user; scope
   `calendar.readonly`. (Testing mode is fine for a single user; sensitive-scope verification not needed.)
3. Create **Android OAuth client IDs**: package name (e.g. `com.<you>.dailyassistant`) + SHA-1 of the **debug**
   keystore and another for the **release** keystore (plan §14.1): `keytool -list -v -keystore <file> -alias <alias>`.
4. No `google-services.json` / Firebase needed for `google_sign_in` on Android with this setup (verify with the
   plugin version in use; if required, add it without enabling other Firebase services).
5. No changes to `AndroidManifest.xml` beyond `INTERNET`.

## 10. Errors & offline behaviour

| Case | Behaviour |
|---|---|
| Offline | button disabled: "Needs internet" |
| `PlatformException(sign_in_failed, …10…)` (DEVELOPER_ERROR) | "Google sign-in isn't configured for this build (check SHA-1)" |
| User cancels | silent return to NotImported |
| Calendar API 401/403 | ImportFailed "Calendar permission was not granted" |
| Backend 422 | ImportFailed with server detail; nothing stored |
| Backend cold start | `WakingServerBanner`; ApiClient retries |
In every case the Google session is disconnected (§8.1 step 7).

## 11. Testing plan

Unit (`normalize`): `skips_cancelled`, `skips_declined_by_self`, `timed_event_iso_with_offset`, `all_day_dates_exclusive_end`,
`transparent_sets_show_as_free`, `missing_summary_empty_title`, `dedupes_by_id`, `caps_at_200`.
Use case (mocked GoogleSignIn, CalendarApi, ApiClient): `import_happy_path_puts_events_and_disconnects`,
`cancel_sign_in_no_api_calls`, `api_error_still_disconnects`, `forget_calls_delete_and_clears_marker`,
`day_bounds_use_app_timezone`.
Widget: `card_states_render`, `card_hidden_when_day_closed`.

## 12. Acceptance criteria

- **M-CAL-AC-01** Given the open day, When I tap Use calendar and consent, Then today's events are sent with `PUT /schedule/calendar/{date}` and the card shows the count.
- **M-CAL-AC-02** After any import attempt (success or failure), the Google grant is disconnected and no token is stored or sent to the backend.
- **M-CAL-AC-03** Without my tap, the app never calls Google APIs.
- **M-CAL-AC-04** Cancelled and declined events are not imported; only id, title and times are sent.
- **M-CAL-AC-05** When I tap Forget, Then `DELETE /schedule/calendar/{date}` is called and the card returns to NotImported.
- **M-CAL-AC-06** After import, the Today screen is refreshed so new feasibility checks consider the events.

## 13. Open questions

None. Decided 2026-11-09: **strict** — `disconnect()` after every import, so Google asks for consent every time I use the calendar.

# mobile/app_shell — Spec

> Governed by `constitution.md` (P1, P4, P5, P12) and `plan.md` (§2.2, §3.2, §6.1, §7, §8.3, §12.2, §14, §15).
> app_shell is the **composition root** of the Flutter app: it owns bootstrap, configuration, the HTTP client,
> authentication, routing, the shared drift database + offline outbox, settings and lifecycle hooks.

## 1. Purpose & scope

| Capability | Contribution |
|---|---|
| C1 | Email + password login, JWT storage, logout, 401 handling |
| (all) | API client, error model, cold-start handling, routing, shared DB, outbox, lifecycle, settings |

In scope: `main.dart`, `ProviderScope`, timezone init, `AppConfig` from `--dart-define`, dio client + interceptors,
RFC 7807 → `AppError`, login screen, go_router + guards, bottom navigation shell (Today, Chat, Reports, Settings),
settings screen (timezone sync, report email, logout, links to schedule editor / battery guidance), drift
`AppDatabase` (all tables, migrations), offline outbox, app lifecycle coordinator, shared state widgets, minimal theme.

Out of scope: sign-up, password reset, OAuth, 2FA, multi-user (P1); editing reminder offsets (P5 fixes T-60/T-30 —
shown read-only); themes/polish (plan §18); any API key in the app (P12).

## 2. Folder layout

```
lib/
├── main.dart                         # bootstrap(); runApp(ProviderScope(child: App()))
└── features/app_shell/
    ├── data/
    │   ├── app_config.dart           # AppConfig.fromEnvironment()
    │   ├── api_client.dart           # ApiClient (wraps Dio), dioFactory(config, tokenStore, hooks)
    │   ├── interceptors/
    │   │   ├── auth_interceptor.dart     # Bearer header; 401 → onUnauthorized
    │   │   ├── retry_interceptor.dart    # cold-start retry/backoff
    │   │   └── waking_interceptor.dart   # reports in-flight latency to ServerStatusNotifier
    │   ├── problem_mapper.dart       # DioException / problem+json → AppError
    │   ├── token_store.dart          # flutter_secure_storage wrapper (isolate-safe, no Riverpod)
    │   ├── auth_api.dart             # POST /auth/login
    │   ├── settings_api.dart         # GET/PATCH /settings
    │   ├── db/
    │   │   ├── app_database.dart     # @DriftDatabase(tables: [...all features]) + migrations
    │   │   ├── outbox_table.dart     # OutboxEntries
    │   │   ├── kv_table.dart         # AppKv (small non-secret flags)
    │   │   └── outbox_dao.dart
    │   └── dto/                      # TokenDto, SettingsDto, SettingsPatchDto, ProblemDto (freezed)
    ├── domain/
    │   ├── app_error.dart            # sealed AppError
    │   ├── local_date.dart           # LocalDate value type (ISO yyyy-MM-dd)
    │   ├── clock.dart                # Clock interface + SystemClock
    │   ├── app_settings.dart         # AppSettings entity
    │   ├── auth_state.dart           # sealed AuthState
    │   ├── outbox_sender.dart        # OutboxSender.flush() — pure-ish, usable from background isolate
    │   └── backoff.dart              # backoffDelay(attempt, rnd) — pure
    └── presentation/
        ├── app.dart                  # MaterialApp.router, theme
        ├── router.dart               # GoRouter, routes, redirect guard
        ├── shell_scaffold.dart       # bottom NavigationBar (4 tabs) + WakingServerBanner
        ├── login_screen.dart
        ├── settings_screen.dart
        ├── lifecycle_coordinator.dart# AppLifecycleListener → ordered LifecycleHooks
        ├── providers.dart            # all public providers (see §5)
        └── widgets/
            ├── async_value_view.dart # loading / waking / error / empty / content convention
            ├── waking_server_banner.dart
            ├── error_view.dart
            └── empty_view.dart
```

## 3. Dependencies

Other features (public API only; consumed **only** in `main.dart` / `router.dart` / `lifecycle_coordinator.dart`
as composition root): screens and route builders of tasks, chat, reports, schedule, notifications; drift table
classes of tasks, notifications and chat (registered in `AppDatabase`); `LifecycleHook` implementations from tasks,
notifications.

Pub packages (pin exact versions at implementation, stable channel):

| Package | Use |
|---|---|
| flutter_riverpod | state (manual `Provider`/`Notifier`/`AsyncNotifier`; no codegen) |
| go_router | routing, `StatefulShellRoute.indexedStack` |
| dio | HTTP |
| freezed, freezed_annotation, json_serializable, json_annotation, build_runner (dev) | DTOs/entities |
| flutter_secure_storage | JWT |
| drift, drift_flutter (sqlite3 + path), drift_dev (dev) | DB |
| timezone, flutter_timezone | tz database, device IANA zone |
| uuid | idempotency keys |
| intl | date/time formatting |
| mocktail, http_mock_adapter (dev) | tests |

## 4. Local data

### 4.1 Secure storage (owned) — `TokenStore`
| Key | Value |
|---|---|
| `auth.jwt` | access token |
| `auth.expires_at` | ISO-8601 UTC |
| `auth.email` | last login email (prefill only) |

`TokenStore` uses one constant `AndroidOptions` instance (shared with the background isolate) and exposes
`read() → StoredToken?`, `write(token, expiresAt, email)`, `clear()`. A token with `expiresAt <= now + 60 s` is
treated as absent.

### 4.2 drift — `AppDatabase` (single SQLite file `daily_assistant.sqlite`)
Owned tables:

`outbox_entries`
| Column | Type | Notes |
|---|---|---|
| id | int PK autoincrement | FIFO order |
| idempotency_key | text unique | uuid v4, sent as `Idempotency-Key` header |
| method | text | `POST` only in v1 |
| path | text | e.g. `/tasks/{id}/check-response` |
| body_json | text | |
| label | text | human text for failure snackbar (on-device only) |
| created_at | datetime (UTC) | |
| attempts | int default 0 | |
| next_attempt_at | datetime nullable | |
| state | text | `pending`, `dead` (sent rows are deleted) |
| last_error | text nullable | |

`app_kv` — `key text PK, value text`: `tz.synced` (`'1'`), `battery_guide.shown`, `notif_perm.asked`.

Feature tables registered here (defined in their features): tasks → `cached_days`, `cached_tasks`;
notifications → `notification_followups`, `pending_finish_questions`; chat → `proposal_outcomes`.

Connection: `driftDatabase(name: 'daily_assistant')`; on open `PRAGMA journal_mode=WAL; PRAGMA busy_timeout=5000;`
(the notification background isolate opens a second connection). `AppDatabase.open()` is a static factory usable
without Riverpod.

Migrations: `schemaVersion = 1`; `MigrationStrategy(onCreate: m.createAll(), onUpgrade: stepByStep(...))`; schema
snapshots exported with `dart run drift_dev make-migrations` into `mobile/drift_schemas/`; every schema change in any
feature bumps the version **here** and adds a step + generated migration test. Cached data (`cached_*`) may be
dropped and recreated in a migration; outbox and notification tables must be migrated preserving rows.

## 5. Public interface

```dart
// config
class AppConfig { final Uri apiBaseUrl; static AppConfig fromEnvironment(); } // throws StateError if empty
final appConfigProvider = Provider<AppConfig>(...);

// time
class LocalDate implements Comparable<LocalDate> { final int year, month, day;
  factory LocalDate.parse(String iso); String toIso(); LocalDate addDays(int n);
  static LocalDate fromTz(DateTime utc, tz.Location loc);
  tz.TZDateTime startOf(tz.Location loc); tz.TZDateTime endExclusive(tz.Location loc); } // next local midnight
abstract interface class Clock { DateTime nowUtc(); }
final clockProvider = Provider<Clock>((_) => const SystemClock());
final appLocationProvider = Provider<tz.Location>(...); // location of AppSettings.timezone (fallback tz.local)

// errors
sealed class AppError implements Exception { String get userMessage; }
final class NetworkError extends AppError {}            // offline / DNS / connection refused
final class ServerWakingTimeout extends AppError {}     // retries exhausted on cold start
final class UnauthorizedError extends AppError {}       // 401
final class NotFoundError extends AppError {}           // 404
final class ConflictError extends AppError { final String? code; final String? detail; }        // 409
final class ValidationError extends AppError { final Map<String, String> fieldErrors; final String? detail; } // 400/422
final class ServerError extends AppError { final int status; final String? detail; }           // 5xx
final class UnknownError extends AppError { final Object cause; }

// http
class ApiClient {
  Future<T> get<T>(String path, {Map<String, dynamic>? query, required T Function(Object? json) decode});
  Future<T> post<T>(String path, {Object? body, String? idempotencyKey, required T Function(Object? json) decode});
  Future<T> put<T>(...); Future<T> patch<T>(...); Future<void> delete(String path);
  Future<Uint8List> getBytes(String path);   // report assets
}  // all methods throw AppError only
final apiClientProvider = Provider<ApiClient>(...);
Dio buildDio({required AppConfig config, required TokenStore tokens, void Function()? onUnauthorized,
              ServerStatusSink? status});      // also used by background isolate

// server status
enum ServerStatus { ok, waking, offline }
final serverStatusProvider = NotifierProvider<ServerStatusNotifier, ServerStatus>(...);

// auth
sealed class AuthState { } // AuthUnknown, Unauthenticated({String? reason}), Authenticated({DateTime expiresAt})
final authControllerProvider = AsyncNotifierProvider<AuthController, AuthState>(...);
//   Future<void> login(String email, String password); Future<void> logout({String? reason});
final tokenStoreProvider = Provider<TokenStore>(...);

// settings
@freezed class AppSettings { String timezone; List<int> reminderOffsetsMin; String? reportEmail; int weekStart; }
final settingsControllerProvider = AsyncNotifierProvider<SettingsController, AppSettings>(...);
//   Future<void> setReportEmail(String? email); Future<void> syncTimezoneFromDevice();

// db + outbox
final appDatabaseProvider = Provider<AppDatabase>(...);
class OutboxService { Future<void> enqueue(OutboxRequest r); Future<OutboxFlushResult> flush(); }
@freezed class OutboxRequest { String path; Map<String, Object?> body; String label; }
final outboxServiceProvider = Provider<OutboxService>(...);
final outboxFailuresProvider = StreamProvider<List<OutboxFailure>>(...); // dead entries for snackbar

// lifecycle
abstract interface class LifecycleHook { int get order; Future<void> onLaunchOrResume(Ref ref); }
final lifecycleHooksProvider = Provider<List<LifecycleHook>>(...); // composed in main.dart

// UI conventions
class AsyncValueView<T> extends ConsumerWidget { /* value, data, isEmpty, empty, onRetry */ }
```

## 6. Backend endpoints used

| Method & path | Request | Response | Notes |
|---|---|---|---|
| `GET /health` | — | `200` | warm-up ping at launch (public, fire-and-forget) |
| `POST /auth/login` | `{email, password}` | `{access_token, expires_at}` | public; 401 → "Wrong email or password" |
| `GET /settings` | — | `{timezone, reminder_offsets_min, report_email, week_start}` | after login + on settings open |
| `PATCH /settings` | any subset of `{timezone, report_email}` | settings | `report_email: null` clears |

Base URL = `AppConfig.apiBaseUrl` + `/api/v1` (except `/health`, which is at the root per plan §7 listing — see Q1).

## 7. Screens & UX flow

### 7.1 Bootstrap (`main.dart`)
```
WidgetsFlutterBinding.ensureInitialized()
AppConfig.fromEnvironment()                 // fail fast with a red error screen if API_BASE_URL missing
tz_data.initializeTimeZones(); tz.setLocalLocation(tz.getLocation(await FlutterTimezone.getLocalTimezone()))
final db = AppDatabase.open()
await NotificationsBootstrap.initialize(onResponse: ...)   // from notifications feature (channels, callbacks)
final launchResponse = await NotificationsBootstrap.launchDetails()
runApp(ProviderScope(overrides: [appDatabaseProvider.overrideWithValue(db), ...], child: App(launch: launchResponse)))
unawaited(dio.get('/health'))               // warm the Render instance early
```
`AuthController.build()` reads `TokenStore`; valid token → `Authenticated`, else `Unauthenticated`.

### 7.2 Routes (go_router)

| Path | Screen | Owner |
|---|---|---|
| `/splash` | spinner while `AuthUnknown` | app_shell |
| `/login` | LoginScreen | app_shell |
| `/today` (tab 0) | TodayScreen | tasks |
| `/today/new`, `/today/task/:id/edit`, `/today/templates` | add/edit, templates | tasks |
| `/today/calendar` | CalendarConsentSheet (modal page) | calendar_connect |
| `/chat` (tab 1) | ChatScreen | chat |
| `/reports` (tab 2), `/reports/:id` | list, viewer | reports |
| `/eod` | EodResolutionScreen | reports |
| `/settings` (tab 3) | SettingsScreen | app_shell |
| `/settings/schedule`, `/settings/schedule/free-slots` | schedule editor, preview | schedule |
| `/settings/battery` | BatteryGuideScreen | notifications |
| `/check/:taskId/eta`, `/check/:taskId/finish` | ETA sheet, "When did you finish?" | notifications |

Shell: `StatefulShellRoute.indexedStack` with 4 branches; `NavigationBar` labels Today, Chat, Reports, Settings.

Guard (`redirect`, `refreshListenable` = auth state stream):
1. `AuthUnknown` → `/splash`.
2. `Unauthenticated` and location ≠ `/login` → `/login` (remember `from` query param).
3. `Authenticated` and location ∈ {`/login`, `/splash`} → `from` ?? `/today`.

Deep links from notifications (`/check/...`) are buffered while unauthenticated and replayed after login.

### 7.3 LoginScreen
Fields: email (prefilled from `auth.email`, keyboard `emailAddress`, required, contains `@`), password (obscured,
required). Button "Log in" disabled while submitting.
States: idle · submitting ("Logging in…") · waking (`ServerStatus.waking` → "Waking server… this can take up to a
minute") · error (inline: wrong credentials / offline / server unavailable with Retry). No sign-up link (P1).
On success: `TokenStore.write` → `AuthController` = Authenticated → post-login task (§8.4) → `/today`.

### 7.4 SettingsScreen
Sections:
1. **Account** — logged-in email, "Log out" (confirm sheet → `logout()`).
2. **Time zone** — server zone; device zone; if different: "Use device time zone (Europe/…)" button → PATCH.
3. **Reminders** — read-only text "1 hour and 30 minutes before start; one completion check" from
   `reminder_offsets_min`.
4. **Report email** — text field + Save; validation `^[^@\s]+@[^@\s]+\.[^@\s]+$` or empty (= clear). Helper:
   "Reports are only emailed when you tap 'Email this report'." Reports deep link `/settings?focus=report_email`
   autofocuses this field.
5. **Schedule** — "Weekly fixed schedule" → `/settings/schedule`.
6. **Notifications** — permission status rows (from notifications feature) + "Battery optimisation guide".
7. **About** — version (`package_info` is not used; show `const String.fromEnvironment('APP_VERSION')` or omit), API
   base URL host.

### 7.5 State conventions (`AsyncValueView`)
| State | Rendering |
|---|---|
| loading (< 3 s) | centered `CircularProgressIndicator` |
| waking (`ServerStatus.waking` while loading) | progress + "Waking server… this can take up to a minute" |
| error | `ErrorView`: icon, `AppError.userMessage`, "Retry" button |
| empty | `EmptyView`: one line + optional primary action |
| content | child; refresh keeps old content visible with a `LinearProgressIndicator` on top |
`WakingServerBanner` (in shell scaffold) shows for any request when status = waking; offline banner "Offline —
changes to notifications answers will sync later" when status = offline.

## 8. Behaviour & rules

### 8.1 Dio configuration
- `baseUrl = '$apiBaseUrl/api/v1'`; `connectTimeout 20 s`, `sendTimeout 30 s`, `receiveTimeout 75 s` (Render holds
  requests during spin-up; feasibility/assistant calls may take ~25 s server-side).
- Headers: `Accept: application/json, application/problem+json`; `Authorization: Bearer <jwt>` for every path except
  `/auth/login`, `/health`.
- Interceptor order: `WakingInterceptor` → `AuthInterceptor` → `RetryInterceptor` → (LogInterceptor in debug only,
  bodies **not** logged — personal text).

### 8.2 Retry / cold start (`RetryInterceptor`)
Retryable when: connection error, connect/receive timeout, HTTP 502/503/504 (Render returns these during
spin-up/deploys). Retry applies to GET/PUT/DELETE/PATCH, and to POST **only** if the request carries an
`Idempotency-Key` header or `extra['retryable'] == true` (login, `/feasibility/assess`, `/assistant/messages` are
marked retryable: safe to repeat; see Q2).
Attempts: max 4 retries; delay = `backoffDelay(n) = min(2^n s, 16 s) + jitter(0..500 ms)` → ~2, 4, 8, 16 s; total
budget 120 s, after which `ServerWakingTimeout`. `NetworkError` (no connectivity: `SocketException` host lookup
failure) is **not** retried more than once.

### 8.3 Waking detection
`WakingInterceptor` starts a 3 s timer per request; if no response by then, or a retry is scheduled →
`ServerStatus.waking`. On any 2xx/4xx response → `ok`. On `NetworkError` → `offline`. Counter-based (status = waking
while ≥ 1 slow request in flight).

### 8.4 Auth
- 401 on any request except `/auth/login` → `TokenStore.clear()` → `AuthController.logout(reason: 'Session expired —
  please log in again')` → guard sends to `/login`. Concurrent 401s trigger one logout (guard flag).
- Token expiry checked at launch and on resume; expired → logout (no refresh tokens, plan §6.1).
- Post-login: `GET /settings`; if `app_kv['tz.synced']` absent → `PATCH /settings {timezone: device IANA}` → set
  flag. Then `lifecycle.onLaunchOrResume`.
- Logout: clear token, `cancelAll` notifications (via notifications public API), clear `cached_*` tables, keep outbox
  rows (sent after next login), keep `tz.synced`.

### 8.5 Problem mapping
Body `application/problem+json` `{type, title, status, detail, instance, ...ext}` → `AppError` by status (table in §5).
`ConflictError.code` = `ext['code']` if present, else last path segment of `type` (e.g.
`.../report-email-not-configured` → `report-email-not-configured`). 422 FastAPI bodies `{detail:[{loc,msg}]}` →
`ValidationError.fieldErrors[loc.last] = msg`. Non-JSON bodies → status-based error with null detail.

### 8.6 Outbox
- Used for requests that must survive being offline: `POST /tasks/{id}/check-response`, `POST /tasks/{id}/status`
  (only when initiated from notifications or when offline at tap time). Task creation, chat, EOD close are
  online-only.
- `enqueue` inserts a row with a fresh uuid `idempotency_key`; callers then call `flush()`.
- `flush()` (single-flight; a mutex row-lock via `app_kv['outbox.lock']` with 60 s expiry so the background isolate
  and UI isolate don't double-send): iterate `pending` rows by `id` ascending:
  - 2xx → delete row.
  - `NetworkError`/`ServerWakingTimeout`/5xx → `attempts++`, `next_attempt_at = now + backoff`, **stop** (FIFO).
  - 401 → stop, keep row (sent after re-login).
  - 409 → delete row (state already changed elsewhere; logged as superseded).
  - 400/404/422 → `state = dead`, `last_error`; continue with next row; surfaced via `outboxFailuresProvider`
    snackbar "Couldn't sync: <label>" with Dismiss (deletes row).
- Triggers: after enqueue, on launch/resume, on connectivity regained (a successful request after `offline`).

### 8.7 Lifecycle coordinator
`AppLifecycleListener(onResume)` + first frame after auth. Throttle: skip if last run < 30 s ago (manual pull-to-refresh
bypasses). Runs hooks sequentially by `order`:
| order | hook (owner) | action |
|---|---|---|
| 10 | token check (app_shell) | expired → logout, abort chain |
| 20 | outbox flush (app_shell) | `flush()` |
| 30 | current day refresh (tasks) | `GET /days/current` + `GET /tasks?date=` |
| 40 | notifications reconcile (notifications) | cancel + reschedule from day state |
| 50 | pending questions (notifications) | open "When did you finish?" if a row exists |
A hook failure is logged and does not abort later hooks (except order 10).

### 8.8 Theme
`ThemeData(useMaterial3: true, colorSchemeSeed: Colors.indigo)`, light + dark following system. Status chip colours
defined once in `AppStatusColors` extension (planned grey, completed green, postponed amber, cancelled outline,
cant_do red-ish, missed dark grey).

## 9. Platform configuration
- `android/app/build.gradle(.kts)`: `minSdk = 26`, `targetSdk`/`compileSdk` = latest stable supported by Flutter,
  `applicationId = "<chosen package>"` (also used for the Google OAuth client, see calendar_connect), release
  `signingConfig` from `key.properties` (git-ignored) or CI env (plan §14.1), core library desugaring enabled
  (required by flutter_local_notifications).
- `AndroidManifest.xml`: `<uses-permission android:name="android.permission.INTERNET"/>` (release builds don't add it
  implicitly); remaining permissions/receivers owned by notifications spec. `android:usesCleartextTraffic` not set
  (HTTPS only).
- Build: `flutter build apk --release --dart-define=API_BASE_URL=https://<service>.onrender.com`. Missing define →
  bootstrap error screen "API_BASE_URL not configured".
- `pubspec.yaml` `version: X.Y.Z+N` (plan §14.4).

## 10. Errors & offline behaviour
| Situation | Behaviour |
|---|---|
| Cold start | waking banner; retries ≤ 120 s; then ErrorView "Server didn't wake up. Retry" |
| Offline | offline banner; cached Today (from tasks' drift cache) shown read-only-ish; outbox queues answers |
| 401 | logout → login screen with reason |
| 5xx | ErrorView with Retry; no automatic infinite loops |
| Secure storage read failure (keystore reset after restore) | treat as logged out; clear storage |
| DB open failure | fatal error screen with "Clear local data" (deletes SQLite file; server data unaffected) |

## 11. Testing plan
Unit (`test/features/app_shell/...`, mocktail, fake `Clock`):
- `backoff_test`: delays for attempts 0..5, cap 16 s, jitter bounds.
- `problem_mapper_test`: 400, 401, 404, 409 with `code` ext, 409 with `type` only, 422 FastAPI list, 500 non-JSON,
  connection error, timeout.
- `local_date_test`: parse/format, `endExclusive` across DST change (Europe/Bucharest last Sunday of October).
- `token_store_test`: expired within 60 s treated as absent.
Integration-style (dio + `http_mock_adapter`):
- `auth_interceptor_test`: header added; omitted for `/auth/login`; 401 → single logout for 3 parallel requests.
- `retry_interceptor_test`: 503,503,200 → success after 2 retries; POST without key not retried; budget exhausted →
  `ServerWakingTimeout`; status passes through `waking` → `ok`.
- `outbox_test` (drift in-memory `NativeDatabase.memory()`): FIFO order, stop on network error, 409 deletes, 422
  marks dead and continues, same `Idempotency-Key` on replay, lock prevents concurrent flush.
- `migration_test`: generated drift schema tests v1.
Widget:
- `login_screen_test`: validation, submitting state, wrong credentials message, waking message, success navigates.
- `settings_screen_test`: tz mismatch button, report email validation + PATCH, logout confirm.
- `router_guard_test`: unknown→splash, unauth→login, auth at login→today, `from` restored.
- `async_value_view_test`: each state.
Golden: `login_screen` (idle, error), `settings_screen` (light).

## 12. Acceptance criteria
- **M-SHELL-AC-01** Given no stored JWT, When the app launches, Then the login screen is shown and no authenticated
  request is made.
- **M-SHELL-AC-02** Given valid credentials, When I tap Log in, Then `POST /auth/login` is called, the token and
  expiry are stored in secure storage, and Today is shown.
- **M-SHELL-AC-03** Given wrong credentials (401), When I tap Log in, Then "Wrong email or password" is shown and I
  stay on login.
- **M-SHELL-AC-04** Given I'm logged in, When any request returns 401, Then the token is cleared and I land on
  login with "Session expired".
- **M-SHELL-AC-05** Given the server is asleep, When a request takes > 3 s or gets 503, Then "Waking server…" is
  shown and the request is retried with backoff for up to 120 s.
- **M-SHELL-AC-06** Given the first successful login, When `tz.synced` is absent, Then `PATCH /settings` sends the
  device IANA zone exactly once.
- **M-SHELL-AC-07** Given an error response in problem+json, When mapped, Then the typed `AppError` subtype matches
  the status and carries `detail`/`code`.
- **M-SHELL-AC-08** Given queued outbox entries A then B and the network is back, When flush runs, Then A is sent
  before B, each with its stored `Idempotency-Key`, and sent rows are deleted.
- **M-SHELL-AC-09** Given the app returns to foreground, When ≥ 30 s since last run, Then outbox flush, day refresh,
  notification reconcile and pending-question check run in that order.
- **M-SHELL-AC-10** Given I enter a report email, When I save, Then `PATCH /settings {report_email}` is sent and the
  value is shown; invalid formats are rejected client-side.
- **M-SHELL-AC-11** Given I log out, Then token, cached day data and all scheduled notifications are removed.
- **M-SHELL-AC-12** Given the APK was built without `API_BASE_URL`, When launched, Then a configuration error screen
  is shown.
- **M-SHELL-AC-13** The bottom navigation shows exactly Today, Chat, Reports, Settings and preserves each tab's
  stack.

## 13. Open questions
| # | Question | Proposed default |
|---|---|---|
| Q1 | Is `/health` mounted at the root or under `/api/v1`? (plan §7 lists it in the `/api/v1` table) | call `${base}/health`; adjust after backend core spec |
| Q2 | Backend support for `Idempotency-Key` on POSTs (outbox replay, retries) is not in plan §7 | request backend core to store key → response for 24 h; until then, outbox treats 409 as success |
| Q3 | Should a timezone mismatch after first login be auto-synced (travel)? | no; show button in Settings + banner on Today |
| Q4 | `AppSettings.reminder_offsets_min` is editable server-side but P5 fixes T-60/T-30 | read-only in app; use first two values |

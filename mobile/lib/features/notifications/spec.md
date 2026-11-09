# mobile/notifications — Spec

> Governed by `constitution.md` (**P5** attention, P9 learn from data, P10) and `plan.md` (§8.2, ADR-002, §14.5, §15).
> Device-local reminders and completion checks. The server is never involved in *when* a notification fires; it only
> receives the answers.

## 1. Purpose & scope

| Capability | Contribution |
|---|---|
| C5 | Reminders at T-60 and T-30 before each timed task's start |
| C6 | Exactly **one** completion check at `predicted_end_at` (Done / Not yet) + "When did you finish?" for late Done |
| C8 | Nothing fires after local midnight; EOD cancels everything |

In scope: pure scheduling rules, deterministic IDs, reconcile, flutter_local_notifications setup (channels,
`zonedSchedule`, actions, foreground + background handlers), late-Done flow, user-requested follow-up, permissions,
manifest, reboot persistence, battery-optimisation guidance, notification texts.

Out of scope: server push (none exists), repeated/escalating prompts (forbidden by P5), notifications for anytime
tasks, scheduling for days other than the open day (Q1), notification sounds customisation.

**Attention budget per task (hard limit):** ≤ 2 reminders + ≤ 1 automatic completion check. A follow-up (slot 3) only
exists after the user explicitly picked an ETA; the "When did you finish?" notification only appears as a direct
response to the user's own late Done tap and replaces the check in place.

## 2. Folder layout

```
features/notifications/
├── data/
│   ├── db/
│   │   ├── notification_tables.dart   # NotificationFollowups, PendingFinishQuestions
│   │   └── notification_dao.dart
│   ├── local_notifications_gateway.dart # thin wrapper over FlutterLocalNotificationsPlugin (mockable)
│   ├── notifications_bootstrap.dart     # initialize(), channels, launchDetails()
│   ├── background_handler.dart          # @pragma('vm:entry-point') notificationBackgroundHandler
│   ├── background_deps.dart             # builds TokenStore + AppDatabase + Dio without Riverpod
│   └── permission_service.dart          # POST_NOTIFICATIONS, exact alarms, enabled checks
├── domain/
│   ├── notification_planner.dart        # PURE: plan(PlannerInput) → List<DesiredNotification>
│   ├── notification_ids.dart            # PURE: fnv1a32, idFor(taskId, slot), collision probing
│   ├── notification_payload.dart        # PURE: encode/decode payload JSON
│   ├── notification_texts.dart          # PURE: titles/bodies (formatter injected)
│   ├── reconcile_diff.dart              # PURE: diff(pending, active, desired, state) → ReconcileOps
│   └── response_processor.dart          # PURE-ish: NotificationResponse → effects (ports injected)
└── presentation/
    ├── reconciler.dart                  # NotificationReconciler (uses gateway + diff), single-flight
    ├── notification_sync.dart           # listens to currentDayControllerProvider/settings → reconcile
    ├── eta_sheet.dart                   # /check/:taskId/eta
    ├── finish_time_screen.dart          # /check/:taskId/finish
    ├── permission_card.dart             # Today/Settings card when notifications are off
    ├── battery_guide_screen.dart        # /settings/battery
    └── providers.dart
```

## 3. Dependencies

| Feature | Used |
|---|---|
| app_shell | `AppDatabase`, `TokenStore`, `buildDio`, `OutboxService`/`OutboxSender`, `clockProvider`, `appLocationProvider`, `settingsControllerProvider` (`reminderOffsetsMin`, `timezone`), `LocalDate`, `LifecycleHook`, app_kv |
| tasks | `currentDayControllerProvider` (`TodayState`), `Task`, `Day`, `TaskStatus`, `CheckResponse`, `tasksRepositoryProvider.checkResponse` (foreground only) |

Packages: flutter_local_notifications (pin latest stable; API below assumes ≥ 19), timezone, flutter_timezone,
drift, dio, flutter_secure_storage, android_intent_plus (battery/app settings intents), intl.

## 4. Local data (drift, registered in `AppDatabase`)

`notification_followups` — at most one per task
| Column | Type | Notes |
|---|---|---|
| task_id | text PK | |
| local_date | text | open day it belongs to |
| fire_at | datetime UTC | `requested_at + eta_min` |
| eta_min | int | 15 / 30 / 60 |
| requested_at | datetime UTC | |

`pending_finish_questions` — late Done awaiting "When did you finish?"
| Column | Type | Notes |
|---|---|---|
| task_id | text PK | |
| title | text | for UI without network |
| start_at | datetime UTC nullable | lower bound for "Pick" |
| fired_at | datetime UTC | scheduled fire time of the tapped notification |
| tapped_at | datetime UTC | Done tap time |
| slot | int | 2 or 3 (notification id reused) |

Both tables are written by the UI isolate **and** the background isolate (WAL + busy_timeout, app_shell §4.2).
app_kv keys used: `notif_perm.asked`, `battery_guide.shown`.

## 5. Public interface

```dart
enum NotificationSlot { reminder1 /*0*/, reminder2 /*1*/, check /*2*/, followUp /*3*/ }

@freezed class TaskSnapshot { String id; String title; LocalDate localDate; TaskStatus status;
  DateTime? startAt; DateTime? predictedEndAt; CheckResponse? checkResponse; }
@freezed class FollowUp { String taskId; DateTime fireAt; int etaMin; }
@freezed class PlannerInput { LocalDate dayDate; DayState dayState; List<TaskSnapshot> tasks;
  List<FollowUp> followUps; DateTime nowUtc; tz.Location location; List<int> reminderOffsetsMin; bool exactAllowed; }
@freezed class DesiredNotification { int id; String taskId; NotificationSlot slot; tz.TZDateTime fireAt;
  String channelId; String title; String body; List<String> actionIds; DateTime timeoutAtUtc;
  AndroidScheduleMode mode; String payload; String contentHash; }

List<DesiredNotification> planNotifications(PlannerInput input, {NotificationTexts texts, IdHasher hasher});
int notificationId(String taskId, NotificationSlot slot, {IdHasher hasher});

class NotificationReconciler { Future<ReconcileReport> reconcile(); Future<void> cancelAll(); }
final notificationReconcilerProvider = Provider<NotificationReconciler>(...);
final notificationSyncProvider = Provider<void>(...);          // kept alive by App root; wires listeners
class FollowUpService { Future<FollowUpResult> request(Task task, int etaMin); }  // used by tasks StatusSheet
final followUpServiceProvider = Provider<FollowUpService>(...);
final notificationPermissionProvider = AsyncNotifierProvider<..., NotificationPermissionState>(...);
//   {bool enabled; bool exactAllowed}  + requestEnabled(), openExactAlarmSettings()
abstract final class NotificationsBootstrap {
  static Future<void> initialize({required void Function(NotificationResponse) onForeground});
  static Future<NotificationResponse?> launchResponse();
}
final class NotificationsReconcileHook implements LifecycleHook { order = 40 }
final class PendingQuestionsHook implements LifecycleHook { order = 50 }
Future<void> cancelAllForDay();   // used by reports after EOD close: cancelAll() + clear followups/questions
```

## 6. Backend endpoints used

| Method & path | Request | When |
|---|---|---|
| `POST /tasks/{id}/check-response` | `{response:"done", finished_at}` | Done (≤ 10 min) / finish-time answer |
| `POST /tasks/{id}/check-response` | `{response:"not_yet", eta_min?}` | Not yet / ETA chosen |

Always sent through the app_shell **outbox** (enqueue → flush) with an `Idempotency-Key`, from either isolate.
No other endpoint is called by this feature; task state comes from tasks' `TodayState`.

## 7. Screens & UX flow

### 7.1 Notification texts (examples; `HH:mm` 24 h in app tz)
| Slot | Channel | Title | Body | Actions |
|---|---|---|---|---|
| reminder1 (offset 60) | `reminders` | "In 1 hour: Write project report" | "Starts at 14:00 · ends ~15:10" | — |
| reminder2 (offset 30) | `reminders` | "In 30 min: Write project report" | "Starts at 14:00" | — |
| check | `checks` | "Done with Write project report?" | "It was predicted to end at 15:10." | Done · Not yet · Remind me later… |
| followUp | `checks` | "Done with Write project report now?" | "You asked to be checked at 15:40." | Done · Not yet · Remind me later… |
| finish question (replaces check/followUp in place, silent) | `checks` | "When did you finish Write project report?" | "Tap to pick a time." | At 15:10 · Just now |
Offset label: 60 → "1 hour", other n → "n min", 120 → "2 hours".

Action ids: `done` (background), `not_yet` (background), `not_yet_eta` (`showsUserInterface: true`),
`finish_at_fire` (background), `finish_now` (background). Body tap = `actionId == null` (opens app).

Notification details: `AndroidNotificationDetails(channelId, …, category: AndroidNotificationCategory.reminder,
visibility: NotificationVisibility.private, autoCancel: true, timeoutAfter: ms until timeoutAtUtc)`. `timeoutAtUtc`:
reminders → `start_at + 15 min` (capped at day end); check/followUp/finish → local midnight of the open day.

### 7.2 EtaSheet (`/check/:taskId/eta`)
"Not done yet — want one more check?" Buttons **+15 min**, **+30 min**, **+60 min**, **No follow-up**.
- ETA → `FollowUpService.request(task, eta)` → snackbar "I'll ask once more at 15:40".
- No follow-up / back / dismiss → `check-response not_yet` (no eta).
- If `now + eta ≥ day end` the option is disabled with hint "after midnight".

### 7.3 FinishTimeScreen (`/check/:taskId/finish`)
"When did you finish *Write project report*?" (from `pending_finish_questions`)
- **At 15:10** — when I was asked (`fired_at`)
- **Just now · 15:32** — `tapped_at` (label "When I tapped Done · 15:32" if opened > 5 min after tap)
- **Pick a time…** — time picker bounded `[start_at ?? day start, tapped_at]`
Confirm → outbox `done{finished_at}` → flush → delete row → cancel the finish notification → `refresh()` Today.
Back without answer keeps the row (asked again at next app open while the task's day is open).
States: content; row missing (already answered from notification) → pop silently.

### 7.4 PermissionCard
Shown on Today (top) and in Settings when `!enabled`: "Notifications are off — you won't get reminders." [Turn on]
→ `requestNotificationsPermission()`; if permanently denied → open app notification settings. Exact alarms not
allowed → Settings row "Reminders may arrive a few minutes late. [Allow exact timing]" →
`requestExactAlarmsPermission()`.

### 7.5 BatteryGuideScreen (`/settings/battery`, auto-opened once)
Opened once (app_kv `battery_guide.shown`) after the first successful reconcile that scheduled ≥ 1 notification;
always reachable from Settings. Content:
1. Why: some phones stop scheduled reminders to save battery.
2. Generic: Settings → Apps → Daily Assistant → Battery → **Unrestricted**. Button "Open app settings"
   (`android.settings.APPLICATION_DETAILS_SETTINGS`, `package:<applicationId>`); button "Open battery optimisation
   list" (`android.settings.IGNORE_BATTERY_OPTIMIZATION_SETTINGS`).
3. OEM notes (static text): Xiaomi/HyperOS — enable Autostart + "No restrictions"; Samsung — remove from "Sleeping
   apps", add to "Never sleeping apps"; OnePlus/Oppo/Realme — allow background activity / auto-launch; Huawei — App
   launch → manage manually. Reference shown as text: `dontkillmyapp.com`.
4. "Got it" closes. `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` is **not** used.

## 8. Behaviour & rules

### 8.1 Deterministic IDs
```
fnv1a32(utf8(taskId))             // offset basis 0x811C9DC5, prime 0x01000193, 32-bit
base  = fnv1a32(taskId) & 0x0FFFFFFF        // 28 bits
id    = base * 4 + slot.index               // 0 ≤ id < 2^30 (fits Android int)
```
Collision handling (within one desired set): tasks sorted by `id` (string asc); a task whose `base` is already taken
uses `base = (base + 0x9E3779B) & 0x0FFFFFFF`, repeated until free. Deterministic for a given task set; logged.

### 8.2 Planner rules (pure; `planNotifications`)
Let `loc = input.location`, `dayStart = dayDate.startOf(loc)`, `dayEnd = dayDate.endExclusive(loc)` (next local
midnight), `guard = nowUtc + 5 s` (zonedSchedule rejects past instants).
`include(t) ⇔ t > guard ∧ t < dayEnd`.

| Rule | Statement |
|---|---|
| R1 | `dayState != open` → ∅ |
| R2 | `nowUtc ≥ dayEnd` (stale day not yet refreshed) → ∅ |
| R3 | tasks with `localDate != dayDate` are ignored |
| R4 | tasks with `status != planned` are ignored (terminal statuses cancel) |
| R5 | tasks with `startAt == null` (anytime) get nothing |
| R6 | reminders: offsets = first **two** distinct positive values of `reminderOffsetsMin` (order kept); slot i ← offsets[i]; `fireAt = startAt − offset`; emit iff `include(fireAt)` |
| R7 | duplicate offsets collapse to one (slot of first occurrence) |
| R8 | check: iff `predictedEndAt != null ∧ predictedEndAt > startAt ∧ checkResponse == null ∧ include(predictedEndAt)` |
| R9 | follow-up: iff a `FollowUp` row exists for the task ∧ `include(fireAt)` (R4 still applies) |
| R10 | a check already past is **never** re-scheduled (no catch-up, no repeat) |
| R11 | `mode = exactAllowed ? exactAllowWhileIdle : inexactAllowWhileIdle` |
| R12 | `contentHash = fnv1a32(slot|fireAtIsoUtc|title|body|mode)` hex; part of payload |
| R13 | output sorted by `(fireAt, id)`; ≤ 4 entries per task |

Payload (JSON, ≤ 1 KB): `{"v":1,"t":taskId,"s":slot,"f":fireAtIsoUtc,"d":"YYYY-MM-DD","h":hash,"n":title,"st":startAtIsoUtc?}`.

### 8.3 Reconcile (`NotificationReconciler.reconcile`)
Single-flight: concurrent calls coalesce into one trailing run.
```
state = currentDayControllerProvider.value       // includes optimistic statuses; cache allowed
if state == null → return noop                     // unknown: never wipe a valid schedule
desired  = planNotifications(input from state, settings, followUps, clock, permission.exactAllowed)
pending  = gateway.pendingNotificationRequests()   // scheduled, not yet fired
active   = gateway.getActiveNotifications()        // currently displayed
ops = reconcileDiff(pending, active, desired, state):
  cancel  p ∈ pending  if payload undecodable ∨ p.id ∉ desired ∨ desired[p.id].hash ≠ p.h
  schedule d ∈ desired if pending[d.id] missing ∨ hash differs
  cancel  a ∈ active   if day not open ∨ task(a.t) missing ∨ task(a.t).isTerminal
apply ops (cancel first, then zonedSchedule); a failing schedule is logged and skipped
dao.pruneFollowUps(terminal tasks, fireAt ≤ now, other dates)
dao.prunePendingQuestions(terminal tasks, other dates)
```
`zonedSchedule(id: d.id, title, body, scheduledDate: d.fireAt, notificationDetails, androidScheduleMode: d.mode,
payload: d.payload)` (no `matchDateTimeComponents` — one-shot).

Triggers (`notificationSyncProvider`): `currentDayControllerProvider` emits data (debounce 300 ms) · settings change
(offsets/timezone) · follow-up row change · permission change detected on resume · lifecycle hook (order 40).
`cancelAll()` on logout; `cancelAllForDay()` after EOD close (reports).

### 8.4 Response handling (`ResponseProcessor`, shared by both isolates)
Ports: `Outbox` (enqueue+flush), `NotificationDao`, `Gateway` (show/cancel), `Clock`, `Navigator` (foreground only).
```
p = decode(response.payload); if p == null ∨ p.v != 1 → ignore
switch response.actionId:
  'done':
     if now − p.f ≤ 10 min → outbox.enqueue(check-response done{finished_at: now}); dao.deleteFollowUp(p.t); flush
     else → dao.upsertPendingQuestion(p.t, p.n, p.st, fired_at: p.f, tapped_at: now, slot: p.s)
            gateway.show(id: idFor(p.t, p.s), finish-question notification, silent, actions [finish_at_fire, finish_now])
  'finish_at_fire': outbox done{finished_at: question.fired_at}; delete question; flush
  'finish_now':     outbox done{finished_at: question.tapped_at}; delete question; flush
  'not_yet':        outbox not_yet{}; dao.deleteFollowUp(p.t); flush           // no more automatic prompts
  'not_yet_eta':    navigate /check/{t}/eta                                      // foreground only
  null (body tap):  question exists ? navigate /check/{t}/finish : navigate /today (highlight t)
```
- Lateness boundary: exactly 10:00 → no question; > 10 min → question.
- Foreground (`onDidReceiveNotificationResponse`) additionally triggers `currentDayController.refresh()` after flush.
- App launched from a notification: `launchResponse()` processed after auth; navigation targets buffered until the
  router is ready.

### 8.5 Background handler (no Riverpod)
```dart
@pragma('vm:entry-point')
Future<void> notificationBackgroundHandler(NotificationResponse r) async {
  WidgetsFlutterBinding.ensureInitialized();
  DartPluginRegistrant.ensureInitialized();
  final deps = await BackgroundDeps.create();   // TokenStore, AppDatabase.open(), buildDio(no onUnauthorized),
                                                // plugin.initialize(settings without callbacks), tz init
  try { await ResponseProcessor(deps.ports).process(r, now: DateTime.now().toUtc()); }
  finally { await deps.dispose(); }
}
```
Top-level function in `background_handler.dart`, passed as `onDidReceiveBackgroundNotificationResponse`. No JWT /
401 / offline → the outbox row stays; flushed on next launch/resume. Must finish < 10 s (one flush attempt, no
retries beyond one; `receiveTimeout` 8 s in background Dio).

### 8.6 Follow-up (`FollowUpService.request`)
1. Reject if task not planned, or `now + eta ≥ dayEnd` → `FollowUpResult.afterMidnight`.
2. Upsert row (replaces any previous follow-up: still ≤ 1).
3. Outbox `not_yet{eta_min}` + flush.
4. Reconcile.

### 8.7 Permissions
- `POST_NOTIFICATIONS` (API 33+): requested once after first authenticated Today load (`notif_perm.asked`).
  `areNotificationsEnabled()` checked on each resume.
- Exact alarms: `canScheduleExactNotifications()`; false → inexact mode (R11) + Settings row. API 33+ with
  `USE_EXACT_ALARM` is granted at install; API 31–32 uses `SCHEDULE_EXACT_ALARM` (granted by default, revocable).

### 8.8 Reboot / update persistence
The plugin persists scheduled notifications and re-arms them via `ScheduledNotificationBootReceiver` on
`BOOT_COMPLETED` / `MY_PACKAGE_REPLACED`. Any drift is corrected at the next reconcile.

### 8.9 Initialisation
```dart
await plugin.initialize(
  const InitializationSettings(android: AndroidInitializationSettings('@drawable/ic_stat_notify')),
  onDidReceiveNotificationResponse: onForeground,
  onDidReceiveBackgroundNotificationResponse: notificationBackgroundHandler);
android.createNotificationChannel(AndroidNotificationChannel('reminders', 'Task reminders',
    description: 'Before a task starts', importance: Importance.high));
android.createNotificationChannel(AndroidNotificationChannel('checks', 'Completion checks',
    description: 'One check when a task should be done', importance: Importance.high));
```

## 9. Platform configuration

`android/app/src/main/AndroidManifest.xml`:
```xml
<uses-permission android:name="android.permission.INTERNET"/>
<uses-permission android:name="android.permission.POST_NOTIFICATIONS"/>
<uses-permission android:name="android.permission.RECEIVE_BOOT_COMPLETED"/>
<uses-permission android:name="android.permission.SCHEDULE_EXACT_ALARM" android:maxSdkVersion="32"/>
<uses-permission android:name="android.permission.USE_EXACT_ALARM"/>
<uses-permission android:name="android.permission.VIBRATE"/>

<application ...>
  <receiver android:exported="false"
      android:name="com.dexterous.flutterlocalnotifications.ActionBroadcastReceiver"/>
  <receiver android:exported="false"
      android:name="com.dexterous.flutterlocalnotifications.ScheduledNotificationReceiver"/>
  <receiver android:exported="false"
      android:name="com.dexterous.flutterlocalnotifications.ScheduledNotificationBootReceiver">
    <intent-filter>
      <action android:name="android.intent.action.BOOT_COMPLETED"/>
      <action android:name="android.intent.action.MY_PACKAGE_REPLACED"/>
      <action android:name="android.intent.action.QUICKBOOT_POWERON"/>
      <action android:name="com.htc.intent.action.QUICKBOOT_POWERON"/>
    </intent-filter>
  </receiver>
</application>
```
Gradle (`android/app/build.gradle.kts`): `compileOptions { isCoreLibraryDesugaringEnabled = true }`,
`dependencies { coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:<version required by plugin>") }`.
Resources: `res/drawable/ic_stat_notify.xml` (white monochrome vector) + `res/raw/keep.xml`
(`tools:keep="@drawable/ic_stat_notify"`) so R8 resource shrinking keeps it. Verify scheduled notifications on a
**release** build (R8); add `-keep class com.dexterous.** { *; }` to `proguard-rules.pro` if they fail.

## 10. Errors & offline behaviour
| Case | Behaviour |
|---|---|
| Offline at Done/Not yet | answer stored in outbox; sent on next flush (resume, next request) |
| JWT expired in background | row kept; sent after re-login |
| 409 on replay (already answered/terminal) | dropped by outbox (superseded) |
| `zonedSchedule` throws (past instant race, invalid) | skip that entry, log, continue |
| Exact alarms denied | inexact mode; Settings hint |
| Notifications disabled | PermissionCard; scheduling still performed (harmless) |
| State unknown (no cache, error) | reconcile no-op; existing schedule kept |
| Phone off at fire time | Android delivers missed alarms after boot if still in the future; past checks are not replayed (R10) |

## 11. Testing plan

Unit — planner (`notification_planner_test.dart`). Fixture: `loc = Europe/Bucharest`, `dayDate = 2026-11-09`
(Mon), offsets `[60,30]`, `exactAllowed = true`, task **A** `start 10:00`, `predictedEnd 11:00`, status planned,
`checkResponse null`; `now` local unless stated. Fake clock injected; `hasher` injectable for collisions.

| # | Input variation | Expected desired set |
|---|---|---|
| N01 | now 08:00 | A0@09:00, A1@09:30, A2@11:00 |
| N02 | now 09:10 | A1@09:30, A2@11:00 |
| N03 | now 09:45 | A2@11:00 |
| N04 | now 11:30 | ∅ |
| N05 | now = 08:59:56 (fire − 4 s) | A0 excluded (guard), A1, A2 |
| N06 | now = 08:59:54 (fire − 6 s) | A0 included |
| N07 | A anytime (`start null`) | ∅ |
| N08 | A status completed / postponed / cancelled / cant_do / missed (5 cases) | ∅ each |
| N09 | A `checkResponse = done` (status planned, stale) | A0, A1 only |
| N10 | A `checkResponse = not_yet`, no follow-up | A0, A1 only (no check) |
| N11 | N10 + FollowUp(A, 12:15) | A0, A1, A3@12:15 |
| N12 | FollowUp at 23:59:59 | A3 included |
| N13 | FollowUp at 00:00:00 next day | A3 excluded |
| N14 | A start 23:50, end 00:40 (+1 d) | A0@22:50, A1@23:20; no check |
| N15 | A start 00:20, end 01:20, now 00:05 | A2@01:20 only |
| N16 | dayState closing / closed | ∅ |
| N17 | now 00:10 on 2026-11-10 (day still 2026-11-09, open) | ∅ (R2) |
| N18 | A.localDate = 2026-11-10 | ∅ |
| N19 | offsets `[60,30,15]` | only slots 0,1 |
| N20 | offsets `[30]` | A0@09:30 ("In 30 min"), A2 |
| N21 | offsets `[]` | A2 only |
| N22 | offsets `[30,30]` | A0@09:30 only + A2 |
| N23 | offsets `[0,-5,45]` | A0@09:15 (45) + A2 |
| N24 | predictedEnd null | A0, A1 |
| N25 | predictedEnd = start | A0, A1 (no check) |
| N26 | dayDate 2026-10-25 (DST end, 25-h day), now 2026-10-24T22:00Z (01:00 EEST), A start 03:30 EEST first occurrence (00:30Z), end 02:30Z | A0@2026-10-24T23:30Z, A1@2026-10-25T00:00Z, A2@02:30Z; dayEnd = 2026-10-25T22:00Z |
| N27 | dayDate 2027-03-28 (DST start, 23-h day), now 2027-03-28T00:00Z (02:00 EET), A start 04:30 EEST (01:30Z), end 02:30Z | A0@00:30Z, A1@01:00Z, A2@02:30Z; dayEnd = 2027-03-28T21:00Z |
| N28 | loc = UTC vs Bucharest, same UTC inputs | dayEnd differs; N14-like boundary moves |
| N29 | `exactAllowed = false` | same ids, mode inexact, different hashes |
| N30 | same input twice | identical ids, hashes, order |
| N31 | title changed | only A's hashes change |
| N32 | two tasks A (10:00), B (09:00) | union sorted by fireAt |
| N33 | forced base collision A/B (stub hasher) | B probed; result independent of input order |
| N34 | ids | `id == base*4+slot`, `0 ≤ id < 2^30` |
| N35 | texts | "In 1 hour: …", "In 30 min: …", "In 45 min: …", check/followUp titles per §7.1 |
| N36 | payload | round-trips; `v==1`; contains `f` = fireAt UTC |

Unit — reconcile diff (`reconcile_diff_test.dart`), fake gateway:
| # | Case | Expected ops |
|---|---|---|
| R01 | pending ∅, desired 3 | schedule 3 |
| R02 | pending == desired (same hashes) | no ops |
| R03 | one hash differs | cancel + schedule that id |
| R04 | pending id not desired | cancel |
| R05 | undecodable payload pending | cancel |
| R06 | active check for task now completed | cancel active |
| R07 | active notification, day closed | cancel |
| R08 | state null | no ops |
| R09 | schedule throws for one entry | others applied, report lists failure |
| R10 | 3 concurrent `reconcile()` calls | gateway executed ≤ 2 times (one + trailing) |

Unit — response processor (`response_processor_test.dart`), fake clock, fake outbox/dao/gateway:
| # | Case | Expected |
|---|---|---|
| P01 | `done`, tap = fire + 3 min | outbox done{finished_at = tap}; flush; no question |
| P02 | `done`, tap = fire + 10:00 | as P01 |
| P03 | `done`, tap = fire + 10:01 | question row; finish notification shown with same id; no outbox |
| P04 | `finish_at_fire` | outbox done{finished_at = fired_at}; row deleted |
| P05 | `finish_now` | outbox done{finished_at = tapped_at}; row deleted |
| P06 | `not_yet` | outbox not_yet{} (no eta); follow-up row deleted; nothing scheduled |
| P07 | `not_yet_eta` (foreground) | navigate `/check/{t}/eta` |
| P08 | body tap with question row | navigate `/check/{t}/finish` |
| P09 | body tap, no row | navigate `/today` |
| P10 | late `done` on follow-up (slot 3) | question uses slot-3 id |
| P11 | payload `v:2` / garbage | ignored |
| P12 | flush fails (offline) | row remains in outbox; no exception |
| P13 | follow-up request, now 23:40, eta 30 | `afterMidnight`; no row; no outbox |
| P14 | follow-up request eta 30 at 15:10 | row fire 15:40; outbox not_yet{eta_min:30}; reconcile called |

Integration: drift DAO tests (in-memory) incl. two connections writing concurrently (WAL); background handler smoke
test with `BackgroundDeps` fakes. Widget: `eta_sheet_test` (disabled after-midnight option, dismiss sends not_yet),
`finish_time_screen_test` (three options, picker bounds, missing row pops), `permission_card_test`,
`battery_guide_screen_test` (shown once). Manual release checklist: reminder fires with app killed; fires after
reboot; Done from lock screen with app killed reaches server after unlock/resume.

## 12. Acceptance criteria
- **M-NOTIF-AC-01** Given a planned task starting 14:00 and now 12:00, When reconcile runs, Then exactly two reminders
  are scheduled at 13:00 and 13:30.
- **M-NOTIF-AC-02** Given a task with `predicted_end_at` 15:10 and no check response, Then exactly one completion check
  is scheduled at 15:10 with actions Done / Not yet / Remind me later….
- **M-NOTIF-AC-03** Given any reminder or check time is in the past, Then it is not scheduled and never replayed.
- **M-NOTIF-AC-04** Given a fire time at or after local midnight of the open day, Then it is not scheduled.
- **M-NOTIF-AC-05** Given a task becomes completed/postponed/cancelled/cant_do, When reconcile runs, Then its pending
  and displayed notifications are cancelled.
- **M-NOTIF-AC-06** Given reconcile runs twice on the same state, Then the second run performs no cancel/schedule
  operations (deterministic IDs + hashes).
- **M-NOTIF-AC-07** Given the check fired at 15:10, When I tap Done at 15:15, Then `check-response done` with
  `finished_at ≈ 15:15` is sent (via outbox) and no question is asked.
- **M-NOTIF-AC-08** Given the check fired at 15:10, When I tap Done at 15:40, Then "When did you finish?" offers
  15:10 / 15:40 / Pick, and the chosen time is sent as `finished_at`.
- **M-NOTIF-AC-09** Given I tap Not yet, Then `not_yet` is sent and no further notification for that task is scheduled.
- **M-NOTIF-AC-10** Given I choose +30 min in the ETA sheet at 15:10, Then exactly one follow-up is scheduled at 15:40
  and `not_yet{eta_min:30}` is sent.
- **M-NOTIF-AC-11** Given the app is killed and offline, When I tap Done, Then the answer is stored in the outbox by the
  background handler and sent on the next launch/resume.
- **M-NOTIF-AC-12** Given the day is closed (EOD), Then all of the day's notifications are cancelled.
- **M-NOTIF-AC-13** Given Android 13+, When I first reach Today after login, Then the notification permission is
  requested once.
- **M-NOTIF-AC-14** Given exact alarms are not allowed, Then notifications are scheduled inexactly and Settings shows
  the "Allow exact timing" hint.
- **M-NOTIF-AC-15** Given the phone reboots, Then pending notifications still fire (boot receiver).
- **M-NOTIF-AC-16** Given an anytime task, Then no notification is ever scheduled for it.
- **M-NOTIF-AC-17** Given the first successful scheduling, Then the battery guide is shown once and never auto-shown
  again.

## 13. Open questions
| # | Question | Proposed default |
|---|---|---|
| Q1 | Morning tasks: tomorrow's tasks (templates materialize only on `GET /days/current`) get no reminders until the app is opened after midnight; a 07:00 task's T-60 at 06:00 is missed if the app isn't opened | v1 accepts; candidate fix: backend endpoint previewing tomorrow's planned tasks, scheduled on the evening reconcile (needs plan change to "nothing past midnight") |
| Q2 | Does `check-response done` set `status=completed` + `actual_end_source=notification_action` server-side? | assumed yes |
| Q3 | Is a second `check-response` (not_yet then done, or not_yet twice from follow-up) accepted? | done must be accepted after not_yet; duplicate not_yet → 409 dropped |
| Q4 | `reminder_offsets_min` is configurable server-side but P5 fixes T-60/T-30 | use first two distinct values; app never edits them |
| Q5 | Late-Done question unanswered before the day closes → task becomes `missed` | EOD sheet still lists it as planned; propose: pending question rows are surfaced first in the EOD sheet |

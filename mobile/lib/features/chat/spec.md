# mobile/chat — Spec

> Governed by `constitution.md` (P5, P7, P10) and `plan.md` (§4 assistant never mutates state, §7, §8.1, §8.3,
> ADR-009). The chat screen talks to the assistant and turns its **action proposals** into one-tap confirmations
> that are executed through the owning features' normal flows/endpoints.

## 1. Purpose & scope

| Capability | Contribution |
|---|---|
| C11 | Conversation UI, clarifying questions as quick-reply chips |
| C2/C3 | `create_task` proposal → same add-task flow (form, recurring question, feasibility card) |
| C7 | `update_status` proposal → status change via tasks |
| C8 | `close_day` proposal ("EOD done for the day") → EOD flow via reports |
| C10 | `email_report` proposal → explicit email via reports |

Out of scope: voice input (plan §18), chat history of previous days (v1 shows the open day only), streaming tokens,
the assistant executing anything itself, any mutation without a user tap.

## 2. Folder layout

```
features/chat/
├── data/
│   ├── dto/                       # ChatMessageDto, AssistantReplyDto, ActionProposalDto (freezed unions)
│   ├── assistant_api.dart         # POST /assistant/messages, GET /assistant/messages?date=
│   └── db/
│       ├── proposal_outcomes_table.dart  # ProposalOutcomes (registered in AppDatabase)
│       └── proposal_outcome_dao.dart
├── domain/
│   ├── entities.dart              # ChatMessage, ActionProposal (sealed), ProposalOutcome
│   ├── proposal_validator.dart    # PURE: is the proposal still executable against TodayState?
│   └── proposal_summary.dart      # PURE: human one-line summary per proposal
└── presentation/
    ├── chat_screen.dart
    ├── message_bubble.dart
    ├── typing_indicator.dart
    ├── proposal_card.dart
    ├── quick_reply_chips.dart
    ├── degraded_banner.dart
    ├── chat_controller.dart       # AsyncNotifier<ChatState>
    ├── proposal_executor.dart     # routes a confirmed proposal to tasks / reports
    └── providers.dart
```

## 3. Dependencies

| Feature | Used |
|---|---|
| app_shell | `apiClientProvider`, `serverStatusProvider`, `appDatabaseProvider`, `clockProvider`, `LocalDate`, `AppError`, `AsyncValueView` |
| tasks | `currentDayControllerProvider`, `AddTaskFlow.start`, `StatusSheet.show`, `tasksRepositoryProvider.setStatus`, `TaskDraft`, `StatusChange`, `CreatedVia.chat` |
| reports | `EodFlow.start(context)`, `ReportEmailAction.send(context, reportId)`, `reportsRepositoryProvider.latest(kind)` |

Packages: flutter_riverpod, go_router, freezed, json_serializable, drift, intl.

## 4. Local data

`proposal_outcomes` (drift): `message_id text PK`, `outcome text` (`confirmed | dismissed | failed`),
`result_ref text nullable` (task id / report id), `at datetime UTC`. Needed because the server stores the proposal
but not what the user did with it; prevents double execution when history is reloaded. Rows older than 7 days are
pruned on launch.

## 5. Public interface

```dart
sealed class ActionProposal { }
final class CreateTaskProposal extends ActionProposal { final TaskDraft draft; }   // draft.isRecurring may be null
final class UpdateStatusProposal extends ActionProposal { final String taskId; final String? taskTitle;
  final StatusChange change; }                    // completed{finished_at?} | postponed{new_start_at?} | cancelled{reason?} | cant_do{reason?}
final class CloseDayProposal extends ActionProposal { }
final class EmailReportProposal extends ActionProposal { final String? reportId; final String? kind; }
final class UnknownProposal extends ActionProposal { final String type; }          // forward compatibility

@freezed class ChatMessage { String id; ChatRole role; String content; DateTime createdAt;
  ActionProposal? proposal; List<String> quickReplies; bool degraded; SendState sendState; }  // sendState: sent|sending|failed

final chatControllerProvider = AsyncNotifierProvider<ChatController, ChatState>(...);
//   Future<void> send(String text); Future<void> retry(String localId); Future<void> loadHistory();
//   Future<void> confirm(String messageId); Future<void> dismiss(String messageId);
```
No other feature depends on chat (chat is a leaf).

## 6. Backend endpoints used

| Method & path | Request | Response |
|---|---|---|
| `POST /assistant/messages` | `{text}` (1–2000 chars) | `{user_message: Msg, reply: Msg}` |
| `GET /assistant/messages?date=YYYY-MM-DD` | — | `[Msg]` oldest first |

`Msg = {id, role: "user"|"assistant", content, created_at, proposal?, quick_replies?: [string], degraded?: bool}`.

`proposal` (discriminated by `type`):
```json
{"type":"create_task","draft":{"title":"Gym","category":"Health","local_date":"2026-11-08",
  "start_at":"2026-11-08T16:00:00Z","estimate_min":60,"is_recurring":null,"recurrence":null}}
{"type":"update_status","task_id":"…","task_title":"Gym","status":"completed","finished_at":"2026-11-08T17:05:00Z"}
{"type":"update_status","task_id":"…","status":"postponed","new_start_at":"2026-11-09T07:00:00Z"}
{"type":"update_status","task_id":"…","status":"cant_do","reason":"Gym closed"}
{"type":"close_day"}
{"type":"email_report","report_id":"…"}            // report_id may be null → latest daily
```
Field names follow plan §4.1 `AssistantReplyDTO` ("reply + optional ActionProposal"); exact JSON to be verified against
`openapi.json` (Q1). Proposal `status: "missed"` is never valid and is rendered as `UnknownProposal`.

## 7. Screens & UX flow

### 7.1 ChatScreen (`/chat`)
Layout: AppBar "Assistant · Sun 8 Nov" · optional `DegradedBanner` · reversed message list · quick-reply chips (last
assistant message only) · input row (multiline `TextField`, max 2000, Send button).

| State | UI |
|---|---|
| loading history | spinner (waking text after 3 s) |
| empty | hint card: "Try: 'Add gym at 18:00 for an hour', 'I finished the report', 'EOD done for the day', 'Email today's report'" |
| content | bubbles (user right, assistant left), timestamps `HH:mm` |
| sending | user bubble shown immediately (`sending`), `TypingIndicator` bubble; after 3 s with `ServerStatus.waking` the indicator reads "Waking server…" |
| send failed | user bubble with error icon + "Retry"; input re-enabled |
| offline | input disabled, placeholder "You're offline" |
| history error | ErrorView + Retry (input still usable) |
| day closed | input enabled; proposals other than `email_report` render as non-executable ("Today is closed") |

One request in flight at a time (Send disabled while `sending`) to keep ordering.

### 7.2 ProposalCard (inside the assistant bubble)
| Type | Summary line | Confirm label | On Confirm |
|---|---|---|---|
| create_task | "Add task: Gym · 18:00 · 60 min" (+ "Recurring?" when unknown) | Review & add | `AddTaskFlow.start(prefill: draft, via: chat)` → form (recurring question always visible) → feasibility card → Add/Add anyway/Adjust |
| update_status completed/cancelled (complete data) | "Mark 'Gym' completed (finished 19:05)" | Confirm | `tasksRepository.setStatus(id, change)` |
| update_status postponed without `new_start_at` / cant_do without reason | "Postpone 'Gym'…" | Choose… | `StatusSheet.show(task, preselect, prefill)` |
| update_status postponed/cant_do with data | "Postpone 'Gym' to Mon 09:00" | Confirm | `setStatus` |
| close_day | "End the day now" | Done for the day | `EodFlow.start(context)` (resolution sheet → close → report) |
| email_report | "Email the daily report for Sun 8 Nov" | Send email | `ReportEmailAction.send(context, reportId ?? latest daily id)` |
| unknown | "Unsupported action" | — (Dismiss only) | — |

Card states: `ready` (Confirm + Dismiss) · `executing` (spinner) · `confirmed` (result text, e.g. "Added", "Marked
completed", "Report emailed"; buttons hidden) · `dismissed` ("Dismissed") · `stale` (reason text; Dismiss only) ·
`failed` (error text + Retry). The outcome is written to `proposal_outcomes`; cancelling the add-task form or the
status sheet returns the card to `ready` (no outcome written).

### 7.3 Quick replies
`quick_replies` of the **latest** assistant message render as `ActionChip`s above the input; tapping sends that
exact text via `send()`; chips disappear once any new message is sent.

### 7.4 DegradedBanner
Shown while the latest assistant reply has `degraded == true`: "Assistant is in basic mode (AI provider unavailable).
Tasks, reminders and reports still work." Dismissible for the session.

## 8. Behaviour & rules

1. **Assistant never mutates**: the chat feature makes no write call other than `POST /assistant/messages`; every
   state change goes through tasks/reports public flows after an explicit tap (ADR-009).
2. **Validity check before rendering Confirm** (`proposal_validator`, pure, input `TodayState`):
   - update_status: task id must exist in the open day with `status == planned` → else `stale` "Already updated".
   - create_task / update_status / close_day: day state must be `open` → else `stale` "Today is closed".
   - close_day when another close is in progress → `stale`.
   - email_report: always valid (server returns 409 if email not configured; reports handles it).
3. **Draft normalisation for create_task**: missing `category` → `Personal`; missing `local_date` → open day;
   `start_at` outside `local_date` → dropped (user picks time on the form); `is_recurring` passed through as
   preselection only — the user still sees and confirms the question.
4. **Outcomes**: `confirmed` written only after the delegated flow returns success (Task created, status set, day
   closed, email sent). History reload merges outcomes by message id; confirmed/dismissed cards never show Confirm.
5. **History**: loaded on first open of the tab and on resume if the open day's date changed; messages for the open
   day only. Local optimistic user messages are replaced by `user_message` from the response.
6. **Execution side-effects**: tasks/reports flows update `currentDayControllerProvider`, which triggers notification
   reconcile; chat does nothing extra.
7. **Text limits**: trimmed; empty → Send disabled; > 2000 chars → counter + disabled.
8. **No auto-email / no auto-close**: `email_report` and `close_day` require the Confirm tap even if the user's text
   was explicit (P5, C10).
9. **Morning greeting** (decided 2026-11-09): `MorningGreetingHook implements LifecycleHook { order = 60 }` runs after
   the day refresh. If the open day's `local_date` ≠ `app_kv['greeting.last_date']` and the day is `open`:
   `POST /assistant/greeting` → store the date in `app_kv` (regardless of `created`) → if `created == true`, switch to
   the **Chat** tab and show the greeting ("Good morning! What do you plan to do today?") with its quick replies.
   My answer can list several tasks; the assistant proposes them one at a time ("Next: …"). Failures (offline,
   cold start timeout) are silent and retried on the next resume. No notification is used for the greeting.

## 9. Platform configuration
None.

## 10. Errors & offline behaviour
| Case | Behaviour |
|---|---|
| Cold start | typing indicator → "Waking server…"; app_shell retries ≤ 120 s |
| POST fails (timeout/5xx/offline) | user bubble `failed` + Retry (resends same text with same idempotency key) |
| 422 (text too long/empty) | inline error under input |
| Proposal execution fails | card `failed` with `AppError.userMessage` + Retry |
| `email_report` → 409 not configured | handled by `ReportEmailAction` (dialog → Settings); card back to `ready` |
| Degraded AI | banner; proposals still rendered if present |
| Unknown proposal type | `UnknownProposal` card, Dismiss only |

## 11. Testing plan
Unit:
- `proposal_dto_test`: parse each `type` incl. nulls; unknown type → `UnknownProposal`; `status:"missed"` → Unknown.
- `proposal_validator_test`: task missing; task terminal; day closed; valid cases.
- `proposal_summary_test`: each type, anytime vs timed, recurring unknown.
- `chat_controller_test` (mock API, fake clock): optimistic send → replaced by server ids; failure → `failed`; retry;
  single in-flight; history merge with outcomes.
- `proposal_executor_test` (mocks of AddTaskFlow/StatusSheet/setStatus/EodFlow/ReportEmailAction): routing table in
  §7.2; outcome written only on success; cancelled form → no outcome.
Widget:
- `chat_screen_test`: empty hint, typing indicator, waking text, failed bubble + retry, offline input disabled,
  quick-reply chip sends text, degraded banner.
- `proposal_card_test`: each state; confirmed card has no buttons; stale card shows reason.
Golden: `proposal_card` (create_task ready, update_status confirmed, close_day stale).
Integration: "Add gym at 18:00" → mocked reply with create_task → Review & add → form prefilled with recurring
question unanswered → assess → Add → Today shows task, card confirmed.

## 12. Acceptance criteria
- **M-CHAT-AC-01** Given I type a message, When I send it, Then `POST /assistant/messages {text}` is called, my bubble
  appears immediately and a typing indicator is shown until the reply arrives.
- **M-CHAT-AC-02** Given the server is asleep, When the reply takes > 3 s, Then the indicator reads "Waking server…".
- **M-CHAT-AC-03** Given a `create_task` proposal, When I tap Review & add, Then the add-task form opens prefilled, the
  "Recurring or one-time?" question must be answered, and the feasibility card is shown before saving.
- **M-CHAT-AC-04** Given an `update_status` completed proposal for a planned task, When I tap Confirm, Then
  `POST /tasks/{id}/status` is called once and the card shows "Marked completed".
- **M-CHAT-AC-05** Given an `update_status` proposal for a task that is no longer planned, Then Confirm is not shown.
- **M-CHAT-AC-06** Given a `close_day` proposal, When I tap "Done for the day", Then the EOD resolution flow starts; the
  day is not closed without completing that flow.
- **M-CHAT-AC-07** Given an `email_report` proposal, When I tap Send email, Then `POST /reports/{id}/email` is called;
  without the tap nothing is emailed.
- **M-CHAT-AC-08** Given quick replies on the last assistant message, When I tap one, Then its text is sent as my
  message.
- **M-CHAT-AC-09** Given a reply with `degraded:true`, Then the degraded banner is shown.
- **M-CHAT-AC-10** Given a confirmed proposal, When history reloads, Then the card shows its outcome and cannot be
  executed again.
- **M-CHAT-AC-11** The chat feature performs no write request other than `POST /assistant/messages` and `POST /assistant/greeting`.
- **M-CHAT-AC-12** Given the first app open of a new open day, Then the Chat tab opens with the greeting "What do you
  plan to do today?"; reopening the app the same day does not greet again.

## 13. Open questions
| # | Question | Proposed default |
|---|---|---|
| Q1 | Exact `AssistantReplyDTO` / `ActionProposal` JSON (incl. `quick_replies`, `degraded`, `task_title`) is not defined in plan §7 | as in §6; align with backend assistant spec |
| Q2 | Should the server record proposal outcomes (for intent-routing quality)? | local only in v1 |
| Q3 | Retrying `POST /assistant/messages` after a timeout may duplicate the turn server-side | needs `Idempotency-Key` support (app_shell Q2) |
| Q4 | Chat history for previous days | not shown in v1 |

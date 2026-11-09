# Module Spec — `assistant`

> Backend module · Governed by [`constitution.md`](../../../../constitution.md) and [`plan.md`](../../../../plan.md) §8, §9, ADR-009.
> Conversational layer: understands a message, asks clarifying questions, answers progress questions, and returns
> **action proposals**. It never mutates tasks, days or reports — the app executes proposals via normal endpoints.

## 1. Purpose & scope

| Capability | Role |
|---|---|
| C2 | "Add gym at 6 pm" → `create_task` proposal (always asks recurring vs one-time if unknown) |
| C7 | "Mark gym done" → `update_status` proposal |
| C8 | "EOD done for the day" → `close_day` proposal |
| C10 | "Send the report on email" → `email_report` proposal |
| C11 | Clarifying questions, progress answers, small talk |

Out of scope: executing actions, feasibility (the app calls `/feasibility/assess` when executing `create_task`).

## 2. Folder layout

```
assistant/
├── spec.md
├── __init__.py        # exports AssistantService, AssistantReplyDTO, ActionProposal, Intent
├── api.py             # POST/GET /assistant/messages
├── service.py         # AssistantService.handle (pipeline §7.1)
├── intents.py         # Intent enum, Jev routing questions, thresholds
├── slots.py           # extraction schemas (TaskSlots, StatusSlots), merge with pending context
├── resolver.py        # task reference resolution (fuzzy match on today's titles)
├── progress.py        # deterministic progress summary
├── prompts/
│   ├── extract_task.v1.j2
│   ├── extract_status.v1.j2
│   ├── classify_intent.v1.j2      # Groq fallback for routing (via ai_gateway.extract)
│   ├── reply.v1.j2                # phrasing of replies / clarifying questions
│   └── progress.v1.j2
├── models.py          # chat_message ORM
├── repository.py
└── schemas.py
```

## 3. Dependencies

- Modules: `core`, `crypto`, `ai_gateway`, `tasks` (read: `TaskDraft`, `Recurrence`, `TaskService.day_plan`),
  `schedule` (read: `free_slots`), `day_cycle` (read: `DayService.current`), `reports` (read: latest report id).
- Packages: `rapidfuzz` (title matching), `pydantic`.

## 4. Data owned — `chat_message`

| Column | Type | Notes |
|---|---|---|
| id | uuid PK | |
| local_date | date | day the message belongs to (index `(local_date, created_at)`) |
| role | text | `user` \| `assistant` |
| content 🔒 | EncryptedText (`chat_message.content`) | |
| intent | text null | on user messages |
| intent_confidence | real null | Jev choice confidence / Groq 0.5 |
| in_scope_noul | real null | |
| proposal 🔒 | EncryptedJSON null (`chat_message.proposal`) | on assistant messages |
| pending 🔒 | EncryptedJSON null (`chat_message.pending`) | partial slots awaiting clarification (assistant messages) |
| quick_replies | jsonb null | list of strings (generic chips like "Recurring", "One-time" — no personal text) |
| degraded | bool default false | |
| created_at, updated_at | timestamptz | |

Retention: messages older than 90 days deleted opportunistically.

## 5. Public interface

```python
class Intent(StrEnum):
    ADD_TASK = "add_task"
    UPDATE_TASK_STATUS = "update_task_status"
    QUERY_PROGRESS = "query_progress"
    PLAN_DAY = "plan_day"
    END_OF_DAY = "end_of_day"
    SEND_REPORT_EMAIL = "send_report_email"
    SCHEDULE_QUESTION = "schedule_question"
    SMALL_TALK = "small_talk"


class CreateTaskProposal(BaseModel):
    type: Literal["create_task"]
    draft: TaskDraft  # is_recurring may be unknown → see §7.4


class UpdateStatusProposal(BaseModel):
    type: Literal["update_status"]
    task_id: UUID
    task_title: str
    status: Literal["completed", "postponed", "cancelled", "cant_do"]
    finished_at: datetime | None = None
    new_start_at: datetime | None = None
    reason: str | None = None


class CloseDayProposal(BaseModel):
    type: Literal["close_day"]


class EmailReportProposal(BaseModel):
    type: Literal["email_report"]
    report_id: UUID | None
    kind: Literal["daily", "weekly"] = "daily"


ActionProposal = Annotated[
    CreateTaskProposal | UpdateStatusProposal | CloseDayProposal | EmailReportProposal,
    Field(discriminator="type"),
]


class MessageDTO(BaseModel):
    id: UUID
    role: Literal["user", "assistant"]
    content: str
    created_at: datetime
    proposal: ActionProposal | None = None
    quick_replies: list[str] | None = None
    degraded: bool = False


class AssistantReplyDTO(BaseModel):
    user_message: MessageDTO
    reply: MessageDTO
    intent: Intent
    degraded: bool


class AssistantService:
    async def handle(self, text: str) -> AssistantReplyDTO: ...
    async def history(self, local_date: date, limit: int = 100) -> list[MessageDTO]: ...
```
`CreateTaskProposal.draft.is_recurring`: the shared `TaskDraft` requires it; when the user hasn't said, the
assistant asks first (§7.4) and only emits the proposal once known. The app's add-task form still shows the
recurring question (mobile tasks spec), so the user can change it.

## 6. HTTP endpoints

| Method & path | Body / params | Response | Errors |
|---|---|---|---|
| `POST /api/v1/assistant/messages` | `{"text": "…"}` (1..2000 chars) | 200 `AssistantReplyDTO` | 422 |
| `GET /api/v1/assistant/messages?date=YYYY-MM-DD&limit=100` | date default = current day | 200 `[MessageDTO]` oldest→newest | 422 |
| `POST /api/v1/assistant/greeting` | — | 200 `{"created": bool, "message": MessageDTO \| null}` — morning greeting, at most once per day (§7.8) | — |

`ensure_current_day` (day_cycle dependency) is attached so midnight auto-close happens before handling.

Examples:
```json
POST {"text":"add gym at 6pm for an hour"}
→ {"intent":"add_task","degraded":false,
   "reply":{"role":"assistant","content":"Should Gym repeat (daily / some weekdays) or is it one-time?",
            "quick_replies":["One-time","Daily","Choose weekdays"],"proposal":null}}
POST {"text":"daily"}
→ {"intent":"add_task","reply":{"content":"Got it — Gym daily at 18:00 for 60 min. Review and add?",
   "proposal":{"type":"create_task","draft":{"title":"Gym","category":"Health","start_at":"2026-11-09T12:30:00Z",
   "estimate_min":60,"is_recurring":true,"recurrence":{"freq":"daily"},"local_date":"2026-11-09"}}}}
POST {"text":"EOD done for the day"}
→ {"intent":"end_of_day","reply":{"content":"Ready to wrap up today? 2 tasks are still open.","proposal":{"type":"close_day"}}}
```

## 7. Behaviour & rules

### 7.1 Pipeline (`handle`)
1. `day = day_cycle.current()`; persist the user message (encrypted).
2. Load the last assistant message of the day; if it has `pending` and was created ≤ 30 min ago → **continuation**:
   treat the text as an answer to the pending question (skip routing, go to step 4 with `pending.intent`).
3. **Route** (§7.2) → intent.
4. **Dispatch** by intent (§7.3–7.7) → `(content, proposal?, quick_replies?, pending?)`.
5. Persist the assistant message; return both messages. `degraded` = any ai_gateway result degraded.

### 7.2 Intent routing
`ai_gateway.decide("intent", state, questions)` with
`state = {"message": text, "now_local": "...", "today_task_titles": [...≤30], "day_state": "open|closed"}` and:
- `intent` — **choice**: "Which intent best describes the user's message to their personal task assistant?"
  criteria: add_task: "wants to add/plan a new task", update_task_status: "says a task is done, postponed,
  cancelled or can't be done", query_progress: "asks how the day/week is going or what's left",
  plan_day: "wants help planning today", end_of_day: "declares the day finished (e.g. 'EOD done for the day')",
  send_report_email: "asks to email/send a report", schedule_question: "asks about free time or their schedule",
  small_talk: "anything else".
- `in_scope` — **noul** (companion): "Does the message clearly match one of: adding a task, updating a task's
  status, asking about progress, planning the day, ending the day, emailing a report, asking about free time?"

Rules: if `in_scope < 0.35` → `small_talk`; if `intent.confidence < 0.45` → ask "Did you want to: add a task,
update a task, or something else?" with those quick replies (no proposal).
Fallback (`engine != jev`): Groq answers via ai_gateway emulation automatically; if `deterministic_only`, a keyword
router: `/\b(eod|end of (the )?day|done for the day|wrap up)\b/` → end_of_day; `/\b(email|mail|send).*report\b/` →
send_report_email; `/\b(done|finished|completed|postpone|cancel|can'?t)\b/` → update_task_status;
`/\b(add|plan|schedule|remind)\b/` → add_task; `/\b(how am i|progress|left|remaining)\b/` → query_progress; else small_talk.

### 7.3 add_task
1. `ai_gateway.extract("extract_task", TaskSlots, "assistant/extract_task.v1.j2", ctx)` where
   `TaskSlots = {title: str|None, category: str|None, start_local: "HH:MM"|None, date: "today"|"tomorrow"|ISO|None,
   estimate_min: int|None, is_recurring: bool|None, recurrence: {freq, byweekday?}|None}`; ctx = message, now_local,
   categories list, pending slots.
2. Merge with `pending` slots (new values win).
3. Required to propose: `title`, and `is_recurring` known. Clarify in this order, one question per turn:
   missing title → "What's the task?"; missing `is_recurring` → "Should '{title}' repeat (daily / some weekdays)
   or is it one-time?" quick replies `["One-time","Daily","Choose weekdays"]` (→ "Which weekdays?" with
   `["Mon–Fri","Mon/Wed/Fri","Sat–Sun"]`); missing start time → "What time do you plan to start?" with
   `["Now","In 30 min","Anytime today"]` (start time optional: "Anytime today" sets none).
   Estimate is never required.
4. Build `TaskDraft` (start_local + date → `start_at` UTC via app tz; category default `Personal`) and return
   `create_task` proposal with a one-line summary. No feasibility call here — the app assesses when executing.

### 7.4 update_task_status
1. Extract `StatusSlots = {task_ref: str|None, status: completed|postponed|cancelled|cant_do|None,
   finished_local: "HH:MM"|None, new_date: str|None, new_start_local: str|None, reason: str|None}`.
2. Resolve `task_ref` against today's planned tasks (`resolver.py`): `rapidfuzz.process.extract` on decrypted titles,
   scorer `WRatio`; accept best if score ≥ 80 and ≥ 10 points ahead of the second; else ask "Which task?" with the
   top-3 titles as quick replies (pending kept). No planned tasks → "Nothing is open today."
3. Missing pieces are allowed: `postponed` without time or `cant_do` without reason → proposal still emitted; the
   app opens its status sheet to complete it (mobile chat spec).
4. `completed` with no time → `finished_at = now`.

### 7.5 end_of_day
Day open → `close_day` proposal; content mentions number of still-planned tasks. Day already closed →
"Today is already closed." (no proposal). Never closes by itself, even if the message is explicit (P5/ADR-009).

### 7.6 send_report_email
Find the latest `ready` report (`kind` from text: "weekly" → weekly, else daily). If none → "There's no report yet —
close the day first." Otherwise `email_report` proposal with `report_id`. Report email not configured → still propose;
the app handles the 409 and links to Settings.

### 7.7 query_progress / plan_day / schedule_question / small_talk
- **query_progress**: `progress.py` computes deterministically from `day_plan`: counts by status, completed
  minutes, next planned task, overdue tasks (start passed, still planned). Phrased via `generate("progress.v1.j2")`
  (≤ 3 sentences); fallback = template string with the numbers.
- **plan_day**: lists planned tasks + top-3 free slots (`schedule.free_slots`) and asks "What else do you want to
  get done today?" with pending `{intent: add_task}`.
- **schedule_question**: free slots summary for the date asked (today default).
- **small_talk**: short `generate("reply.v1.j2")` reply steering back to tasks; fallback "I can help you add tasks,
  update them, or wrap up the day."

### 7.8 Morning greeting (user decision 2026-11-09)
`AssistantService.greet() -> GreetingResult` (endpoint `POST /assistant/greeting`), called by the app on its first
open of each day:
1. `day = day_cycle.current()`; if the day is closed, or a greeting message already exists for `day.local_date`
   (`chat_message` with `intent = 'greeting'`) → `{created:false, message:null}` (idempotent).
2. Otherwise create an assistant message (template, no AI). Salutation by local time: before 12:00 "Good morning",
   12:00–17:00 "Good afternoon", later "Good evening" (examples below use morning):
   - no tasks yet: "Good morning! What do you plan to do today?"
   - recurring tasks already materialized: "Good morning! Today you have {n} recurring tasks: {titles ≤ 3}{…}.
     What else do you plan to do today?"
   with `intent='greeting'`, `pending={"intent":"plan_day","queue":[]}`, quick replies
   `["Nothing else today", "Show my free time"]`.
3. The user's next message (within the pending TTL, extended to **4 h** for greetings) is handled as a **multi-task
   plan** (§7.9).

### 7.9 Multi-task messages ("gym at 6, finish report at 10, call mom")
For `add_task`/`plan_day` continuations, extraction uses `TaskListSlots = {tasks: [TaskSlots]}` (≤ 10).
Tasks are queued in `pending.queue` and handled **one at a time**: the assistant clarifies/proposes the first
(`create_task` proposal), and after each proposal its reply ends with "Next: '{title}'" — the user's next message
(or the quick reply "Next") continues with the next queued task. "Nothing else today" clears the queue.

### 7.10 Reply phrasing
Clarifying questions and summaries use fixed templates (deterministic, no AI) so they're instant and consistent;
only progress/small_talk use `generate`. All times rendered in local `HH:MM` 24h.

## 8. Configuration

`ASSISTANT_PENDING_TTL_MIN` (30), `ASSISTANT_FUZZY_MIN_SCORE` (80), `ASSISTANT_ROUTE_MIN_CONFIDENCE` (0.45),
`ASSISTANT_IN_SCOPE_MIN` (0.35).

## 9. Errors & degradation

| Case | Behaviour |
|---|---|
| Routing AI down | keyword router; `degraded=true` |
| Extraction returns None | ask the next missing slot with a plain question; keep pending |
| Generate fails | template text |
| Day closed | `create_task`/`update_status`/`close_day` not proposed; reply explains |

The endpoint does not return 5xx for AI failures.

## 10. Security & privacy

Content, proposals and pending slots encrypted at rest. Only the message text, today's titles and times go to AI
(no notes). `quick_replies` is stored in plaintext, so it may only hold generic labels; task-title chips
("Which task?") are returned in the response but stored as `null`.

## 11. Testing plan

Unit: `test_keyword_router`, `test_route_low_confidence_asks`, `test_add_task_asks_recurring_first`,
`test_add_task_weekdays_flow`, `test_draft_start_at_tz_conversion`, `test_pending_continuation_within_ttl`,
`test_pending_expired_reroutes`, `test_resolver_accepts_clear_match`, `test_resolver_ambiguous_asks`,
`test_status_without_reason_still_proposes`, `test_eod_proposal_never_closes`, `test_email_no_report_message`,
`test_progress_numbers_deterministic`, `test_greeting_once_per_day`, `test_greeting_lists_recurring_tasks`,
`test_greeting_skipped_when_day_closed`, `test_multi_task_queue_one_at_a_time`, `test_nothing_else_clears_queue`.
Integration: `test_post_message_persists_encrypted`, `test_get_history_order`, `test_ai_down_end_to_end_keyword_path`, `test_handle_has_no_write_side_effects`.

## 12. Acceptance criteria

| ID | Given / When / Then | Tests |
|---|---|---|
| ASST-AC-01 | Given "add gym at 6pm", When recurring is unknown, Then the reply asks recurring vs one-time with quick replies and no proposal | `test_add_task_asks_recurring_first` |
| ASST-AC-02 | Given the answer "daily", Then a `create_task` proposal with `is_recurring=true, recurrence={freq:daily}` is returned | `test_pending_continuation_within_ttl` |
| ASST-AC-03 | Given "EOD done for the day" on an open day, Then a `close_day` proposal is returned and the day is still open | `test_eod_proposal_never_closes` |
| ASST-AC-04 | Given "mark gym done" and one planned task "Gym", Then `update_status` completed with that task id | `test_resolver_accepts_clear_match` |
| ASST-AC-05 | Given AI providers are down, Then intents still route via keywords and `degraded=true` | `test_ai_down_end_to_end_keyword_path` |
| ASST-AC-06 | Chat content and proposals are ciphertext at rest | `test_post_message_persists_encrypted` |
| ASST-AC-07 | The assistant never writes to tasks/day/report tables | `test_handle_has_no_write_side_effects` |
| ASST-AC-08 | Given the first app open of an open day, When `POST /assistant/greeting`, Then one greeting "What do you plan to do today?" is created; a second call returns `created:false` | `test_greeting_once_per_day` |
| ASST-AC-09 | Given the reply "gym at 6, report at 10", Then the first task is proposed and the second is queued as "Next" | `test_multi_task_queue_one_at_a_time` |

## 13. Open questions

None. Morning greeting decided 2026-11-09 (§7.8).

# Module spec — `backend/schedule`

> Governed by [`constitution.md`](../../../../constitution.md) and [`plan.md`](../../../../plan.md) (§4.1, §5.3, §7, §8.5, ADR-007).
> Status: draft for M2.

## 1. Purpose & scope

Knows when the user is **not** available: the fixed weekly schedule and, only for days the user consented to, imported Google Calendar events. Computes busy intervals and free slots in UTC for any local date.

| Capability | Served by |
|---|---|
| C4 Fixed weekly schedule | `fixed_schedule_block`, `GET/PUT /schedule/blocks` |
| C4 Per-day consented calendar events (P6) | `calendar_event`, `PUT/DELETE /schedule/calendar/{date}` |
| C3 inputs (deterministic overlap math, P8) | `ScheduleService.busy_intervals`, `free_slots`, `GET /schedule/free-slots` |

Out of scope: talking to Google (done on the phone, plan §8.5 — the server never sees a Google token), feasibility scoring, subtracting planned tasks from free time (feasibility combines `tasks.day_plan` with these results), recurring calendar expansion (phone requests `singleEvents=true`).

## 2. Folder layout

| File | Contents |
|---|---|
| `__init__.py` | exports `ScheduleService`, `BusyInterval`, `TimeInterval`, `BlockKind` |
| `api.py` | router `/api/v1/schedule…` |
| `service.py` | `ScheduleService` |
| `intervals.py` | pure functions: `local_to_utc`, `day_window`, `block_intervals_for_date`, `clip`, `merge`, `subtract`, `weekly_overlaps` (unit-tested, no I/O) |
| `repository.py` | `BlockRepository`, `CalendarEventRepository` |
| `models.py` | ORM `FixedScheduleBlock`, `CalendarEvent` |
| `schemas.py` | DTOs and request bodies |

## 3. Dependencies

- Modules: `core` (`AppSettingsService`, `Clock`, errors, `get_session`), `crypto` (`EncryptedText`), `auth` (`current_user`, api only). Plan §4: `schedule ──▶ core, crypto`.
- Third-party: `sqlalchemy[asyncio]`, `pydantic`, stdlib `zoneinfo`, `datetime`. No Google library on the server.

## 4. Data owned

All tables have `created_at`, `updated_at timestamptz not null default now()`. Enums are `varchar` + `CHECK`.

### 4.1 `fixed_schedule_block`
| Column | Type | Null | Default / notes |
|---|---|---|---|
| id | uuid PK | no | |
| weekday | smallint | no | `CHECK (weekday BETWEEN 0 AND 6)`, 0=Mon … 6=Sun (Python `date.weekday()`) |
| start_local | time | no | seconds = 0 |
| end_local | time | no | `CHECK (end_local <> start_local)`; `end_local < start_local` ⇒ crosses midnight into weekday+1 |
| label 🔒 | text (`EncryptedText`, AAD `fixed_schedule_block.label`) | no | |
| kind | varchar enum `work, sleep, commute, meal, personal, other` | no | |
| is_hard | bool | no | `true` |
| active | bool | no | `true` |
| position | smallint | no | *added*: order in the last PUT payload (stable display order) |

Index `ix_fsb_weekday_active (weekday, active)`.

### 4.2 `calendar_event`
| Column | Type | Null | Default / notes |
|---|---|---|---|
| id | uuid PK | no | |
| day_date | date | no | local date the import was consented for |
| external_id | varchar(1024) | no | Google event id (instance id for recurring) — opaque, not personal text |
| start_at, end_at | timestamptz | no | `CHECK (end_at > start_at)`; for all-day: local midnight boundaries in UTC |
| all_day | bool | no | `false` |
| show_as_free | bool | no | `false` — *added*: Google `transparency = transparent` |
| title 🔒 | text (`EncryptedText`, AAD `calendar_event.title`) | no | `""` allowed for untitled |
| imported_at | timestamptz | no | |

Constraint `uq_calendar_event_day_ext UNIQUE (day_date, external_id)`; index `ix_calendar_event_day (day_date)`.

### 4.3 `schedule_block_override` *(added — user decision 2026-11-09)*
Per-date change of one weekly block, so I can manually make room for a task on a specific day without editing the
weekly schedule.

| Column | Type | Null | Default / notes |
|---|---|---|---|
| id | uuid PK | no | |
| local_date | date | no | the date of the block **occurrence** (the date it starts on) |
| block_id | uuid FK → `fixed_schedule_block.id` ON DELETE CASCADE | no | |
| action | varchar enum `skip, adjust` | no | `skip` = block doesn't apply that date; `adjust` = use the times below |
| start_local, end_local | time | yes | required iff `action = adjust`; `end < start` ⇒ crosses midnight |
| is_hard | bool | yes | optional per-date hardness change (null = keep block's) |

Constraint `UNIQUE (local_date, block_id)`. Rows with `local_date < today − 30 days` are pruned opportunistically.

Migration: M2 creates all three tables. No FKs to other modules.

## 5. Public interface

```python
class ScheduleService:
    def __init__(self, session: AsyncSession, settings: AppSettingsService, clock: Clock) -> None: ...
    async def busy_intervals(self, local_date: date) -> list[BusyInterval]: ...  # canonical (plan §4.1)
    async def free_slots(self, local_date: date) -> list[TimeInterval]: ...  # canonical
    # used by api.py
    async def list_blocks(self) -> list[BlockOut]: ...
    async def replace_blocks(self, blocks: list[BlockIn]) -> ReplaceBlocksResult: ...
    async def replace_calendar(
        self, local_date: date, events: list[CalendarEventIn]
    ) -> CalendarImportResult: ...
    async def forget_calendar(self, local_date: date) -> int: ...
    async def day_window(self, local_date: date) -> TimeInterval: ...
    async def list_overrides(self, local_date: date) -> list[BlockOverrideOut]: ...
    async def upsert_override(
        self, local_date: date, block_id: UUID, o: BlockOverrideIn
    ) -> BlockOverrideOut: ...
    async def delete_override(self, local_date: date, block_id: UUID) -> None: ...
```

```python
BlockKind = Literal["work", "sleep", "commute", "meal", "personal", "other"]


class BusyInterval(BaseModel):
    start_at: datetime  # UTC, aware, clipped to the day window
    end_at: datetime  # UTC, > start_at
    label: str  # decrypted label / event title ("" allowed)
    source: Literal["fixed", "calendar"]
    is_hard: bool
    kind: BlockKind | None  # fixed blocks only; None for calendar
    ref_id: UUID  # block id or calendar_event id (feasibility exposes it so the app can offer "adjust for this day")
    clipped: bool  # true if it extends beyond the day window
    overridden: bool = False  # fixed blocks: a per-date override (adjust) was applied


class TimeInterval(BaseModel):
    start_at: datetime
    end_at: datetime  # UTC
    minutes: int  # floor((end-start)/60s)


class BlockIn(BaseModel):
    id: UUID | None = (
        None  # existing block → updated in place (keeps its per-date overrides); None → new block
    )
    weekday: int  # 0..6
    start_local: time
    end_local: time  # "HH:MM" or "HH:MM:SS" with :00 seconds
    label: str  # 1..80 chars after strip
    kind: BlockKind
    is_hard: bool = True
    active: bool = True


class BlockOut(BlockIn):
    id: UUID
    crosses_midnight: bool
    minutes: int


class OverlapWarning(BaseModel):
    a: int
    b: int
    minutes: int  # indexes into the payload/response list


class ReplaceBlocksResult(BaseModel):
    blocks: list[BlockOut]
    warnings: list[OverlapWarning]


class CalendarEventIn(BaseModel):
    external_id: str  # 1..1024
    title: str = ""  # ≤ 500
    all_day: bool = False
    start_at: AwareDatetime | None = None  # required when not all_day
    end_at: AwareDatetime | None = None
    start_date: date | None = None  # required when all_day (Google start.date)
    end_date: date | None = None  # exclusive (Google end.date)
    show_as_free: bool = False


class CalendarEventOut(BaseModel):
    id: UUID
    external_id: str
    title: str
    all_day: bool
    show_as_free: bool
    start_at: datetime
    end_at: datetime


class CalendarImportResult(BaseModel):
    date: date
    imported: int
    events: list[CalendarEventOut]


class BlockOverrideIn(BaseModel):
    action: Literal["skip", "adjust"]
    start_local: time | None = None
    end_local: time | None = None  # required iff adjust; start != end
    is_hard: bool | None = None


class BlockOverrideOut(BlockOverrideIn):
    id: UUID
    local_date: date
    block_id: UUID
    block_label: str
    block_kind: BlockKind
```

## 6. HTTP endpoints

All `Depends(current_user)`, RFC 7807 errors with `code`.

| Method & path | Request | Response | Errors |
|---|---|---|---|
| `GET /schedule/blocks` | — | 200 `{"blocks":[BlockOut], "warnings":[OverlapWarning]}` (ordered by `position`) | |
| `PUT /schedule/blocks` | `{"blocks":[BlockIn]}` (0..100 items) | 200 `ReplaceBlocksResult` | 422 `schedule.invalid_block`, 422 `schedule.too_many_blocks` |
| `PUT /schedule/calendar/{date}` | `{"events":[CalendarEventIn]}` (0..200) | 200 `CalendarImportResult` | 422 `schedule.invalid_event`, 422 `schedule.event_outside_day`, 422 `schedule.duplicate_external_id`, 422 `schedule.date_out_of_range` |
| `DELETE /schedule/calendar/{date}` | — | 204 (idempotent) | 422 bad date |
| `GET /schedule/free-slots?date=YYYY-MM-DD` | date default = today local | 200 `{"date","timezone","window":TimeInterval,"busy":[BusyInterval],"slots":[TimeInterval],"total_free_min"}` | 422 bad date |
| `GET /schedule/overrides/{date}` | — | 200 `[BlockOverrideOut]` | 422 bad date |
| `PUT /schedule/overrides/{date}/{block_id}` | `BlockOverrideIn` | 200 `BlockOverrideOut` (upsert) | 404 unknown/inactive block; 422 `schedule.invalid_override`; 422 `schedule.date_in_past` (date < today local); 422 `schedule.block_not_on_date` (block's weekday ≠ date's weekday) |
| `DELETE /schedule/overrides/{date}/{block_id}` | — | 204 (idempotent) | 422 bad date |

Example `PUT /schedule/blocks`:
```json
{"blocks":[
 {"weekday":0,"start_local":"09:00","end_local":"17:30","label":"Office","kind":"work","is_hard":true},
 {"weekday":6,"start_local":"23:30","end_local":"07:00","label":"Sleep","kind":"sleep","is_hard":true},
 {"weekday":0,"start_local":"12:30","end_local":"13:15","label":"Lunch","kind":"meal","is_hard":false}]}
```
→ `200 {"blocks":[…3 with ids, "crosses_midnight": false/true/false…],"warnings":[{"a":0,"b":2,"minutes":45}]}`

Example `PUT /schedule/calendar/2026-11-09`:
```json
{"events":[
 {"external_id":"abc123_20261109T090000Z","title":"Dentist","start_at":"2026-11-09T15:00:00+01:00","end_at":"2026-11-09T15:45:00+01:00"},
 {"external_id":"bday77","title":"Anna's birthday","all_day":true,"start_date":"2026-11-09","end_date":"2026-11-10"}]}
```

Example `GET /schedule/free-slots?date=2026-11-09` (tz Europe/Berlin, UTC+1): window `2026-11-08T23:00Z–2026-11-09T23:00Z`; busy = Sleep (Sun block, clipped to 23:00Z–06:00Z), Office 08:00Z–16:30Z, Lunch 11:30Z–12:15Z (soft), Dentist 14:00Z–14:45Z; slots = `06:00Z–08:00Z (120)`, `16:30Z–23:00Z (390)`; `total_free_min = 510`.

## 7. Behaviour & rules

### 7.1 Local → UTC (DST-safe)
`local_to_utc(d, t, tz) = datetime.combine(d, t).replace(tzinfo=tz, fold=0).astimezone(UTC)`.
- Spring-forward gap (e.g. Europe/Berlin 2026-03-29 02:00–03:00): non-existent times map forward by the gap length (02:30 → 03:30 local = 01:30Z).
- Fall-back overlap (2026-10-25 02:00–03:00 occurs twice): `fold=0` ⇒ the first (DST) occurrence.
- `day_window(d) = [local_to_utc(d, 00:00), local_to_utc(d+1, 00:00))` — 23 h, 24 h or 25 h long.
`tz = await settings.tz()` on every call (no caching across requests; tz can change).

### 7.2 Fixed blocks for a date (`block_intervals_for_date`)
For `d` and active blocks:
1. Blocks with `weekday == d.weekday()`: `start = local_to_utc(d, start_local)`; `end = local_to_utc(d, end_local)` if `end_local > start_local` else `local_to_utc(d+1, end_local)`.
2. Blocks with `weekday == (d − 1 day).weekday()` **and** `end_local < start_local` (crossing midnight into `d`): `start = local_to_utc(d−1, start_local)`, `end = local_to_utc(d, end_local)`.
3. **Overrides** (§4.3) are applied per occurrence *before* clipping, keyed by the occurrence's start date
   (`d` in step 1, `d−1` in step 2): `skip` → drop the occurrence; `adjust` → recompute start/end from the
   override times with the same midnight rule, `is_hard` from the override if set; mark `overridden=true`.
4. Clip each to `day_window(d)`; drop if `end ≤ start` after clipping or because of a DST gap; set `clipped` when clipping occurred.

### 7.3 Calendar events for a date
Rows with `day_date ∈ {d−1, d, d+1}`, `all_day = false`, `show_as_free = false`, intersecting `day_window(d)`; de-duplicated by `external_id` (prefer the row with `day_date = d`). Clipped to the window. `is_hard = SCHEDULE_CALENDAR_EVENTS_HARD` (default `true`). **All-day events and show-as-free events are stored but excluded** from busy intervals and free slots (birthdays/holidays would otherwise block the entire day); feasibility may still mention them in a later version.

### 7.4 `busy_intervals(d)`
Fixed (§7.2) ∪ calendar (§7.3), labels decrypted, sorted by `(start_at, end_at, source)`. Not merged — callers need individual items (hard vs soft, labels for messages).

### 7.5 `free_slots(d)`
1. `W = day_window(d)`; `B = [b for b in busy_intervals(d) if b.is_hard]` — **soft blocks are not busy time**
   (user decision 2026-11-09): they only produce a warning when a task overlaps them (feasibility).
2. Sort by start; merge intervals that overlap or touch (`next.start ≤ cur.end`).
3. Complement within `W`: gaps between `W.start`, merged intervals, `W.end`.
4. Drop gaps shorter than `SCHEDULE_FREE_SLOT_MIN_MIN` (default 5); `minutes = floor(seconds/60)`.
Past time is not removed (feasibility handles "now"). Free slots are not reduced by planned tasks.

### 7.5a Per-date overrides
- Created from the app when a task conflicts with a block ("Adjust schedule for this day") or from the schedule
  screen. Only for `date ≥ today` (local) and blocks whose weekday matches the date.
- `adjust` validation: `start_local ≠ end_local`, seconds = 0. Upsert replaces any previous override for that pair.
- Overrides affect `busy_intervals`/`free_slots` for that date only; the weekly block is untouched.

### 7.6 `PUT /schedule/blocks` (full replace)
- Items with an `id` that exists are **updated in place** (overrides kept); items without `id` are inserted;
  existing blocks absent from the payload are deleted (their overrides cascade). Unknown `id` → 422.
- Validate every item: weekday 0..6; times with seconds = 0; `start_local ≠ end_local` (a 24 h block is not representable — use two blocks); label 1..80 after strip; ≤ 100 items.
- One transaction: `DELETE FROM fixed_schedule_block`; insert all with new UUIDs and `position = index`. Empty list clears the schedule. Ids are **not** stable across PUTs (clients must not store them).
- Overlaps are **allowed** (soft lunch inside hard work hours is normal). Warnings are computed among active blocks in minute-of-week space `[0, 10080)`: block interval `[weekday·1440 + start_min, … + duration)` where duration wraps across midnight; intervals passing `10080` wrap to week start (Sunday-night sleep into Monday). Every overlapping pair `(a<b)` yields `OverlapWarning{a,b,minutes}`. `GET` recomputes warnings the same way.

### 7.7 `PUT /schedule/calendar/{date}` (atomic replace, consented)
- The request **is** the consent: it is only sent after the user taps "use calendar" for that date (P6, mobile `calendar_connect`). The server never fetches calendar data.
- `date ∈ [today − 1, today + SCHEDULE_CALENDAR_MAX_FUTURE_DAYS]` (422 otherwise).
- Phone normalization contract: request `events.list(primary, timeMin, timeMax = date's local window, singleEvents=true)`; drop `status = cancelled` and events the user declined; map `transparency = transparent` → `show_as_free=true`; timed → `start_at/end_at` (aware RFC 3339); all-day → `all_day=true`, `start_date/end_date` (exclusive).
- Validation: timed requires `start_at < end_at`, intersecting `day_window(date)`; all-day requires `start_date < end_date` and `start_date ≤ date < end_date`; `external_id` unique within payload. Any failure → 422 for the whole payload (nothing written).
- All-day storage: `start_at = local_to_utc(max(start_date, date), 00:00)`, `end_at = local_to_utc(min(end_date, date+1), 00:00)`.
- One transaction: `DELETE FROM calendar_event WHERE day_date = :date`; insert all with `imported_at = now`. Empty list = "consented, nothing scheduled" (zero rows; same storage as DELETE).
- Retention: in the same transaction delete rows with `day_date < today − SCHEDULE_CALENDAR_RETENTION_DAYS`.
- `DELETE /schedule/calendar/{date}` removes that date's rows (withdrawal of consent); 204 even if none.

## 8. Configuration
| Setting | Default | Meaning |
|---|---|---|
| `SCHEDULE_MAX_BLOCKS` | 100 | max blocks per PUT |
| `SCHEDULE_CALENDAR_MAX_EVENTS` | 200 | max events per import |
| `SCHEDULE_CALENDAR_MAX_FUTURE_DAYS` | 30 | latest importable date |
| `SCHEDULE_CALENDAR_RETENTION_DAYS` | 30 | imported events older than this are pruned |
| `SCHEDULE_CALENDAR_EVENTS_HARD` | `true` | `is_hard` for timed calendar events |
| `SCHEDULE_FREE_SLOT_MIN_MIN` | 5 | minimum free-slot length |

## 9. Errors & degradation
- 422 `DomainValidationError` with per-item `errors: [{"index": i, "field": "...", "msg": "..."}]`.
- No external calls → no upstream degradation. If no blocks and no events exist, `busy_intervals = []` and `free_slots = [whole window]`.
- Decryption failure → 500 via core (logged with row id only).

## 10. Security & privacy
- `label` and `title` are 🔒 (`EncryptedText`); `external_id` is an opaque Google id, stored plaintext for the unique constraint.
- Calendar rows exist only for consented dates and are pruned after 30 days; DELETE withdraws consent for a date.
- No Google tokens, emails or attendee lists are accepted (extra fields in the payload are rejected: `model_config = ConfigDict(extra="forbid")`).
- Logs: counts and dates only, never labels/titles.

## 11. Testing plan
Fixtures: `db_session`, `fake_clock`, `tz_berlin` (DST tests), `tz_new_york`, `api_client`, `raw_conn`, factory `block(weekday, "HH:MM", "HH:MM", hard=True)`.

Unit (`intervals.py`): `test_day_window_normal_24h`, `test_day_window_spring_forward_23h` (Berlin 2026-03-29), `test_day_window_fall_back_25h` (Berlin 2026-10-25), `test_local_to_utc_gap_shifts_forward`, `test_local_to_utc_ambiguous_first_occurrence`, `test_block_same_day`, `test_block_crossing_midnight_split_across_two_dates`, `test_sunday_block_crossing_into_monday`, `test_block_inside_dst_gap_dropped`, `test_merge_touching_and_overlapping`, `test_subtract_produces_gaps`, `test_free_slot_min_length_filter`, `test_weekly_overlaps_wraparound`.

Integration: `test_put_blocks_replaces_all`, `test_put_blocks_empty_clears`, `test_put_blocks_rejects_equal_times`, `test_put_blocks_returns_overlap_warnings`, `test_inactive_blocks_ignored`, `test_put_calendar_atomic_replace`, `test_put_calendar_invalid_event_writes_nothing`, `test_put_calendar_event_outside_day_422`, `test_put_calendar_duplicate_external_id_422`, `test_all_day_event_stored_not_busy`, `test_show_as_free_not_busy`, `test_event_spanning_midnight_imported_both_days_deduped`, `test_delete_calendar_idempotent`, `test_calendar_retention_prunes_old_rows`, `test_busy_intervals_labels_decrypted_sorted`, `test_free_slots_endpoint_example`, `test_encrypted_label_and_title_raw_rows`, `test_extra_fields_rejected`.

## 12. Acceptance criteria
| ID | Given / When / Then | Test |
|---|---|---|
| SCHED-AC-01 | Given blocks exist, When PUT with a new list, Then exactly the new list is stored (full replace) | `test_put_blocks_replaces_all` |
| SCHED-AC-02 | Given a Sunday 23:30–07:00 sleep block, When busy intervals for Monday are requested, Then it contributes 00:00–07:00 local (clipped) | `test_sunday_block_crossing_into_monday` |
| SCHED-AC-03 | Given Europe/Berlin, When the window for 2026-03-29 / 2026-10-25 is computed, Then it is 23 h / 25 h | `test_day_window_spring_forward_23h`, `test_day_window_fall_back_25h` |
| SCHED-AC-04 | Given overlapping soft and hard blocks, When PUT, Then 200 with an overlap warning (not an error) | `test_put_blocks_returns_overlap_warnings` |
| SCHED-AC-05 | Given an import for a date, When re-imported with different events, Then only the new events remain; an invalid event rejects the whole payload | `test_put_calendar_atomic_replace`, `test_put_calendar_invalid_event_writes_nothing` |
| SCHED-AC-06 | Given an all-day or show-as-free event, Then it is stored but not part of busy intervals or free-slot subtraction | `test_all_day_event_stored_not_busy`, `test_show_as_free_not_busy` |
| SCHED-AC-07 | Given fixed blocks and timed events, When free slots are requested, Then they equal the day window minus the merged **hard** busy intervals (fixed hard blocks + calendar events), dropping gaps < 5 min | `test_free_slots_endpoint_example`, `test_free_slot_min_length_filter` |
| SCHED-AC-08 | Labels and titles are never stored in plaintext | `test_encrypted_label_and_title_raw_rows` |
| SCHED-AC-09 | DELETE calendar for a date removes its rows and is idempotent | `test_delete_calendar_idempotent` |
| SCHED-AC-10 | Calendar data older than 30 days is pruned on the next import | `test_calendar_retention_prunes_old_rows` |
| SCHED-AC-OV1 | Given a hard Office block Mon 09:00–17:30 and an override `skip` for 2026-11-09, When busy intervals are requested for that date, Then Office is absent; the following Monday it is present | `test_override_skip_applies_only_to_date` |
| SCHED-AC-OV2 | Given an override `adjust 10:00–14:00`, Then the block occupies 10:00–14:00 that date with `overridden=true` | `test_override_adjust_times` |
| SCHED-AC-OV3 | Given a soft Lunch block, When free slots are requested, Then Lunch does not reduce free time | `test_free_slots_ignore_soft_blocks` |
| SCHED-AC-OV4 | Given a PUT that includes an existing block id, Then the block keeps its overrides | `test_put_blocks_keeps_ids_and_overrides` |
| SCHED-AC-OV5 | Override for a past date → 422 `schedule.date_in_past` | `test_override_past_date_rejected` |

## 13. Open questions
1. ~~Soft blocks in free slots~~ — resolved 2026-11-09: soft blocks are excluded from busy time; overlap → warning only; per-date overrides (§4.3) let me rearrange a day manually.
2. All-day events are excluded from busy time. Should some (e.g. "Out of office") count? Would need a phone-side flag.
3. Calendar retention (30 days) and `show_as_free` are not in the plan; both privacy/accuracy additions — confirm and add to plan §5.3.
4. No `GET /schedule/calendar/{date}`: the phone already holds the events it imported. Add if the app needs to show what the server stored.

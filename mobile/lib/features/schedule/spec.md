# Feature Spec — `schedule` (mobile)

> Flutter feature · Governed by [`constitution.md`](../../../../constitution.md) and [`plan.md`](../../../../plan.md) §5.3, §7.
> Editor for the weekly fixed schedule (work, sleep, commute, …) that feasibility uses to find free time.

## 1. Purpose & scope

| Capability | Role |
|---|---|
| C4 | View/edit fixed weekly blocks (`GET/PUT /schedule/blocks`); preview free slots for a date |

Out of scope: Google Calendar import (calendar_connect), per-day overrides (deferred).

## 2. Folder layout

```
features/schedule/
├── spec.md
├── data/
│   ├── schedule_api.dart          # GET/PUT /schedule/blocks, GET /schedule/free-slots
│   └── dto.dart                   # BlockDto, FreeSlotDto, ReplaceResultDto (json_serializable)
├── domain/
│   ├── block.dart                 # ScheduleBlock entity, BlockKind enum
│   ├── validation.dart            # pure validation (duration, label, per-day count)
│   └── edits.dart                 # pure helpers: copyDayTo(), sortBlocks(), crossesMidnight()
└── presentation/
    ├── schedule_screen.dart       # /settings/schedule — weekday tabs
    ├── block_editor_sheet.dart    # add/edit bottom sheet
    ├── free_slots_preview.dart    # date picker + slot list
    └── providers.dart
```

## 3. Dependencies

- Features: `app_shell` (`apiClientProvider`, `AppError`, `serverStatusProvider`, `clockProvider`, `appLocationProvider`, `LocalDate`).
- Packages: flutter_riverpod, freezed, json_serializable, go_router.

## 4. Local data

None persisted. Edits are held in memory until **Save** (one `PUT` = full replace).

## 5. Public interface

```dart
enum BlockKind { work, sleep, commute, meal, personal, other }
@freezed class ScheduleBlock { String? id; int weekday /*0=Mon..6=Sun*/; TimeOfDay startLocal; TimeOfDay endLocal;
  String label; BlockKind kind; bool isHard; bool active; }

final scheduleEditorProvider = AsyncNotifierProvider<ScheduleEditor, ScheduleEditorState>(...);
//   load(); addBlock(ScheduleBlock); updateBlock(int index, ScheduleBlock); removeBlock(int index);
//   copyDay(int fromWeekday, List<int> toWeekdays); Future<SaveResult> save(); bool get dirty;
@freezed class ScheduleEditorState { List<ScheduleBlock> blocks; List<OverlapWarning> warnings; bool saving; }

final freeSlotsProvider = FutureProvider.family<List<FreeSlot>, LocalDate>(...);   // GET /schedule/free-slots
@freezed class FreeSlot { DateTime startAt; DateTime endAt; int minutes; }

// Per-date manual adjustment of one weekly block (used by tasks' VerdictCard and the Day overrides list)
abstract final class BlockOverrideSheet {
  static Future<bool> show(BuildContext c, LocalDate date, {required String blockId, required String label,
      required DateTime startAt, required DateTime endAt, required bool isHard});   // true if saved
}
final dayOverridesProvider = FutureProvider.family<List<BlockOverride>, LocalDate>(...);  // GET /schedule/overrides/{date}
@freezed class BlockOverride { String blockId; String blockLabel; LocalDate date; OverrideAction action;
  TimeOfDay? startLocal; TimeOfDay? endLocal; bool? isHard; }
enum OverrideAction { skip, adjust }
```
Route: `/settings/schedule` (entry from Settings screen: "Weekly schedule").

## 6. Backend endpoints used

| Endpoint | Request | Response |
|---|---|---|
| `GET /api/v1/schedule/blocks` | — | `[{id, weekday, start_local "HH:MM", end_local, label, kind, is_hard, active}]` |
| `PUT /api/v1/schedule/blocks` | `[{weekday, start_local, end_local, label, kind, is_hard, active}]` (full list) | `{blocks:[…], warnings:[{a, b, minutes}]}` |
| `GET /api/v1/schedule/overrides/{date}` | — | `[{block_id, block_label, block_kind, action, start_local?, end_local?, is_hard?}]` |
| `PUT /api/v1/schedule/overrides/{date}/{block_id}` | `{action: "skip"\|"adjust", start_local?, end_local?, is_hard?}` | override |
| `DELETE /api/v1/schedule/overrides/{date}/{block_id}` | — | 204 |
| `GET /api/v1/schedule/free-slots?date=YYYY-MM-DD` | — | `{date, timezone, window, busy:[…], slots:[{start_at, end_at, minutes}], total_free_min}` (UTC); the app uses `slots` and `total_free_min` |

## 7. Screens & UX flow

**Schedule screen** — AppBar "Weekly schedule" + Save (enabled when dirty). `TabBar` Mon…Sun.
Each tab: list of blocks sorted by start (`06:30–07:15 · Commute · Hard`), crossing-midnight blocks show "→ next
day". Row tap → editor sheet; swipe → delete (with undo snackbar). FAB "Add block". Overflow menu: "Copy this day
to…" (multi-select weekdays dialog; "Weekdays" / "Weekend" shortcuts), "Preview free time".
States: loading (skeleton), waking server (`WakingServerBanner` from app_shell), error (retry), empty
("No fixed commitments yet — add work hours, sleep, commute…").
Leaving with unsaved changes → confirm dialog "Discard changes?".

**Block editor sheet** — fields: kind (chips), label (text, prefilled from kind e.g. "Work"), start time, end time
(time pickers, 5-min steps), Hard/Soft toggle with help text ("Hard: nothing can be planned here. Soft: you'll get
a warning."), Active toggle. Buttons Save / Cancel.

**BlockOverrideSheet** (opened from the VerdictCard's "Adjust for this day" or from the Day overrides list) —
title "Adjust '{label}' on Mon 9 Nov only" · options: **Skip it this day** · **Change its time this day** (start/end
pickers, prefilled with the block's times; optional Hard/Soft toggle) · link "Edit weekly schedule instead" →
`/settings/schedule`. Save → `PUT /schedule/overrides/{date}/{block_id}` → returns `true` (caller re-runs the
feasibility check). A "Remove adjustment" button appears when an override exists (→ `DELETE`).

**Day overrides list** — in the schedule screen overflow: "Adjustments for a date" → date picker → list of
overrides for that date with edit/remove.

**Free-time preview** — date picker (default today) → `freeSlotsProvider(date)` → list `09:00–10:30 (90 min)`.

## 8. Behaviour & rules

- `end == start` invalid; `end < start` means the block crosses midnight (allowed, shown with "→ next day").
- Duration ≥ 5 min; label 1–80 chars after trim; ≤ 20 blocks per weekday.
- Overlaps within a weekday are allowed but highlighted; server `warnings` shown after save as a banner listing
  the overlapping pairs.
- Defaults by kind: sleep → hard, work → hard, commute → hard, meal → soft, personal → soft, other → soft.
- Existing blocks are sent **with their `id`** so the server updates them in place and keeps their per-date
  overrides; new blocks are sent without `id`.
- Soft blocks never reduce free time; they only cause a warning when a task overlaps them.
- Save → `PUT` the full list → replace state with server response (ids) → invalidate `freeSlotsProvider` and
  ask tasks to refresh (`currentDayControllerProvider.refresh()`), because feasibility uses the new schedule.
- Times are local wall-clock; the server converts to UTC per date (DST-safe).

## 9. Platform configuration

None.

## 10. Errors & offline behaviour

Offline → Save disabled with "You're offline"; edits stay in memory. 422 → field errors mapped to blocks by index
(`ValidationError.fieldErrors` keys like `3.end_local`). Cold-start retries via `ApiClient`.

## 11. Testing plan

Unit: `validation_rejects_zero_length`, `validation_allows_cross_midnight`, `copy_day_replaces_target_days`,
`kind_defaults_hardness`, `sort_blocks_by_start`.
Widget: `schedule_screen_shows_tabs_and_blocks`, `editor_sheet_validation_messages`, `unsaved_changes_dialog`,
`save_shows_overlap_warnings`, `empty_state`.
Integration (mock API): edit → save → PUT payload equals full list; free-slot preview renders server slots.

## 12. Acceptance criteria

- **M-SCHED-AC-01** Given saved blocks, When I open the screen, Then each weekday tab lists its blocks sorted by start time.
- **M-SCHED-AC-02** Given I add "Sleep 23:00–07:00", Then it is accepted and shown as crossing midnight.
- **M-SCHED-AC-03** When I tap Save, Then a single `PUT /schedule/blocks` with the full list is sent and server warnings are shown.
- **M-SCHED-AC-04** Given "Copy Monday to Weekdays", Then Tue–Fri blocks equal Monday's (previous Tue–Fri blocks replaced).
- **M-SCHED-AC-05** Given unsaved edits, When I navigate back, Then a discard confirmation appears.
- **M-SCHED-AC-06** After a successful save, the Today screen data is refreshed.

- **M-SCHED-AC-07** Given a task overlapping my soft Lunch block, When I tap "Adjust for this day" and choose Skip, Then `PUT /schedule/overrides/{date}/{block_id}` `{action:"skip"}` is sent, the weekly schedule is unchanged, and the feasibility check re-runs.
- **M-SCHED-AC-08** Given "Change its time this day" 14:00–14:45, Then only that date's block moves.

## 13. Open questions

None (per-date overrides added 2026-11-09).

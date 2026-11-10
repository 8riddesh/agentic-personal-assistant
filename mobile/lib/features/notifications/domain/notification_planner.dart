import 'package:timezone/timezone.dart' as tz;

import '../../app_shell/domain/format.dart';
import '../../app_shell/domain/local_date.dart';
import '../../tasks/domain/entities.dart';
import 'notification_ids.dart';
import 'notification_payload.dart';
import 'notification_texts.dart';

export 'notification_ids.dart' show NotificationSlot;

/// Exact alarms when the OS allows them, otherwise inexact (R11).
enum ScheduleMode { exact, inexact }

/// What the planner needs to know about a task (a projection of tasks' `Task`).
class TaskSnapshot {
  const TaskSnapshot({
    required this.id,
    required this.title,
    required this.localDate,
    required this.status,
    this.startAt,
    this.predictedEndAt,
    this.checkResponse,
  });

  factory TaskSnapshot.fromTask(Task t) => TaskSnapshot(
        id: t.id,
        title: t.title,
        localDate: t.localDate,
        status: t.status,
        startAt: t.startAt,
        predictedEndAt: t.predictedEndAt,
        checkResponse: t.checkResponse,
      );

  final String id;
  final String title;
  final LocalDate localDate;
  final TaskStatus status;
  final DateTime? startAt;
  final DateTime? predictedEndAt;
  final CheckResponse? checkResponse;
}

/// A user-requested "ask me once more" (only exists after an explicit ETA choice).
class FollowUp {
  const FollowUp({required this.taskId, required this.fireAt, required this.etaMin});

  final String taskId;
  final DateTime fireAt;
  final int etaMin;
}

class PlannerInput {
  const PlannerInput({
    required this.dayDate,
    required this.dayState,
    required this.tasks,
    required this.nowUtc,
    required this.location,
    required this.reminderOffsetsMin,
    required this.exactAllowed,
    this.followUps = const [],
    this.checksEnabled = false,
  });

  final LocalDate dayDate;
  final DayState dayState;
  final List<TaskSnapshot> tasks;
  final List<FollowUp> followUps;
  final DateTime nowUtc;
  final tz.Location location;
  final List<int> reminderOffsetsMin;
  final bool exactAllowed;

  /// The completion check and follow-ups ship with M3 (predictor). While `false`, only T-60/T-30 reminders exist.
  final bool checksEnabled;
}

class DesiredNotification {
  const DesiredNotification({
    required this.id,
    required this.taskId,
    required this.slot,
    required this.fireAt,
    required this.channelId,
    required this.title,
    required this.body,
    required this.actionIds,
    required this.timeoutAtUtc,
    required this.mode,
    required this.payload,
    required this.contentHash,
  });

  final int id;
  final String taskId;
  final NotificationSlot slot;
  final tz.TZDateTime fireAt;
  final String channelId;
  final String title;
  final String body;
  final List<String> actionIds;
  final DateTime timeoutAtUtc;
  final ScheduleMode mode;
  final String payload;
  final String contentHash;
}

class _Spec {
  _Spec({
    required this.task,
    required this.slot,
    required this.fireAt,
    required this.channelId,
    required this.title,
    required this.body,
    required this.actionIds,
    required this.timeoutAtUtc,
  });

  final TaskSnapshot task;
  final NotificationSlot slot;
  final DateTime fireAt;
  final String channelId;
  final String title;
  final String body;
  final List<String> actionIds;
  final DateTime timeoutAtUtc;
}

const String remindersChannel = 'reminders';
const String checksChannel = 'checks';
const List<String> checkActionIds = ['done', 'not_yet', 'not_yet_eta'];

/// Reminder timeout after the start (capped at day end).
const Duration reminderTimeoutAfterStart = Duration(minutes: 15);

/// zonedSchedule rejects past instants, so a fire time must be later than `now + 5 s`.
const Duration scheduleGuard = Duration(seconds: 5);

/// The notifications that should exist for the open day (notifications spec §8.2, rules R1-R13). Pure.
List<DesiredNotification> planNotifications(
  PlannerInput input, {
  NotificationTexts texts = const NotificationTexts(),
  IdHasher hasher = fnv1a32,
}) {
  if (input.dayState != DayState.open) return const []; // R1
  final loc = input.location;
  final dayEnd = input.dayDate.endExclusive(loc);
  if (!input.nowUtc.isBefore(dayEnd)) return const []; // R2: stale day, not yet refreshed
  final guard = input.nowUtc.add(scheduleGuard);

  bool include(DateTime t) => t.isAfter(guard) && t.isBefore(dayEnd);

  // R6/R7: first two distinct positive offsets, order kept.
  final offsets = <int>[];
  for (final o in input.reminderOffsetsMin) {
    if (o > 0 && !offsets.contains(o)) offsets.add(o);
    if (offsets.length == 2) break;
  }
  final followUps = {for (final f in input.followUps) f.taskId: f};

  final specs = <_Spec>[];
  for (final t in input.tasks) {
    if (t.localDate != input.dayDate) continue; // R3
    if (t.status != TaskStatus.planned) continue; // R4
    final start = t.startAt;
    if (start == null) continue; // R5
    final startHm = formatHm(start, loc);
    final end = t.predictedEndAt;

    for (var i = 0; i < offsets.length; i++) {
      final fireAt = start.subtract(Duration(minutes: offsets[i]));
      if (!include(fireAt)) continue;
      final text = texts.reminder(
        offsetMin: offsets[i],
        taskTitle: t.title,
        startHm: startHm,
        endHm: end == null ? null : formatHm(end, loc),
        first: i == 0,
      );
      final timeout = start.add(reminderTimeoutAfterStart);
      specs.add(_Spec(
        task: t,
        slot: i == 0 ? NotificationSlot.reminder1 : NotificationSlot.reminder2,
        fireAt: fireAt,
        channelId: remindersChannel,
        title: text.title,
        body: text.body,
        actionIds: const [],
        timeoutAtUtc: timeout.isAfter(dayEnd) ? dayEnd : timeout,
      ));
    }

    if (!input.checksEnabled) continue;

    // R8: one completion check at the predicted end. R10: a past check is never re-scheduled.
    if (end != null && end.isAfter(start) && t.checkResponse == null && include(end)) {
      final text = texts.check(taskTitle: t.title, predictedHm: formatHm(end, loc));
      specs.add(_Spec(
        task: t,
        slot: NotificationSlot.check,
        fireAt: end,
        channelId: checksChannel,
        title: text.title,
        body: text.body,
        actionIds: checkActionIds,
        timeoutAtUtc: dayEnd,
      ));
    }

    // R9: follow-up only when the user asked for it.
    final followUp = followUps[t.id];
    if (followUp != null && include(followUp.fireAt)) {
      final text = texts.followUp(taskTitle: t.title, fireHm: formatHm(followUp.fireAt, loc));
      specs.add(_Spec(
        task: t,
        slot: NotificationSlot.followUp,
        fireAt: followUp.fireAt,
        channelId: checksChannel,
        title: text.title,
        body: text.body,
        actionIds: checkActionIds,
        timeoutAtUtc: dayEnd,
      ));
    }
  }

  final bases = assignBases(specs.map((s) => s.task.id), hasher: hasher);
  final mode = input.exactAllowed ? ScheduleMode.exact : ScheduleMode.inexact; // R11
  final result = <DesiredNotification>[];
  for (final s in specs) {
    final fireUtc = s.fireAt.toUtc();
    final hash = fnv1a32('${s.slot.index}|${fireUtc.toIso8601String()}|${s.title}|${s.body}|${mode.name}')
        .toRadixString(16); // R12
    final payload = NotificationPayload(
      taskId: s.task.id,
      slot: s.slot,
      fireAtUtc: fireUtc,
      date: input.dayDate.toIso(),
      hash: hash,
      title: s.task.title,
      startAtUtc: s.task.startAt,
    ).encode();
    result.add(DesiredNotification(
      id: idFromBase(bases[s.task.id]!, s.slot),
      taskId: s.task.id,
      slot: s.slot,
      fireAt: tz.TZDateTime.from(fireUtc, loc),
      channelId: s.channelId,
      title: s.title,
      body: s.body,
      actionIds: s.actionIds,
      timeoutAtUtc: s.timeoutAtUtc.toUtc(),
      mode: mode,
      payload: payload,
      contentHash: hash,
    ));
  }
  result.sort((a, b) {
    final c = a.fireAt.compareTo(b.fireAt);
    return c != 0 ? c : a.id.compareTo(b.id);
  }); // R13
  return result;
}

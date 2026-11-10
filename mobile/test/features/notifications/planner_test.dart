import 'package:daily_assistant/features/app_shell/domain/local_date.dart';
import 'package:daily_assistant/features/notifications/domain/notification_ids.dart';
import 'package:daily_assistant/features/notifications/domain/notification_payload.dart';
import 'package:daily_assistant/features/notifications/domain/notification_planner.dart';
import 'package:daily_assistant/features/tasks/domain/entities.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/timezone.dart' as tz;

import '../../support/fakes.dart';

const day = LocalDate(2026, 11, 9);
final now = DateTime.utc(2026, 11, 9, 12); // 12:00 in UTC
final dayEnd = DateTime.utc(2026, 11, 10); // local midnight (UTC location)

DateTime at(int h, [int m = 0]) => DateTime.utc(2026, 11, 9, h, m);

PlannerInput input(
  List<TaskSnapshot> tasks, {
  DayState state = DayState.open,
  DateTime? nowUtc,
  List<int> offsets = const [60, 30],
  bool exact = true,
  bool checks = false,
  List<FollowUp> followUps = const [],
  tz.Location? location,
  LocalDate dayDate = day,
}) =>
    PlannerInput(
      dayDate: dayDate,
      dayState: state,
      tasks: tasks,
      followUps: followUps,
      nowUtc: nowUtc ?? now,
      location: location ?? utc,
      reminderOffsetsMin: offsets,
      exactAllowed: exact,
      checksEnabled: checks,
    );

TaskSnapshot task({
  String id = 't1',
  String title = 'Write report',
  DateTime? start,
  DateTime? end,
  TaskStatus status = TaskStatus.planned,
  LocalDate localDate = day,
  CheckResponse? check,
}) =>
    TaskSnapshot(
      id: id,
      title: title,
      localDate: localDate,
      status: status,
      startAt: start,
      predictedEndAt: end,
      checkResponse: check,
    );

List<DateTime> fireTimes(List<DesiredNotification> list) => [for (final n in list) n.fireAt.toUtc()];

void main() {
  setUpAll(initTz);

  group('M-NOTIF-AC-01 reminders at T-60 and T-30', () {
    test('a task at 14:00, now 12:00: exactly two reminders with the right texts', () {
      final result = planNotifications(input([task(start: at(14), end: at(15, 10))]));
      expect(fireTimes(result), [at(13), at(13, 30)]);
      expect(result.map((n) => n.slot), [NotificationSlot.reminder1, NotificationSlot.reminder2]);
      expect(result[0].title, 'In 1 hour: Write report');
      expect(result[0].body, 'Starts at 14:00 · ends ~15:10');
      expect(result[1].title, 'In 30 min: Write report');
      expect(result[1].body, 'Starts at 14:00');
      expect(result.map((n) => n.channelId).toSet(), {remindersChannel});
      expect(result.every((n) => n.actionIds.isEmpty), isTrue);
      expect(result[0].id, notificationId('t1', NotificationSlot.reminder1));
    });

    test('the first reminder omits the end when there is no prediction', () {
      final result = planNotifications(input([task(start: at(14))]));
      expect(result[0].body, 'Starts at 14:00');
    });
  });

  group('rules R1-R5 (what is ignored)', () {
    final timed = task(start: at(14));

    test('R1 a closing or closed day plans nothing', () {
      expect(planNotifications(input([timed], state: DayState.closing)), isEmpty);
      expect(planNotifications(input([timed], state: DayState.closed)), isEmpty);
    });

    test('R2 / N17 a stale day (now >= its local midnight) plans nothing', () {
      expect(planNotifications(input([timed], nowUtc: DateTime.utc(2026, 11, 10, 0, 10))), isEmpty);
      expect(planNotifications(input([timed], nowUtc: dayEnd)), isEmpty);
    });

    test('R3 tasks of another date are ignored', () {
      final other = task(start: at(14), localDate: const LocalDate(2026, 11, 10));
      expect(planNotifications(input([other])), isEmpty);
    });

    test('R4 / M-NOTIF-AC-05 every terminal status is ignored', () {
      for (final status in TaskStatus.values.where((s) => s != TaskStatus.planned)) {
        expect(planNotifications(input([task(start: at(14), status: status)])), isEmpty, reason: status.name);
      }
    });

    test('R5 / M-NOTIF-AC-16 anytime tasks never get a notification', () {
      expect(planNotifications(input([task(), task(id: 't2', end: at(15))], checks: true)), isEmpty);
    });
  });

  group('R6/R7 reminder offsets', () {
    test('R6 / M-NOTIF-AC-03 reminders in the past are dropped, never replayed', () {
      // start 12:45: T-60 = 11:45 is past, T-30 = 12:15 still ahead
      final result = planNotifications(input([task(start: at(12, 45))]));
      expect(fireTimes(result), [at(12, 15)]);
      expect(result.single.slot, NotificationSlot.reminder2);
    });

    test('R6 a fire time within the 5 s schedule guard is dropped (zonedSchedule rejects it)', () {
      expect(planNotifications(input([task(start: now.add(const Duration(minutes: 30, seconds: 5)))])), isEmpty);
      final ok = planNotifications(input([task(start: now.add(const Duration(minutes: 30, seconds: 6)))]));
      expect(ok, hasLength(1));
    });

    test('R6 only the first two offsets are used and order is kept', () {
      final result = planNotifications(input([task(start: at(18))], offsets: const [90, 45, 10]));
      expect(fireTimes(result), [at(16, 30), at(17, 15)]);
    });

    test('R7 duplicate and non-positive offsets collapse', () {
      final result = planNotifications(input([task(start: at(18))], offsets: const [0, -5, 60, 60, 30]));
      expect(fireTimes(result), [at(17), at(17, 30)]);
    });

    test('a single offset gives a single reminder', () {
      expect(planNotifications(input([task(start: at(18))], offsets: const [15])), hasLength(1));
    });
  });

  group('M-NOTIF-AC-04 nothing at or after local midnight', () {
    test('a reminder before midnight stays, one exactly at midnight is dropped', () {
      final start = DateTime.utc(2026, 11, 10, 0, 5); // belongs to today in the data, starts after midnight
      final before = planNotifications(input([task(start: start)], offsets: const [10]));
      expect(fireTimes(before), [DateTime.utc(2026, 11, 9, 23, 55)]);
      final atMidnight = planNotifications(input([task(start: start)], offsets: const [5]));
      expect(atMidnight, isEmpty);
    });

    test('the day end is the real local midnight on a DST day (25 h day in Bucharest)', () {
      const dstDay = LocalDate(2026, 10, 25); // clocks go back: the day ends at 22:00Z
      final start = DateTime.utc(2026, 10, 25, 22, 30);
      final result = planNotifications(input(
        [task(start: start, localDate: dstDay)],
        dayDate: dstDay,
        nowUtc: DateTime.utc(2026, 10, 25, 20),
        location: bucharest,
        offsets: const [60, 30],
      ));
      // T-60 = 21:30Z (< 22:00Z, kept); T-30 = 22:00Z (== local midnight, dropped)
      expect(fireTimes(result), [DateTime.utc(2026, 10, 25, 21, 30)]);
    });
  });

  group('R8/R10 the completion check (ships with M3, behind checksEnabled)', () {
    test('M1: with checks disabled only reminders exist', () {
      final result = planNotifications(input([task(start: at(14), end: at(15, 10))]));
      expect(result.map((n) => n.slot), isNot(contains(NotificationSlot.check)));
    });

    test('M-NOTIF-AC-02 exactly one check at the predicted end with Done / Not yet actions', () {
      final result = planNotifications(input([task(start: at(14), end: at(15, 10))], checks: true));
      final checks = result.where((n) => n.slot == NotificationSlot.check).toList();
      expect(checks, hasLength(1));
      expect(checks.single.fireAt.toUtc(), at(15, 10));
      expect(checks.single.channelId, checksChannel);
      expect(checks.single.actionIds, checkActionIds);
      expect(checks.single.title, 'Done with Write report?');
      expect(checks.single.body, 'It was predicted to end at 15:10.');
    });

    test('R8 no check without a prediction, with end <= start, or after an answer', () {
      expect(
        planNotifications(input([task(start: at(14))], checks: true)).where((n) => n.slot == NotificationSlot.check),
        isEmpty,
      );
      expect(
        planNotifications(input([task(start: at(14), end: at(14))], checks: true))
            .where((n) => n.slot == NotificationSlot.check),
        isEmpty,
      );
      for (final answer in CheckResponse.values) {
        expect(
          planNotifications(input([task(start: at(14), end: at(15), check: answer)], checks: true))
              .where((n) => n.slot == NotificationSlot.check),
          isEmpty,
          reason: answer.name,
        );
      }
    });

    test('R10 a check that is already past is never scheduled (no catch-up)', () {
      final result = planNotifications(input([task(start: at(8), end: at(11))], checks: true));
      expect(result, isEmpty);
    });

    test('a check at or after local midnight is dropped', () {
      final result = planNotifications(
        input([task(start: at(23), end: DateTime.utc(2026, 11, 10, 0, 30))], checks: true),
      );
      expect(result.where((n) => n.slot == NotificationSlot.check), isEmpty);
    });
  });

  group('R9 / M-NOTIF-AC-10 follow-up only when the user asked', () {
    final followUp = FollowUp(taskId: 't1', fireAt: at(15, 40), etaMin: 30);

    test('exactly one follow-up at the requested time', () {
      final result = planNotifications(
        input([task(start: at(14), end: at(15, 10), check: CheckResponse.notYet)], checks: true, followUps: [followUp]),
      );
      final ups = result.where((n) => n.slot == NotificationSlot.followUp).toList();
      expect(ups, hasLength(1));
      expect(ups.single.fireAt.toUtc(), at(15, 40));
      expect(ups.single.actionIds, checkActionIds);
      // "Not yet" was answered: no automatic check any more (P5)
      expect(result.where((n) => n.slot == NotificationSlot.check), isEmpty);
    });

    test('no follow-up row, nothing; a terminal task or past time drops it', () {
      final planned = task(start: at(14), end: at(15, 10));
      expect(
        planNotifications(input([planned], checks: true)).where((n) => n.slot == NotificationSlot.followUp),
        isEmpty,
      );
      final done = task(start: at(14), status: TaskStatus.completed);
      expect(planNotifications(input([done], checks: true, followUps: [followUp])), isEmpty);
      final past = FollowUp(taskId: 't1', fireAt: at(11), etaMin: 15);
      expect(
        planNotifications(input([planned], checks: true, followUps: [past]))
            .where((n) => n.slot == NotificationSlot.followUp),
        isEmpty,
      );
    });
  });

  group('R11 scheduling mode', () {
    test('exact when allowed, inexact otherwise (M-NOTIF-AC-14)', () {
      final t = [task(start: at(14))];
      expect(planNotifications(input(t)).every((n) => n.mode == ScheduleMode.exact), isTrue);
      expect(planNotifications(input(t, exact: false)).every((n) => n.mode == ScheduleMode.inexact), isTrue);
    });
  });

  group('R12 content hash and payload', () {
    test('the hash is deterministic and part of a decodable payload', () {
      final a = planNotifications(input([task(start: at(14))]));
      final b = planNotifications(input([task(start: at(14))]));
      expect([for (final n in a) n.contentHash], [for (final n in b) n.contentHash]);
      final payload = NotificationPayload.decode(a.first.payload)!;
      expect(payload.hash, a.first.contentHash);
      expect((payload.taskId, payload.slot, payload.date), ('t1', NotificationSlot.reminder1, '2026-11-09'));
      expect(payload.fireAtUtc, at(13));
      expect(payload.startAtUtc, at(14));
    });

    test('a change of time, title or mode changes the hash', () {
      String firstHash(PlannerInput i) => planNotifications(i).first.contentHash;
      final base = firstHash(input([task(start: at(14))]));
      expect(firstHash(input([task(start: at(15))])), isNot(base)); // time
      expect(firstHash(input([task(start: at(14), title: 'Other')])), isNot(base)); // title
      expect(firstHash(input([task(start: at(14))], exact: false)), isNot(base)); // mode
    });
  });

  group('R13 ordering and budget', () {
    test('sorted by fire time, then id, across tasks', () {
      final result = planNotifications(input([
        task(id: 'late', start: at(18)),
        task(id: 'early', start: at(14)),
      ]));
      final times = fireTimes(result);
      expect(times, [...times]..sort());
      expect(result.first.taskId, 'early');
    });

    test('P5: at most four notifications per task (2 reminders + check + follow-up)', () {
      final result = planNotifications(input(
        [task(start: at(14), end: at(15, 10))],
        checks: true,
        followUps: [FollowUp(taskId: 't1', fireAt: at(15, 40), etaMin: 30)],
      ));
      expect(result, hasLength(4));
      expect(result.map((n) => n.slot).toSet(), NotificationSlot.values.toSet());
      expect(result.map((n) => n.id).toSet(), hasLength(4));
    });

    test('the reminder timeout is 15 min after the start, capped at the day end', () {
      final r = planNotifications(input([task(start: at(14))])).first;
      expect(r.timeoutAtUtc, at(14, 15));
      final late = planNotifications(input([task(start: at(23, 55))], offsets: const [30])).first;
      expect(late.timeoutAtUtc, dayEnd);
    });
  });

  group('deterministic ids', () {
    test('the same task and slot always map to the same id, independent of input order', () {
      final a = planNotifications(input([task(id: 'a', start: at(14)), task(id: 'b', start: at(16))]));
      final b = planNotifications(input([task(id: 'b', start: at(16)), task(id: 'a', start: at(14))]));
      expect({for (final n in a) n.id}, {for (final n in b) n.id});
    });

    test('colliding hashes are probed apart', () {
      final result = planNotifications(
        input([task(id: 'a', start: at(14)), task(id: 'b', start: at(16))]),
        hasher: (_) => 42,
      );
      expect(result.map((n) => n.id).toSet(), hasLength(result.length));
    });
  });
}

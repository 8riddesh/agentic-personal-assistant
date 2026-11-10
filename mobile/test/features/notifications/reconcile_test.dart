import 'package:daily_assistant/features/app_shell/domain/local_date.dart';
import 'package:daily_assistant/features/notifications/domain/notification_ids.dart';
import 'package:daily_assistant/features/notifications/domain/notification_planner.dart';
import 'package:daily_assistant/features/notifications/domain/reconcile_diff.dart';
import 'package:daily_assistant/features/notifications/presentation/reconciler.dart';
import 'package:daily_assistant/features/tasks/domain/entities.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fakes.dart';

const day = LocalDate(2026, 11, 9);
DateTime at(int h, [int m = 0]) => DateTime.utc(2026, 11, 9, h, m);

PlannerInput plannerInput(List<TaskSnapshot> tasks, {DayState state = DayState.open}) => PlannerInput(
      dayDate: day,
      dayState: state,
      tasks: tasks,
      nowUtc: at(12),
      location: utc,
      reminderOffsetsMin: const [60, 30],
      exactAllowed: true,
    );

TaskSnapshot snap({String id = 't1', DateTime? start, TaskStatus status = TaskStatus.planned}) =>
    TaskSnapshot(id: id, title: 'Write report', localDate: day, status: status, startAt: start);

List<PendingNotification> asPending(List<DesiredNotification> list) =>
    [for (final d in list) PendingNotification(id: d.id, payload: d.payload)];

ReconcileContext open({Set<int> live = const {}}) => ReconcileContext(dayOpen: true, livePlannedIds: live);

void main() {
  setUpAll(initTz);

  group('reconcileDiff (spec §8.3)', () {
    final desired = planNotifications(plannerInput([snap(start: at(14))]));

    test('schedules everything that is missing', () {
      final ops = reconcileDiff(pending: const [], activeIds: const {}, desired: desired, state: open());
      expect(ops.schedule.map((d) => d.id), desired.map((d) => d.id));
      expect(ops.cancel, isEmpty);
    });

    test('M-NOTIF-AC-06 a second run on unchanged state does nothing', () {
      final ops = reconcileDiff(pending: asPending(desired), activeIds: const {}, desired: desired, state: open());
      expect(ops.isEmpty, isTrue);
    });

    test('a changed content hash cancels and re-schedules that id', () {
      final moved = planNotifications(plannerInput([snap(start: at(15))]));
      final ops = reconcileDiff(pending: asPending(desired), activeIds: const {}, desired: moved, state: open());
      expect(ops.cancel.toSet(), desired.map((d) => d.id).toSet());
      expect(ops.schedule.map((d) => d.id).toSet(), moved.map((d) => d.id).toSet());
    });

    test('M-NOTIF-AC-05 a pending notification of a task that is no longer planned is cancelled', () {
      final ops = reconcileDiff(pending: asPending(desired), activeIds: const {}, desired: const [], state: open());
      expect(ops.cancel.toSet(), desired.map((d) => d.id).toSet());
      expect(ops.schedule, isEmpty);
    });

    test('a pending entry with an unreadable payload is cancelled', () {
      final ops = reconcileDiff(
        pending: const [PendingNotification(id: 9, payload: 'garbage'), PendingNotification(id: 10)],
        activeIds: const {},
        desired: const [],
        state: open(),
      );
      expect(ops.cancel, [9, 10]);
    });

    test('unknown state (null) never wipes a valid schedule', () {
      final ops = reconcileDiff(pending: asPending(desired), activeIds: {1}, desired: const [], state: null);
      expect(ops.isEmpty, isTrue);
    });

    test('M-NOTIF-AC-12 a closed day also clears notifications that are already displayed', () {
      final ops = reconcileDiff(
        pending: const [],
        activeIds: {5, 6},
        desired: const [],
        state: const ReconcileContext(dayOpen: false, livePlannedIds: {5}),
      );
      expect(ops.cancelActive, [5, 6]);
    });

    test('on an open day only displayed notifications of non-planned tasks are removed', () {
      final ops = reconcileDiff(pending: const [], activeIds: {5, 6}, desired: const [], state: open(live: {5}));
      expect(ops.cancelActive, [6]);
    });
  });

  group('NotificationReconciler', () {
    late FakeGateway gateway;
    late PlannerInput? current;

    NotificationReconciler build() => NotificationReconciler(gateway: gateway, inputBuilder: () async => current);

    setUp(() {
      gateway = FakeGateway();
      current = plannerInput([snap(start: at(14))]);
    });

    test('M-NOTIF-AC-01 schedules two reminders for a task at 14:00', () async {
      final report = await build().reconcile();
      expect(report.scheduled, 2);
      expect(gateway.scheduled.map((n) => n.slot), [NotificationSlot.reminder1, NotificationSlot.reminder2]);
    });

    test('M-NOTIF-AC-06 running twice schedules and cancels nothing the second time', () async {
      final reconciler = build();
      await reconciler.reconcile();
      final second = await reconciler.reconcile();
      expect(second.changedNothing, isTrue);
      expect(gateway.scheduled, hasLength(2));
    });

    test('M-NOTIF-AC-05 completing the task cancels its pending reminders', () async {
      final reconciler = build();
      await reconciler.reconcile();
      current = plannerInput([snap(start: at(14), status: TaskStatus.completed)]);
      final report = await reconciler.reconcile();
      expect(report.cancelled, 2);
      expect(gateway.pendingList, isEmpty);
    });

    test('M-NOTIF-AC-12 closing the day cancels everything, pending and displayed', () async {
      final reconciler = build();
      await reconciler.reconcile();
      gateway.active = [notificationId('t1', NotificationSlot.reminder1)];
      current = plannerInput([snap(start: at(14))], state: DayState.closed);
      final report = await reconciler.reconcile();
      expect(report.cancelled, 2);
      expect(report.cancelledActive, 1);
      expect(gateway.pendingList, isEmpty);
      expect(gateway.active, isEmpty);
    });

    test('unknown state (no input) leaves the schedule untouched', () async {
      final reconciler = build();
      await reconciler.reconcile();
      current = null;
      final report = await reconciler.reconcile();
      expect(report.noop, isTrue);
      expect(gateway.pendingList, hasLength(2));
      expect(gateway.cancelled, isEmpty);
    });

    test('a failing zonedSchedule is skipped and the rest still goes through', () async {
      gateway.failingIds = {notificationId('t1', NotificationSlot.reminder1)};
      final report = await build().reconcile();
      expect(report.failedIds, hasLength(1));
      expect(report.scheduled, 1);
    });

    test('R10 of the reconciler: concurrent calls coalesce into one run plus one trailing run', () async {
      gateway.latency = const Duration(milliseconds: 20);
      final reconciler = build();
      await Future.wait([reconciler.reconcile(), reconciler.reconcile(), reconciler.reconcile()]);
      expect(gateway.pendingCalls, lessThanOrEqualTo(2));
      expect(gateway.scheduled, hasLength(2)); // no duplicates
    });

    test('logout cancels everything this app scheduled', () async {
      final reconciler = build();
      await reconciler.reconcile();
      await reconciler.cancelAll();
      expect(gateway.cancelledAll, isTrue);
      expect(gateway.pendingList, isEmpty);
    });

    test('anytime tasks never produce a notification (M-NOTIF-AC-16)', () async {
      current = plannerInput([snap()]);
      final report = await build().reconcile();
      expect(report.scheduled, 0);
      expect(gateway.scheduled, isEmpty);
    });
  });
}

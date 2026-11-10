import 'dart:async';

import '../domain/notification_ids.dart';
import '../domain/notification_planner.dart';
import '../domain/notification_texts.dart';
import '../domain/notifications_gateway.dart';
import '../domain/reconcile_diff.dart';

class ReconcileReport {
  const ReconcileReport({
    this.scheduled = 0,
    this.cancelled = 0,
    this.cancelledActive = 0,
    this.failedIds = const [],
    this.noop = false,
  });

  /// State unknown: nothing was touched.
  static const ReconcileReport unknown = ReconcileReport(noop: true);

  final int scheduled;
  final int cancelled;
  final int cancelledActive;

  /// Ids whose `zonedSchedule` threw (logged and skipped).
  final List<int> failedIds;
  final bool noop;

  bool get changedNothing => scheduled == 0 && cancelled == 0 && cancelledActive == 0;
}

typedef PlannerInputBuilder = Future<PlannerInput?> Function();

/// Brings the OS-scheduled notifications in line with the open day (spec §8.3).
///
/// Single-flight: calls made while a run is in progress coalesce into one trailing run.
class NotificationReconciler {
  NotificationReconciler({
    required this.gateway,
    required this.inputBuilder,
    this.hasher = fnv1a32,
    this.texts = const NotificationTexts(),
  });

  final NotificationsGateway gateway;
  final PlannerInputBuilder inputBuilder;
  final IdHasher hasher;
  final NotificationTexts texts;

  Future<ReconcileReport>? _current;
  bool _rerun = false;

  Future<ReconcileReport> reconcile() {
    final running = _current;
    if (running != null) {
      _rerun = true;
      return running;
    }
    final completer = Completer<ReconcileReport>();
    _current = completer.future;
    unawaited(() async {
      var report = ReconcileReport.unknown;
      try {
        do {
          _rerun = false;
          report = await _runOnce();
        } while (_rerun);
        completer.complete(report);
      } catch (e, st) {
        completer.completeError(e, st);
      } finally {
        _current = null;
      }
    }());
    return completer.future;
  }

  /// Logout: remove everything this app scheduled.
  Future<void> cancelAll() => gateway.cancelAll();

  Future<ReconcileReport> _runOnce() async {
    final input = await inputBuilder();
    if (input == null) return ReconcileReport.unknown; // unknown state: never wipe a valid schedule

    final desired = planNotifications(input, texts: texts, hasher: hasher);
    final pending = await gateway.pending();
    final active = (await gateway.activeIds()).toSet();

    final livePlanned = <int>{...desired.map((d) => d.id)};
    for (final t in input.tasks) {
      if (t.localDate == input.dayDate && t.status.name == 'planned') {
        for (final slot in NotificationSlot.values) {
          livePlanned.add(notificationId(t.id, slot, hasher: hasher));
        }
      }
    }

    final ops = reconcileDiff(
      pending: pending,
      activeIds: active,
      desired: desired,
      state: ReconcileContext(dayOpen: input.dayState.name == 'open', livePlannedIds: livePlanned),
    );

    for (final id in ops.cancel) {
      await gateway.cancel(id);
    }
    for (final id in ops.cancelActive) {
      await gateway.cancel(id);
    }
    var scheduled = 0;
    final failed = <int>[];
    for (final d in ops.schedule) {
      try {
        await gateway.schedule(d);
        scheduled++;
      } catch (_) {
        failed.add(d.id); // past-instant race or invalid entry: skip, keep going
      }
    }
    return ReconcileReport(
      scheduled: scheduled,
      cancelled: ops.cancel.length,
      cancelledActive: ops.cancelActive.length,
      failedIds: failed,
    );
  }
}

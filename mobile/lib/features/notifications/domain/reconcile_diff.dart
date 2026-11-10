import 'notification_payload.dart';
import 'notification_planner.dart';

/// A notification that is scheduled but has not fired yet.
class PendingNotification {
  const PendingNotification({required this.id, this.payload});

  final int id;
  final String? payload;
}

/// What reconcile knows about the open day (to clean up notifications that are already displayed).
class ReconcileContext {
  const ReconcileContext({required this.dayOpen, required this.livePlannedIds});

  final bool dayOpen;

  /// Ids (all slots) of planned tasks of the open day. A displayed notification whose id is not in here belongs to
  /// a terminal / unknown task and is removed.
  final Set<int> livePlannedIds;
}

class ReconcileOps {
  const ReconcileOps({this.cancel = const [], this.schedule = const [], this.cancelActive = const []});

  final List<int> cancel;
  final List<DesiredNotification> schedule;
  final List<int> cancelActive;

  bool get isEmpty => cancel.isEmpty && schedule.isEmpty && cancelActive.isEmpty;
}

/// Minimal set of operations to turn the scheduled set into [desired] (spec §8.3). Deterministic ids + content
/// hashes make a second run on unchanged state a no-op (M-NOTIF-AC-06). `state == null` (unknown) changes nothing.
ReconcileOps reconcileDiff({
  required List<PendingNotification> pending,
  required Set<int> activeIds,
  required List<DesiredNotification> desired,
  required ReconcileContext? state,
}) {
  if (state == null) return const ReconcileOps();

  final desiredById = {for (final d in desired) d.id: d};
  final pendingHash = <int, String?>{};
  final cancel = <int>[];

  for (final p in pending) {
    final payload = NotificationPayload.decode(p.payload);
    final want = desiredById[p.id];
    if (payload == null || want == null || want.contentHash != payload.hash) {
      cancel.add(p.id);
    } else {
      pendingHash[p.id] = payload.hash;
    }
  }

  final schedule = [
    for (final d in desired)
      if (pendingHash[d.id] != d.contentHash) d,
  ];

  final cancelActive = [
    for (final id in activeIds)
      if (!state.dayOpen || !state.livePlannedIds.contains(id)) id,
  ];

  return ReconcileOps(cancel: cancel, schedule: schedule, cancelActive: cancelActive);
}

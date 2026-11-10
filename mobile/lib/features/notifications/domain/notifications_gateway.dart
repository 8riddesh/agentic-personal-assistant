import 'notification_planner.dart';
import 'reconcile_diff.dart';

/// Thin port over the platform notification plugin (mockable; the real one is `FlutterNotificationsGateway`).
abstract interface class NotificationsGateway {
  Future<void> schedule(DesiredNotification notification);

  /// Scheduled, not yet fired.
  Future<List<PendingNotification>> pending();

  /// Ids of notifications currently displayed.
  Future<List<int>> activeIds();

  Future<void> cancel(int id);

  Future<void> cancelAll();

  Future<bool> areEnabled();

  Future<bool> canScheduleExact();

  /// Asks for `POST_NOTIFICATIONS` (Android 13+); returns whether it is granted.
  Future<bool> requestPermission();

  /// Opens the exact-alarm settings screen (API 31-32 revocable permission).
  Future<void> requestExactAlarms();
}

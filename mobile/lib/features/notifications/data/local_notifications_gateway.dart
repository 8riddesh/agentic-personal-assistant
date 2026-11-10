import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../domain/notification_planner.dart';
import '../domain/notifications_gateway.dart';
import '../domain/reconcile_diff.dart';

/// `flutter_local_notifications` (API of 19.x) behind [NotificationsGateway]. Every plugin call lives here, so a
/// plugin upgrade touches one file.
class FlutterNotificationsGateway implements NotificationsGateway {
  FlutterNotificationsGateway([FlutterLocalNotificationsPlugin? plugin])
      : _plugin = plugin ?? FlutterLocalNotificationsPlugin();

  final FlutterLocalNotificationsPlugin _plugin;

  static const _actionTitles = {'done': 'Done', 'not_yet': 'Not yet', 'not_yet_eta': 'Remind me later…'};

  AndroidFlutterLocalNotificationsPlugin? get _android =>
      _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();

  /// Channels + plugin init (notifications spec §8.9). [onTap] receives the payload of a tapped notification.
  Future<void> initialize({void Function(String? payload)? onTap}) async {
    await _plugin.initialize(
      const InitializationSettings(android: AndroidInitializationSettings('@drawable/ic_stat_notify')),
      onDidReceiveNotificationResponse: (response) => onTap?.call(response.payload),
    );
    final android = _android;
    await android?.createNotificationChannel(
      const AndroidNotificationChannel(
        remindersChannel,
        'Task reminders',
        description: 'Before a task starts',
        importance: Importance.high,
      ),
    );
    await android?.createNotificationChannel(
      const AndroidNotificationChannel(
        checksChannel,
        'Completion checks',
        description: 'One check when a task should be done',
        importance: Importance.high,
      ),
    );
  }

  @override
  Future<void> schedule(DesiredNotification n) {
    final isReminder = n.channelId == remindersChannel;
    final timeoutMs = n.timeoutAtUtc.difference(n.fireAt.toUtc()).inMilliseconds;
    final details = AndroidNotificationDetails(
      n.channelId,
      isReminder ? 'Task reminders' : 'Completion checks',
      channelDescription: isReminder ? 'Before a task starts' : 'One check when a task should be done',
      importance: Importance.high,
      priority: Priority.high,
      category: AndroidNotificationCategory.reminder,
      visibility: NotificationVisibility.private,
      autoCancel: true,
      timeoutAfter: timeoutMs < 1000 ? 1000 : timeoutMs,
      icon: '@drawable/ic_stat_notify',
      actions: [
        for (final id in n.actionIds)
          AndroidNotificationAction(id, _actionTitles[id] ?? id, showsUserInterface: id == 'not_yet_eta'),
      ],
    );
    return _plugin.zonedSchedule(
      n.id,
      n.title,
      n.body,
      n.fireAt,
      NotificationDetails(android: details),
      androidScheduleMode:
          n.mode == ScheduleMode.exact ? AndroidScheduleMode.exactAllowWhileIdle : AndroidScheduleMode.inexactAllowWhileIdle,
      payload: n.payload,
    );
  }

  @override
  Future<List<PendingNotification>> pending() async {
    final requests = await _plugin.pendingNotificationRequests();
    return [for (final r in requests) PendingNotification(id: r.id, payload: r.payload)];
  }

  @override
  Future<List<int>> activeIds() async {
    try {
      final active = await _android?.getActiveNotifications() ?? const <ActiveNotification>[];
      return [for (final a in active) if (a.id != null) a.id!];
    } catch (_) {
      return const [];
    }
  }

  @override
  Future<void> cancel(int id) => _plugin.cancel(id);

  @override
  Future<void> cancelAll() => _plugin.cancelAll();

  @override
  Future<bool> areEnabled() async => await _android?.areNotificationsEnabled() ?? true;

  @override
  Future<bool> canScheduleExact() async => await _android?.canScheduleExactNotifications() ?? true;

  @override
  Future<bool> requestPermission() async => await _android?.requestNotificationsPermission() ?? true;

  @override
  Future<void> requestExactAlarms() async {
    await _android?.requestExactAlarmsPermission();
  }
}

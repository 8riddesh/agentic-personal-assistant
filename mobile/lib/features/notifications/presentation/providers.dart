import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app_shell/data/kv_store.dart';
import '../../app_shell/presentation/providers.dart';
import '../../tasks/presentation/providers.dart';
import '../domain/notification_planner.dart';
import '../domain/notifications_gateway.dart';
import 'reconciler.dart';

/// Overridden at bootstrap with `FlutterNotificationsGateway`.
final notificationsGatewayProvider = Provider<NotificationsGateway>(
  (ref) => throw UnimplementedError('override notificationsGatewayProvider'),
);

/// Called once, after the first successful scheduling, to open the battery guide. Wired in `composition.dart`.
final showBatteryGuideProvider = Provider<void Function()>((_) => () {});

/// Completion checks / follow-ups (M3) are switched on here; M1 ships only the T-60 / T-30 reminders.
final completionChecksEnabledProvider = Provider<bool>((_) => false);

final notificationReconcilerProvider = Provider<NotificationReconciler>((ref) {
  final gateway = ref.watch(notificationsGatewayProvider);
  return NotificationReconciler(
    gateway: gateway,
    inputBuilder: () async {
      // Unknown state (not loaded / error): reconcile does nothing rather than wiping a valid schedule.
      final today = ref.read(currentDayControllerProvider).valueOrNull;
      if (today == null) return null;
      final settings = ref.read(settingsControllerProvider).valueOrNull;
      return PlannerInput(
        dayDate: today.day.localDate,
        dayState: today.day.state,
        tasks: [for (final t in today.tasks) TaskSnapshot.fromTask(t)],
        nowUtc: ref.read(clockProvider).nowUtc(),
        location: ref.read(appLocationProvider),
        reminderOffsetsMin: settings?.reminderOffsetsMin ?? const [60, 30],
        exactAllowed: await gateway.canScheduleExact(),
        checksEnabled: ref.read(completionChecksEnabledProvider),
      );
    },
  );
});

/// Reconcile, then show the battery guide once after the first notification was scheduled (spec §7.5).
Future<void> reconcileAndGuide(Ref ref) async {
  final report = await ref.read(notificationReconcilerProvider).reconcile();
  if (report.scheduled > 0) {
    final kv = ref.read(kvStoreProvider);
    if (await kv.get(KvKeys.batteryGuideShown) == null) {
      await kv.set(KvKeys.batteryGuideShown, '1');
      ref.read(showBatteryGuideProvider)();
    }
  }
}

class NotificationPermissionState {
  const NotificationPermissionState({required this.enabled, required this.exactAllowed});

  final bool enabled;
  final bool exactAllowed;
}

class NotificationPermissionController extends AsyncNotifier<NotificationPermissionState> {
  @override
  Future<NotificationPermissionState> build() async {
    final gateway = ref.watch(notificationsGatewayProvider);
    return NotificationPermissionState(
      enabled: await gateway.areEnabled(),
      exactAllowed: await gateway.canScheduleExact(),
    );
  }

  Future<void> requestEnabled() async {
    final gateway = ref.read(notificationsGatewayProvider);
    await gateway.requestPermission();
    ref.invalidateSelf();
    await future;
    unawaited(reconcileAndGuide(ref));
  }

  Future<void> openExactAlarmSettings() async {
    await ref.read(notificationsGatewayProvider).requestExactAlarms();
  }
}

final notificationPermissionProvider =
    AsyncNotifierProvider<NotificationPermissionController, NotificationPermissionState>(
  NotificationPermissionController.new,
);

/// Wires the reconcile triggers (spec §8.3): the open day changes (debounced 300 ms) and the settings that affect
/// scheduling change. Kept alive by the app root.
final notificationSyncProvider = Provider<void>((ref) {
  Timer? debounce;
  void trigger() {
    debounce?.cancel();
    debounce = Timer(const Duration(milliseconds: 300), () => unawaited(reconcileAndGuide(ref)));
  }

  ref.listen(currentDayControllerProvider, (previous, next) {
    if (next.hasValue) trigger();
  });
  ref.listen(settingsControllerProvider, (previous, next) {
    final before = previous?.valueOrNull;
    final after = next.valueOrNull;
    if (after == null) return;
    if (before?.timezone != after.timezone || before?.reminderOffsetsMin.join(',') != after.reminderOffsetsMin.join(',')) {
      trigger();
    }
  });
  ref.onDispose(() => debounce?.cancel());
});

/// Order 40: ask for the notification permission once, then reconcile from the day state.
final class NotificationsReconcileHook implements LifecycleHook {
  const NotificationsReconcileHook();

  @override
  int get order => 40;

  @override
  Future<void> onLaunchOrResume(Ref ref) async {
    final kv = ref.read(kvStoreProvider);
    if (await kv.get(KvKeys.notifPermAsked) == null) {
      await kv.set(KvKeys.notifPermAsked, '1');
      await ref.read(notificationsGatewayProvider).requestPermission();
    }
    ref.invalidate(notificationPermissionProvider); // may have changed while the app was in the background
    await reconcileAndGuide(ref);
  }
}

/// After the user closes the day (reports, M4): remove every notification of the day.
Future<void> cancelAllForDay(Ref ref) => ref.read(notificationReconcilerProvider).cancelAll();

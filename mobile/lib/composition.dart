import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'features/app_shell/data/app_config.dart';
import 'features/app_shell/data/kv_store.dart';
import 'features/app_shell/presentation/providers.dart';
import 'features/app_shell/presentation/router.dart';
import 'features/notifications/domain/notifications_gateway.dart';
import 'features/notifications/presentation/permission_card.dart';
import 'features/notifications/presentation/providers.dart';
import 'features/tasks/presentation/providers.dart';

/// The one place where features are wired together (composition root): lifecycle hooks, logout cleanup and the
/// cards other features contribute to Today / Settings.
List<Override> buildOverrides({
  required AppConfig config,
  required KeyValueStore kv,
  required NotificationsGateway gateway,
  required String deviceTimezone,
}) =>
    [
      appConfigProvider.overrideWithValue(config),
      kvStoreProvider.overrideWithValue(kv),
      notificationsGatewayProvider.overrideWithValue(gateway),
      deviceTimezoneProvider.overrideWithValue(deviceTimezone),
      // order 10 (token check) and 20 (outbox flush) are built into the lifecycle runner
      lifecycleHooksProvider.overrideWithValue(const [CurrentDayLifecycleHook(), NotificationsReconcileHook()]),
      logoutHooksProvider.overrideWith(
        (ref) => [
          () => ref.read(notificationReconcilerProvider).cancelAll(),
          () => ref.read(tasksRepositoryProvider).clearCache(),
        ],
      ),
      settingsExtraSectionsProvider.overrideWithValue(const [NotificationSettingsSection()]),
      todayHeaderSectionsProvider.overrideWithValue(const [PermissionCard()]),
      showBatteryGuideProvider.overrideWith((ref) => () => ref.read(routerProvider).push<void>('/settings/battery')),
    ];

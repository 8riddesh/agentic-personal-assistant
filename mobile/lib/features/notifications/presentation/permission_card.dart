import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'providers.dart';

/// "Notifications are off — you won't get reminders." (Today top + Settings; notifications spec §7.4).
class PermissionCard extends ConsumerWidget {
  const PermissionCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final permission = ref.watch(notificationPermissionProvider).valueOrNull;
    if (permission == null || permission.enabled) return const SizedBox.shrink();
    return Card(
      key: const Key('permission-card'),
      margin: const EdgeInsets.all(12),
      child: ListTile(
        leading: const Icon(Icons.notifications_off),
        title: const Text("Notifications are off — you won't get reminders."),
        trailing: FilledButton(
          key: const Key('permission-turn-on'),
          onPressed: () => ref.read(notificationPermissionProvider.notifier).requestEnabled(),
          child: const Text('Turn on'),
        ),
      ),
    );
  }
}

/// Notification rows for the Settings screen: permission, exact timing and the battery guide.
class NotificationSettingsSection extends ConsumerWidget {
  const NotificationSettingsSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final permission = ref.watch(notificationPermissionProvider).valueOrNull;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
          child: Text('Notifications', style: Theme.of(context).textTheme.titleSmall),
        ),
        const PermissionCard(),
        if (permission != null && permission.enabled && !permission.exactAllowed)
          ListTile(
            key: const Key('exact-alarm-row'),
            title: const Text('Reminders may arrive a few minutes late.'),
            trailing: TextButton(
              key: const Key('exact-alarm-allow'),
              onPressed: () => ref.read(notificationPermissionProvider.notifier).openExactAlarmSettings(),
              child: const Text('Allow exact timing'),
            ),
          ),
        ListTile(
          key: const Key('battery-guide-link'),
          title: const Text('Battery optimisation guide'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => context.push('/settings/battery'),
        ),
      ],
    );
  }
}

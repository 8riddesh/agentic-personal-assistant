import 'package:android_intent_plus/android_intent.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Must match `applicationId` in `android/app/build.gradle.kts`.
const String applicationId = 'dev.riddesh.daily_assistant';

typedef IntentLauncher = Future<void> Function(String action, {String? data});

/// Opens an Android settings screen (overridden in tests).
final intentLauncherProvider = Provider<IntentLauncher>(
  (ref) => (action, {data}) => AndroidIntent(action: action, data: data).launch(),
);

/// Why some phones stop reminders and how to allow them (notifications spec §7.5). Auto-opened once.
class BatteryGuideScreen extends ConsumerWidget {
  const BatteryGuideScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final launch = ref.watch(intentLauncherProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Reliable reminders')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            'Some phones stop scheduled reminders to save battery. To make sure you get them on time, '
            'let Daily Assistant run without restrictions.',
            key: Key('battery-why'),
          ),
          const SizedBox(height: 16),
          const Text('Settings → Apps → Daily Assistant → Battery → Unrestricted'),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton(
                key: const Key('open-app-settings'),
                onPressed: () => launch('android.settings.APPLICATION_DETAILS_SETTINGS', data: 'package:$applicationId'),
                child: const Text('Open app settings'),
              ),
              OutlinedButton(
                key: const Key('open-battery-list'),
                onPressed: () => launch('android.settings.IGNORE_BATTERY_OPTIMIZATION_SETTINGS'),
                child: const Text('Open battery optimisation list'),
              ),
            ],
          ),
          const SizedBox(height: 24),
          Text('Phone-specific notes', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 8),
          const Text('• Xiaomi / HyperOS: enable Autostart and set battery to "No restrictions".'),
          const Text('• Samsung: remove the app from "Sleeping apps" and add it to "Never sleeping apps".'),
          const Text('• OnePlus / Oppo / Realme: allow background activity and auto-launch.'),
          const Text('• Huawei: App launch → manage manually.'),
          const SizedBox(height: 8),
          const Text('More: dontkillmyapp.com'),
          const SizedBox(height: 24),
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton(
              key: const Key('battery-got-it'),
              onPressed: () => Navigator.of(context).maybePop(),
              child: const Text('Got it'),
            ),
          ),
        ],
      ),
    );
  }
}

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../notifications/presentation/providers.dart';
import 'lifecycle_coordinator.dart';
import 'router.dart';
import 'theme.dart';

/// Root widget: go_router, light/dark theme, lifecycle hooks and the notification sync (kept alive here).
class App extends ConsumerWidget {
  const App({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(notificationSyncProvider);
    final router = ref.watch(routerProvider);
    return MaterialApp.router(
      title: 'Daily Assistant',
      theme: buildTheme(Brightness.light),
      darkTheme: buildTheme(Brightness.dark),
      routerConfig: router,
      builder: (context, child) => LifecycleCoordinator(child: child ?? const SizedBox.shrink()),
    );
  }
}

/// Shown instead of the app when the APK was built without `API_BASE_URL` (M-SHELL-AC-12).
class ConfigErrorApp extends StatelessWidget {
  const ConfigErrorApp({super.key, required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Daily Assistant',
      theme: buildTheme(Brightness.light),
      home: Scaffold(
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.error_outline, size: 48, color: Colors.red),
                const SizedBox(height: 16),
                Text('Configuration error', style: Theme.of(context).textTheme.headlineSmall),
                const SizedBox(height: 8),
                Text(message, key: const Key('config-error-message')),
                const SizedBox(height: 16),
                const Text(
                  'Rebuild with:\nflutter build apk --release --dart-define=API_BASE_URL=https://<service>.onrender.com',
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

import 'package:flutter/material.dart';

import '../data/app_config.dart';
import '../data/health_api.dart';
import 'home_screen.dart';

ThemeData _theme(Brightness brightness) => ThemeData(
      useMaterial3: true,
      colorSchemeSeed: Colors.indigo,
      brightness: brightness,
    );

/// Root widget. M0 shows a single connectivity screen; the login screen, router and the four-tab shell
/// (Today, Chat, Reports, Settings) arrive with M1 (app_shell spec §7).
class App extends StatelessWidget {
  const App({super.key, required this.config, required this.healthApi});

  final AppConfig config;
  final HealthApi healthApi;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Daily Assistant',
      theme: _theme(Brightness.light),
      darkTheme: _theme(Brightness.dark),
      home: HomeScreen(config: config, healthApi: healthApi),
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
      theme: _theme(Brightness.light),
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

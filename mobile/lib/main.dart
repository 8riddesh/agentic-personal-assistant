import 'package:flutter/material.dart';

import 'features/app_shell/data/app_config.dart';
import 'features/app_shell/data/health_api.dart';
import 'features/app_shell/presentation/app.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();

  final AppConfig config;
  try {
    config = AppConfig.fromEnvironment();
  } on StateError catch (e) {
    // Fail fast with a visible error screen instead of a blank app (M-SHELL-AC-12).
    runApp(ConfigErrorApp(message: e.message));
    return;
  }

  runApp(App(config: config, healthApi: DioHealthApi(config.apiBaseUrl)));
}

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:timezone/data/latest.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;

import 'composition.dart';
import 'features/app_shell/data/app_config.dart';
import 'features/app_shell/data/health_api.dart';
import 'features/app_shell/data/kv_store.dart';
import 'features/app_shell/presentation/app.dart';
import 'features/notifications/data/local_notifications_gateway.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final AppConfig config;
  try {
    config = AppConfig.fromEnvironment();
  } on StateError catch (e) {
    // Fail fast with a visible error screen instead of a blank app (M-SHELL-AC-12).
    runApp(ConfigErrorApp(message: e.message));
    return;
  }

  // Time zones: the tz database plus the device's IANA zone (falls back to UTC if it cannot be read).
  tz_data.initializeTimeZones();
  var deviceTimezone = 'UTC';
  try {
    deviceTimezone = (await FlutterTimezone.getLocalTimezone()).identifier;
    tz.setLocalLocation(tz.getLocation(deviceTimezone));
  } catch (_) {
    deviceTimezone = 'UTC';
  }

  final gateway = FlutterNotificationsGateway();
  await gateway.initialize();

  // Warm the (sleeping) Render instance early; the result does not matter.
  unawaited(DioHealthApi(config.apiBaseUrl).check().then<void>((_) {}, onError: (Object _) {}));

  runApp(
    ProviderScope(
      overrides: buildOverrides(
        config: config,
        kv: PrefsKeyValueStore(),
        gateway: gateway,
        deviceTimezone: deviceTimezone,
      ),
      child: const App(),
    ),
  );
}

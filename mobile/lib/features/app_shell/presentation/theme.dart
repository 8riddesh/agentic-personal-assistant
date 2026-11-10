import 'package:flutter/material.dart';

ThemeData buildTheme(Brightness brightness) => ThemeData(
      useMaterial3: true,
      colorSchemeSeed: Colors.indigo,
      brightness: brightness,
    );

/// Status chip colours, defined once (app_shell spec §8.8). Keys are the backend status strings.
abstract final class AppStatusColors {
  static Color of(String status, ColorScheme scheme) => switch (status) {
        'completed' => Colors.green.shade600,
        'postponed' => Colors.amber.shade800,
        'cancelled' => scheme.outline,
        'cant_do' => Colors.red.shade400,
        'missed' => Colors.blueGrey.shade700,
        _ => Colors.grey, // planned
      };
}

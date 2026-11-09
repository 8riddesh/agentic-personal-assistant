import 'package:daily_assistant/features/app_shell/data/app_config.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('AppConfig.parse', () {
    test('accepts an https URL', () {
      final config = AppConfig.parse('https://daily-assistant-api.onrender.com');
      expect(config.apiBaseUrl.host, 'daily-assistant-api.onrender.com');
      expect(config.apiBaseUrl.scheme, 'https');
    });

    test('trims whitespace and a trailing slash', () {
      final config = AppConfig.parse('  https://example.com/  ');
      expect(config.apiBaseUrl.toString(), 'https://example.com');
    });

    test('keeps a non-root path without its trailing slash', () {
      expect(AppConfig.parse('https://example.com/backend/').apiBaseUrl.path, '/backend');
    });

    test('empty value throws StateError (config error screen, M-SHELL-AC-12)', () {
      expect(() => AppConfig.parse(''), throwsA(isA<StateError>()));
      expect(() => AppConfig.parse('   '), throwsA(isA<StateError>()));
    });

    test('rejects URLs that are not http(s) with a host', () {
      for (final bad in ['example.com', 'ftp://example.com', 'https://', 'not a url']) {
        expect(() => AppConfig.parse(bad), throwsA(isA<StateError>()), reason: bad);
      }
    });
  });

  test('fromEnvironment without --dart-define throws StateError', () {
    // `flutter test` runs without API_BASE_URL, which is exactly the "APK built without the define" case.
    expect(AppConfig.fromEnvironment, throwsA(isA<StateError>()));
  });
}

import 'package:daily_assistant/features/app_shell/data/health_api.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('HealthStatus.fromJson', () {
    test('parses the backend HealthDTO', () {
      final health = HealthStatus.fromJson({
        'status': 'ok',
        'db': 'ok',
        'env': 'prod',
        'version': '3f2c1ab',
        'time': '2026-11-08T07:15:02Z',
      });
      expect(health.isOk, isTrue);
      expect(health.version, '3f2c1ab');
      expect(health.env, 'prod');
    });

    test('degraded is not ok', () {
      expect(HealthStatus.fromJson({'status': 'degraded', 'db': 'unavailable'}).isOk, isFalse);
    });

    test('rejects a non-object body', () {
      expect(() => HealthStatus.fromJson('<html>'), throwsFormatException);
    });
  });
}

import 'dart:async';

import 'package:daily_assistant/features/app_shell/data/app_config.dart';
import 'package:daily_assistant/features/app_shell/data/health_api.dart';
import 'package:daily_assistant/features/app_shell/presentation/app.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeHealthApi implements HealthApi {
  _FakeHealthApi(this._responses);

  final List<FutureOr<HealthStatus> Function()> _responses;
  int calls = 0;

  @override
  Future<HealthStatus> check() async {
    // The last response repeats if the screen asks more often than scripted.
    final index = calls < _responses.length ? calls : _responses.length - 1;
    calls++;
    return _responses[index]();
  }
}

final _config = AppConfig.parse('https://api.example.com');

HealthStatus _health({String status = 'ok', String db = 'ok'}) =>
    HealthStatus(status: status, db: db, version: '3f2c1ab', env: 'prod');

void main() {
  testWidgets('shows a spinner, then the server status', (tester) async {
    final completer = Completer<HealthStatus>();
    final api = _FakeHealthApi([() => completer.future]);
    await tester.pumpWidget(App(config: _config, healthApi: api));

    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    completer.complete(_health());
    await tester.pump();

    expect(find.byKey(const Key('health-status')), findsOneWidget);
    expect(find.text('Server is up'), findsOneWidget);
    expect(find.textContaining('version: 3f2c1ab'), findsOneWidget);
    expect(find.text('api.example.com'), findsOneWidget);
  });

  testWidgets('degraded server is reported as degraded', (tester) async {
    final api = _FakeHealthApi([() => _health(status: 'degraded', db: 'unavailable')]);
    await tester.pumpWidget(App(config: _config, healthApi: api));
    await tester.pump();

    expect(find.text('Server is degraded'), findsOneWidget);
    expect(find.textContaining('database: unavailable'), findsOneWidget);
  });

  testWidgets('shows an error with Retry, and Retry re-checks', (tester) async {
    final api = _FakeHealthApi([
      () => throw DioException(
            requestOptions: RequestOptions(path: '/health'),
            type: DioExceptionType.connectionError,
          ),
      () => _health(),
    ]);
    await tester.pumpWidget(App(config: _config, healthApi: api));
    await tester.pump();

    expect(find.byKey(const Key('health-error')), findsOneWidget);
    expect(find.text('Cannot reach the server. Check your connection.'), findsOneWidget);

    await tester.tap(find.text('Retry'));
    await tester.pump(); // rebuild with the new future
    await tester.pump(); // future completes

    expect(api.calls, 2);
    expect(find.text('Server is up'), findsOneWidget);
  });

  testWidgets('ConfigErrorApp shows the message (M-SHELL-AC-12)', (tester) async {
    await tester.pumpWidget(const ConfigErrorApp(message: 'API_BASE_URL not configured'));

    expect(find.text('Configuration error'), findsOneWidget);
    expect(find.byKey(const Key('config-error-message')), findsOneWidget);
    expect(find.text('API_BASE_URL not configured'), findsOneWidget);
  });
}

import 'package:daily_assistant/features/app_shell/data/api_client.dart';
import 'package:daily_assistant/features/app_shell/data/interceptors/waking_interceptor.dart';
import 'package:daily_assistant/features/app_shell/data/problem_mapper.dart';
import 'package:daily_assistant/features/app_shell/data/token_store.dart';
import 'package:daily_assistant/features/app_shell/domain/app_error.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fakes.dart';

Future<TokenStore> _loggedIn() async {
  final store = TokenStore(InMemorySecureKeyValue(), FakeClock(DateTime.utc(2026, 11, 9, 8)));
  await store.write(token: 'jwt-123', expiresAt: DateTime.utc(2026, 12, 9), email: 'me@example.com');
  return store;
}

void main() {
  group('AuthInterceptor', () {
    test('adds the bearer header', () async {
      final adapter = ScriptedAdapter([respond(200, '{"ok":true}')]);
      final dio = buildDio(config: testConfig, tokens: await _loggedIn(), adapter: adapter);
      await dio.get<Object?>('/tasks');
      expect(adapter.requests.single.headers['Authorization'], 'Bearer jwt-123');
    });

    test('omits the header for /auth/login', () async {
      final adapter = ScriptedAdapter([respond(200, '{"ok":true}')]);
      final dio = buildDio(config: testConfig, tokens: await _loggedIn(), adapter: adapter);
      await dio.post<Object?>('/auth/login', data: {'email': 'a@b.c', 'password': 'x'});
      expect(adapter.requests.single.headers.containsKey('Authorization'), isFalse);
    });

    test('a 401 on login does not log out', () async {
      var logouts = 0;
      final adapter = ScriptedAdapter([respond(401, '{"code":"invalid_credentials"}')]);
      final dio = buildDio(config: testConfig, tokens: await _loggedIn(), adapter: adapter, onUnauthorized: () => logouts++);
      await expectLater(dio.post<Object?>('/auth/login', data: {}), throwsA(isA<DioException>()));
      expect(logouts, 0);
    });

    test('three parallel 401s trigger exactly one logout', () async {
      final tokens = await _loggedIn();
      var logouts = 0;
      final adapter = ScriptedAdapter([respond(401, '{"code":"token_expired"}')]);
      final dio = buildDio(
        config: testConfig,
        tokens: tokens,
        adapter: adapter,
        onUnauthorized: () async {
          logouts++;
          await tokens.clear();
        },
      );
      final results = await Future.wait([
        for (final path in ['/a', '/b', '/c'])
          dio.get<Object?>(path).then<Object?>((_) => null, onError: (Object e) => e),
      ]);
      expect(results, everyElement(isA<DioException>()));
      expect(logouts, 1);
    });
  });

  group('RetryInterceptor', () {
    Dio build(ScriptedAdapter adapter, {RecordingSink? sink, Duration budget = const Duration(seconds: 120)}) => buildDio(
          config: testConfig,
          tokens: TokenStore(InMemorySecureKeyValue(), FakeClock(DateTime.utc(2026, 11, 9, 8))),
          adapter: adapter,
          status: sink,
          retryDelay: (_) async {},
          retryBudget: budget,
        );

    test('503, 503, 200 succeeds after two retries', () async {
      final adapter = ScriptedAdapter([respond(503), respond(503), respond(200, '{"ok":true}')]);
      final response = await build(adapter).get<Object?>('/days/current');
      expect(response.statusCode, 200);
      expect(adapter.requests.length, 3);
    });

    test('a POST without an idempotency key is not retried', () async {
      final adapter = ScriptedAdapter([respond(503), respond(200)]);
      await expectLater(build(adapter).post<Object?>('/tasks', data: {}), throwsA(isA<DioException>()));
      expect(adapter.requests.length, 1);
    });

    test('a POST with an idempotency key is retried', () async {
      final adapter = ScriptedAdapter([respond(503), respond(200, '{"ok":true}')]);
      final response = await build(adapter).post<Object?>(
        '/tasks/1/status',
        data: {},
        options: Options(headers: {'Idempotency-Key': 'k1'}),
      );
      expect(response.statusCode, 200);
      expect(adapter.requests.length, 2);
    });

    test('a POST marked retryable is retried', () async {
      final adapter = ScriptedAdapter([respond(503), respond(200, '{"ok":true}')]);
      final response = await build(adapter).post<Object?>(
        '/auth/login',
        data: {},
        options: Options(extra: {'retryable': true}),
      );
      expect(response.statusCode, 200);
    });

    test('a 4xx is never retried', () async {
      final adapter = ScriptedAdapter([respond(404), respond(200)]);
      await expectLater(build(adapter).get<Object?>('/tasks/x'), throwsA(isA<DioException>()));
      expect(adapter.requests.length, 1);
    });

    test('exhausted budget ends in ServerWakingTimeout', () async {
      final adapter = ScriptedAdapter([respond(503)]);
      final dio = build(adapter, budget: const Duration(seconds: 3));
      try {
        await dio.get<Object?>('/days/current');
        fail('expected an error');
      } on DioException catch (e) {
        expect(mapDioException(e), isA<ServerWakingTimeout>());
      }
    });

    test('a plain connection failure is retried only once', () async {
      final adapter = ScriptedAdapter([failConnection()]);
      await expectLater(build(adapter).get<Object?>('/tasks'), throwsA(isA<DioException>()));
      expect(adapter.requests.length, 2);
    });

    test('status goes waking -> ok while the server wakes up', () async {
      final sink = RecordingSink();
      final adapter = ScriptedAdapter([respond(503), respond(200, '{"ok":true}')]);
      await build(adapter, sink: sink).get<Object?>('/days/current');
      expect(sink.statuses, contains(ServerStatus.waking));
      expect(sink.statuses.last, ServerStatus.ok);
    });
  });

  group('DioApiClient', () {
    test('maps failures to AppError only', () async {
      final adapter = ScriptedAdapter([respond(409, '{"code":"task.invalid_transition"}')]);
      final dio = buildDio(
        config: testConfig,
        tokens: TokenStore(InMemorySecureKeyValue(), FakeClock(DateTime.utc(2026, 11, 9, 8))),
        adapter: adapter,
        retryDelay: (_) async {},
      );
      final api = DioApiClient(dio);
      await expectLater(api.get<Object?>('/x', decode: (j) => j), throwsA(isA<ConflictError>()));
    });

    test('sends the Idempotency-Key header and decodes the body', () async {
      final adapter = ScriptedAdapter([respond(200, '{"n":1}')]);
      final dio = buildDio(
        config: testConfig,
        tokens: TokenStore(InMemorySecureKeyValue(), FakeClock(DateTime.utc(2026, 11, 9, 8))),
        adapter: adapter,
      );
      final api = DioApiClient(dio);
      final n = await api.post<int>('/y', body: {'a': 1}, idempotencyKey: 'key-1', decode: (j) => (j as Map)['n'] as int);
      expect(n, 1);
      expect(adapter.requests.single.headers['Idempotency-Key'], 'key-1');
    });
  });
}

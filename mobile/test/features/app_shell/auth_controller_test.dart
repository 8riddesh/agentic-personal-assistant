import 'package:daily_assistant/features/app_shell/data/kv_store.dart';
import 'package:daily_assistant/features/app_shell/data/token_store.dart';
import 'package:daily_assistant/features/app_shell/domain/app_error.dart';
import 'package:daily_assistant/features/app_shell/domain/auth_state.dart';
import 'package:daily_assistant/features/app_shell/presentation/providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fakes.dart';

Map<String, Object?> _settings({String tz = 'UTC', String? email}) => {
      'timezone': tz,
      'reminder_offsets_min': [60, 30],
      'report_email': email,
      'week_start': 1,
    };

void main() {
  late InMemoryKeyValueStore kv;
  late InMemorySecureKeyValue secure;
  late FakeApiClient api;
  late ProviderContainer container;
  late List<String> hookLog;

  setUp(() {
    kv = InMemoryKeyValueStore();
    secure = InMemorySecureKeyValue();
    api = FakeApiClient({
      'POST /auth/login': (c) => {'access_token': 'jwt-1', 'expires_at': '2026-12-09T08:00:00Z'},
      'GET /settings': (_) => _settings(),
      'PATCH /settings': (c) => _settings(tz: (c.body as Map)['timezone'] as String),
    });
    hookLog = [];
    container = ProviderContainer(
      overrides: testOverrides(
        api: api,
        kv: kv,
        secure: secure,
        deviceTimezone: 'Europe/Bucharest',
        extra: [
          logoutHooksProvider.overrideWithValue([
            () async => hookLog.add('cancel notifications'),
            () async => hookLog.add('clear cache'),
          ]),
        ],
      ),
    );
  });

  tearDown(() => container.dispose());

  test('without a stored token the state is Unauthenticated and nothing authenticated is requested', () async {
    final state = await container.read(authControllerProvider.future);
    expect(state, isA<Unauthenticated>());
    expect(api.calls, isEmpty);
  });

  test('a stored valid token means Authenticated at launch', () async {
    await TokenStore(secure, FakeClock(DateTime.utc(2026, 11, 9, 8)))
        .write(token: 'jwt', expiresAt: DateTime.utc(2026, 12, 9), email: 'me@example.com');
    final state = await container.read(authControllerProvider.future);
    expect(state, isA<Authenticated>());
  });

  test('login stores token + expiry, sends the device zone and ends Authenticated', () async {
    await container.read(authControllerProvider.future);
    await container.read(authControllerProvider.notifier).login(' me@example.com ', 'secret');

    final loginCall = api.callsTo('POST', '/auth/login').single;
    expect((loginCall.body as Map)['email'], 'me@example.com');
    expect((loginCall.body as Map)['timezone'], 'Europe/Bucharest');
    expect(secure.values[TokenStore.keyJwt], 'jwt-1');
    expect(secure.values[TokenStore.keyExpiresAt], '2026-12-09T08:00:00.000Z');
    expect(container.read(authControllerProvider).value, isA<Authenticated>());
  });

  test('wrong credentials propagate as UnauthorizedError and nothing is stored', () async {
    api.handlers['POST /auth/login'] = (_) => throw const UnauthorizedError();
    await container.read(authControllerProvider.future);
    await expectLater(
      container.read(authControllerProvider.notifier).login('me@example.com', 'bad'),
      throwsA(isA<UnauthorizedError>()),
    );
    expect(secure.values, isEmpty);
    expect(container.read(authControllerProvider).value, isA<Unauthenticated>());
  });

  test('the device time zone is PATCHed exactly once (tz.synced)', () async {
    await container.read(authControllerProvider.future);
    final auth = container.read(authControllerProvider.notifier);
    await auth.login('me@example.com', 'secret');
    expect(api.callsTo('PATCH', '/settings').length, 1);
    expect((api.callsTo('PATCH', '/settings').single.body as Map)['timezone'], 'Europe/Bucharest');
    expect(await kv.get(KvKeys.tzSynced), '1');

    await auth.logout();
    await auth.login('me@example.com', 'secret');
    expect(api.callsTo('PATCH', '/settings').length, 1, reason: 'second login must not patch again');
  });

  test('a failing settings sync never blocks the login', () async {
    api.handlers['GET /settings'] = (_) => throw const NetworkError();
    await container.read(authControllerProvider.future);
    await container.read(authControllerProvider.notifier).login('me@example.com', 'secret');
    expect(container.read(authControllerProvider).value, isA<Authenticated>());
  });

  test('logout clears the token, runs the hooks and keeps the email prefill', () async {
    await container.read(authControllerProvider.future);
    final auth = container.read(authControllerProvider.notifier);
    await auth.login('me@example.com', 'secret');

    await auth.logout(reason: 'Session expired');

    expect(secure.values.containsKey(TokenStore.keyJwt), isFalse);
    expect(secure.values[TokenStore.keyEmail], 'me@example.com');
    expect(hookLog, ['cancel notifications', 'clear cache']);
    final state = container.read(authControllerProvider).value;
    expect(state, isA<Unauthenticated>());
    expect((state! as Unauthenticated).reason, 'Session expired');
  });

  test('concurrent logouts collapse into one', () async {
    await container.read(authControllerProvider.future);
    final auth = container.read(authControllerProvider.notifier);
    await auth.login('me@example.com', 'secret');
    await Future.wait([auth.logout(), auth.logout(), auth.logout()]);
    expect(hookLog.length, 2);
  });

  test('an expired token found on resume logs out', () async {
    await TokenStore(secure, FakeClock(DateTime.utc(2026, 11, 9, 8)))
        .write(token: 'jwt', expiresAt: DateTime.utc(2026, 11, 9, 8, 0, 30), email: 'a@b.c');
    await container.read(authControllerProvider.future);
    final valid = await container.read(authControllerProvider.notifier).enforceValidToken();
    expect(valid, isFalse);
    expect(container.read(authControllerProvider).value, isA<Unauthenticated>());
  });

  test('settings controller: report email save and timezone sync use PATCH /settings', () async {
    await container.read(authControllerProvider.future);
    await container.read(authControllerProvider.notifier).login('me@example.com', 'secret');
    api.handlers['PATCH /settings'] = (c) {
      final body = c.body as Map;
      return _settings(tz: (body['timezone'] as String?) ?? 'UTC', email: body['report_email'] as String?);
    };
    final settings = container.read(settingsControllerProvider.notifier);
    await container.read(settingsControllerProvider.future);

    await settings.setReportEmail('me@example.com');
    expect(container.read(settingsControllerProvider).value?.reportEmail, 'me@example.com');
    expect((api.callsTo('PATCH', '/settings').last.body as Map).containsKey('report_email'), isTrue);

    await settings.setReportEmail(null);
    expect((api.callsTo('PATCH', '/settings').last.body as Map)['report_email'], isNull);

    await settings.syncTimezoneFromDevice();
    expect(container.read(settingsControllerProvider).value?.timezone, 'Europe/Bucharest');
  });
}

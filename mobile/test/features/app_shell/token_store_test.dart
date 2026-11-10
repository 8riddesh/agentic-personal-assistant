import 'package:daily_assistant/features/app_shell/data/token_store.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fakes.dart';

void main() {
  late InMemorySecureKeyValue secure;
  late FakeClock clock;
  late TokenStore store;

  setUp(() {
    secure = InMemorySecureKeyValue();
    clock = FakeClock(DateTime.utc(2026, 11, 9, 8));
    store = TokenStore(secure, clock);
  });

  test('a stored token is returned with its expiry and email', () async {
    await store.write(token: 'jwt', expiresAt: DateTime.utc(2026, 12, 9), email: 'me@example.com');
    final t = await store.read();
    expect(t?.token, 'jwt');
    expect(t?.expiresAt, DateTime.utc(2026, 12, 9));
    expect(t?.email, 'me@example.com');
  });

  test('a token expiring within 60 s is treated as absent', () async {
    await store.write(token: 'jwt', expiresAt: clock.now.add(const Duration(seconds: 59)), email: 'a@b.c');
    expect(await store.read(), isNull);
  });

  test('a token expiring in more than 60 s is valid', () async {
    await store.write(token: 'jwt', expiresAt: clock.now.add(const Duration(seconds: 61)), email: 'a@b.c');
    expect(await store.read(), isNotNull);
  });

  test('clear removes the token but keeps the email prefill', () async {
    await store.write(token: 'jwt', expiresAt: DateTime.utc(2026, 12, 9), email: 'me@example.com');
    await store.clear();
    expect(await store.read(), isNull);
    expect(await store.lastEmail(), 'me@example.com');
  });

  test('an unreadable keystore means logged out and storage is cleared', () async {
    await store.write(token: 'jwt', expiresAt: DateTime.utc(2026, 12, 9), email: 'a@b.c');
    secure.failReads = true;
    expect(await store.read(), isNull);
    secure.failReads = false;
    expect(secure.values.containsKey(TokenStore.keyJwt), isFalse);
  });

  test('nothing stored -> null', () async {
    expect(await store.read(), isNull);
  });
}

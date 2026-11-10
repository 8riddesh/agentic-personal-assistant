import 'dart:async';

import 'package:daily_assistant/features/app_shell/data/token_store.dart';
import 'package:daily_assistant/features/app_shell/domain/app_error.dart';
import 'package:daily_assistant/features/app_shell/domain/auth_state.dart';
import 'package:daily_assistant/features/app_shell/presentation/login_screen.dart';
import 'package:daily_assistant/features/app_shell/presentation/providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fakes.dart';

class _Auth extends AuthController {
  _Auth(this.onLogin, {this.reason});

  final Future<void> Function(String email, String password) onLogin;
  final String? reason;

  @override
  Future<AuthState> build() async => Unauthenticated(reason: reason);

  @override
  Future<void> login(String email, String password) => onLogin(email, password);
}

class _WakingStatus extends ServerStatusNotifier {
  @override
  ServerStatus build() => ServerStatus.waking;
}

List<Override> _overrides(
  Future<void> Function(String, String) onLogin, {
  String? reason,
  InMemorySecureKeyValue? secure,
  bool waking = false,
}) =>
    testOverrides(
      secure: secure,
      extra: [
        authControllerProvider.overrideWith(() => _Auth(onLogin, reason: reason)),
        if (waking) serverStatusProvider.overrideWith(_WakingStatus.new),
      ],
    );

Future<void> _fill(WidgetTester tester, {String email = 'me@example.com', String password = 'secret'}) async {
  await tester.enterText(find.byKey(const Key('login-email')), email);
  await tester.enterText(find.byKey(const Key('login-password')), password);
}

void main() {
  testWidgets('shows both fields, a Log in button and no sign-up link', (tester) async {
    await pumpScreen(tester, const LoginScreen(), overrides: _overrides((e, p) async {}));
    expect(find.byKey(const Key('login-email')), findsOneWidget);
    expect(find.byKey(const Key('login-password')), findsOneWidget);
    expect(find.text('Log in'), findsOneWidget);
    expect(find.textContaining('Sign up'), findsNothing);
  });

  testWidgets('validates empty fields and does not call login', (tester) async {
    var calls = 0;
    await pumpScreen(tester, const LoginScreen(), overrides: _overrides((e, p) async => calls++));
    await tester.tap(find.byKey(const Key('login-submit')));
    await tester.pump();
    expect(find.text('Email is required'), findsOneWidget);
    expect(find.text('Password is required'), findsOneWidget);
    expect(calls, 0);
  });

  testWidgets('rejects an email without @', (tester) async {
    await pumpScreen(tester, const LoginScreen(), overrides: _overrides((e, p) async {}));
    await _fill(tester, email: 'nope');
    await tester.tap(find.byKey(const Key('login-submit')));
    await tester.pump();
    expect(find.text('Enter a valid email'), findsOneWidget);
  });

  testWidgets('submits the entered credentials', (tester) async {
    String? email;
    String? password;
    await pumpScreen(tester, const LoginScreen(), overrides: _overrides((e, p) async {
      email = e;
      password = p;
    }));
    await _fill(tester);
    await tester.tap(find.byKey(const Key('login-submit')));
    await tester.pump();
    expect(email, 'me@example.com');
    expect(password, 'secret');
  });

  testWidgets('shows "Logging in…" and disables the button while submitting', (tester) async {
    final completer = Completer<void>();
    await pumpScreen(tester, const LoginScreen(), overrides: _overrides((e, p) => completer.future));
    await _fill(tester);
    await tester.tap(find.byKey(const Key('login-submit')));
    await tester.pump();

    expect(find.text('Logging in…'), findsOneWidget);
    final button = tester.widget<FilledButton>(find.byKey(const Key('login-submit')));
    expect(button.onPressed, isNull);

    completer.complete();
    await tester.pump();
  });

  testWidgets('wrong credentials show "Wrong email or password" and stay on the form', (tester) async {
    await pumpScreen(tester, const LoginScreen(), overrides: _overrides((e, p) async => throw const UnauthorizedError()));
    await _fill(tester);
    await tester.tap(find.byKey(const Key('login-submit')));
    await tester.pump();
    expect(find.text('Wrong email or password'), findsOneWidget);
    expect(find.byKey(const Key('login-email')), findsOneWidget);
  });

  testWidgets('offline shows a retryable message', (tester) async {
    await pumpScreen(tester, const LoginScreen(), overrides: _overrides((e, p) async => throw const NetworkError()));
    await _fill(tester);
    await tester.tap(find.byKey(const Key('login-submit')));
    await tester.pump();
    expect(find.textContaining("You're offline"), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
  });

  testWidgets('shows the waking-server message while submitting on a sleeping server', (tester) async {
    final completer = Completer<void>();
    await pumpScreen(tester, const LoginScreen(), overrides: _overrides((e, p) => completer.future, waking: true));
    await _fill(tester);
    await tester.tap(find.byKey(const Key('login-submit')));
    await tester.pump();
    expect(find.byKey(const Key('login-waking')), findsOneWidget);
    completer.complete();
    await tester.pump();
  });

  testWidgets('prefills the last email and shows the session-expired reason', (tester) async {
    final secure = InMemorySecureKeyValue()..values[TokenStore.keyEmail] = 'me@example.com';
    await pumpScreen(
      tester,
      const LoginScreen(),
      overrides: _overrides((e, p) async {}, reason: 'Session expired — please log in again', secure: secure),
    );
    await tester.pump();
    expect(find.text('me@example.com'), findsOneWidget);
    expect(find.byKey(const Key('login-reason')), findsOneWidget);
  });
}

import 'package:daily_assistant/features/app_shell/domain/auth_state.dart';
import 'package:daily_assistant/features/app_shell/presentation/router.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final authed = Authenticated(expiresAt: DateTime.utc(2026, 12, 9));

  test('unknown auth sends everything to /splash', () {
    expect(guardRedirect(const AuthUnknown(), Uri.parse('/today')), '/splash');
    expect(guardRedirect(const AuthUnknown(), Uri.parse('/splash')), isNull);
  });

  test('unauthenticated users are sent to /login, remembering where they were going', () {
    expect(guardRedirect(const Unauthenticated(), Uri.parse('/login')), isNull);
    expect(guardRedirect(const Unauthenticated(), Uri.parse('/splash')), '/login');
    final redirect = guardRedirect(const Unauthenticated(), Uri.parse('/settings?focus=report_email'));
    expect(redirect, startsWith('/login?from='));
    expect(Uri.parse(redirect!).queryParameters['from'], '/settings?focus=report_email');
  });

  test('authenticated users leave /login and /splash for Today', () {
    expect(guardRedirect(authed, Uri.parse('/login')), '/today');
    expect(guardRedirect(authed, Uri.parse('/splash')), '/today');
  });

  test('the remembered "from" location is restored after login', () {
    expect(guardRedirect(authed, Uri.parse('/login?from=%2Fsettings%3Ffocus%3Dreport_email')), '/settings?focus=report_email');
  });

  test('authenticated users stay where they are', () {
    expect(guardRedirect(authed, Uri.parse('/today')), isNull);
    expect(guardRedirect(authed, Uri.parse('/settings/battery')), isNull);
  });
}

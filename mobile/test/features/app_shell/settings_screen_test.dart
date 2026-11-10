import 'package:daily_assistant/features/app_shell/domain/app_error.dart';
import 'package:daily_assistant/features/app_shell/domain/auth_state.dart';
import 'package:daily_assistant/features/app_shell/presentation/providers.dart';
import 'package:daily_assistant/features/app_shell/presentation/settings_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fakes.dart';

class _Auth extends AuthController {
  int logouts = 0;

  @override
  Future<AuthState> build() async => Authenticated(expiresAt: DateTime.utc(2026, 12, 9), email: 'me@example.com');

  @override
  Future<void> logout({String? reason}) async {
    logouts++;
    state = const AsyncData(Unauthenticated());
  }
}

Map<String, Object?> _settings({String tz = 'UTC', String? email}) => {
      'timezone': tz,
      'reminder_offsets_min': [60, 30],
      'report_email': email,
      'week_start': 1,
    };

void main() {
  late FakeApiClient api;
  late _Auth auth;

  setUp(() {
    api = FakeApiClient({
      'GET /settings': (_) => _settings(),
      'PATCH /settings': (c) {
        final body = c.body as Map;
        return _settings(tz: (body['timezone'] as String?) ?? 'UTC', email: body['report_email'] as String?);
      },
    });
    auth = _Auth();
  });

  Future<void> pump(WidgetTester tester, {String device = 'UTC'}) async {
    useTallScreen(tester);
    await pumpScreen(
      tester,
      const SettingsScreen(),
      overrides: testOverrides(
        api: api,
        deviceTimezone: device,
        extra: [authControllerProvider.overrideWith(() => auth)],
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('shows the read-only reminder summary and the API host', (tester) async {
    await pump(tester);
    expect(find.text('1 hour and 30 minutes before start; one completion check'), findsOneWidget);
    expect(find.text('api.test'), findsOneWidget);
  });

  testWidgets('no sync button when the device zone equals the server zone', (tester) async {
    await pump(tester);
    expect(find.byKey(const Key('tz-sync')), findsNothing);
  });

  testWidgets('a zone mismatch offers "Use device time zone" and PATCHes it', (tester) async {
    await pump(tester, device: 'Europe/Bucharest');
    expect(find.text('Use device time zone (Europe/Bucharest)'), findsOneWidget);

    await tester.tap(find.byKey(const Key('tz-sync')));
    await tester.pumpAndSettle();

    expect((api.callsTo('PATCH', '/settings').single.body as Map)['timezone'], 'Europe/Bucharest');
    expect(find.text('Server: Europe/Bucharest'), findsOneWidget);
    expect(find.byKey(const Key('tz-sync')), findsNothing);
  });

  testWidgets('an invalid report email is rejected client-side', (tester) async {
    await pump(tester);
    await tester.enterText(find.byKey(const Key('report-email-field')), 'not-an-email');
    await tester.tap(find.byKey(const Key('report-email-save')));
    await tester.pump();
    expect(find.text('Enter a valid email address'), findsOneWidget);
    expect(api.callsTo('PATCH', '/settings'), isEmpty);
  });

  testWidgets('a valid report email is saved with PATCH /settings', (tester) async {
    await pump(tester);
    await tester.enterText(find.byKey(const Key('report-email-field')), 'me@example.com');
    await tester.tap(find.byKey(const Key('report-email-save')));
    await tester.pumpAndSettle();
    expect((api.callsTo('PATCH', '/settings').single.body as Map)['report_email'], 'me@example.com');
    expect(find.text('Report email saved'), findsOneWidget);
  });

  testWidgets('an empty report email clears it (null)', (tester) async {
    api.handlers['GET /settings'] = (_) => _settings(email: 'old@example.com');
    await pump(tester);
    expect(find.text('old@example.com'), findsOneWidget);

    await tester.enterText(find.byKey(const Key('report-email-field')), '');
    await tester.tap(find.byKey(const Key('report-email-save')));
    await tester.pumpAndSettle();

    final body = api.callsTo('PATCH', '/settings').single.body as Map;
    expect(body.containsKey('report_email'), isTrue);
    expect(body['report_email'], isNull);
  });

  testWidgets('a server error on save shows its message', (tester) async {
    api.handlers['PATCH /settings'] = (_) => throw const ValidationError(detail: 'rejected');
    await pump(tester);
    await tester.enterText(find.byKey(const Key('report-email-field')), 'me@example.com');
    await tester.tap(find.byKey(const Key('report-email-save')));
    await tester.pumpAndSettle();
    expect(find.text('rejected'), findsOneWidget);
  });

  testWidgets('log out asks for confirmation first', (tester) async {
    await pump(tester);
    await tester.tap(find.byKey(const Key('logout-button')));
    await tester.pumpAndSettle();
    expect(find.text('Log out of this device?'), findsOneWidget);
    expect(auth.logouts, 0);

    await tester.tap(find.byKey(const Key('logout-confirm')));
    await tester.pumpAndSettle();
    expect(auth.logouts, 1);
  });

  testWidgets('cancelling the confirmation does not log out', (tester) async {
    await pump(tester);
    await tester.tap(find.byKey(const Key('logout-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(auth.logouts, 0);
  });

  test('validateReportEmail', () {
    expect(validateReportEmail(''), isNull);
    expect(validateReportEmail('  '), isNull);
    expect(validateReportEmail('a@b.co'), isNull);
    expect(validateReportEmail('a@b'), isNotNull);
    expect(validateReportEmail('a b@c.de'), isNotNull);
  });
}

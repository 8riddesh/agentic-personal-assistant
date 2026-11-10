import 'package:daily_assistant/features/app_shell/domain/app_error.dart';
import 'package:daily_assistant/features/app_shell/presentation/app.dart';
import 'package:daily_assistant/features/app_shell/presentation/providers.dart';
import 'package:daily_assistant/features/app_shell/presentation/widgets/async_value_view.dart';
import 'package:daily_assistant/features/app_shell/presentation/widgets/empty_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fakes.dart';

class _WakingStatus extends ServerStatusNotifier {
  @override
  ServerStatus build() => ServerStatus.waking;
}

Widget _view(AsyncValue<int> value, {VoidCallback? onRetry, bool Function(int)? isEmpty}) => AsyncValueView<int>(
      value: value,
      onRetry: onRetry,
      isEmpty: isEmpty,
      empty: const EmptyView(message: 'Nothing here'),
      data: (v) => Text('value $v'),
    );

void main() {
  testWidgets('loading shows a spinner only', (tester) async {
    await pumpScreen(tester, _view(const AsyncLoading<int>()), overrides: testOverrides());
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.byKey(const Key('waking-text')), findsNothing);
  });

  testWidgets('loading while the server wakes up explains the wait', (tester) async {
    await pumpScreen(
      tester,
      _view(const AsyncLoading<int>()),
      overrides: testOverrides(extra: [serverStatusProvider.overrideWith(_WakingStatus.new)]),
    );
    expect(find.text('Waking server… this can take up to a minute'), findsOneWidget);
  });

  testWidgets('error shows the user message and Retry', (tester) async {
    var retries = 0;
    await pumpScreen(
      tester,
      _view(AsyncError<int>(const NetworkError(), StackTrace.empty), onRetry: () => retries++),
      overrides: testOverrides(),
    );
    expect(find.text("You're offline. Check your connection."), findsOneWidget);
    await tester.tap(find.text('Retry'));
    expect(retries, 1);
  });

  testWidgets('empty shows the empty view', (tester) async {
    await pumpScreen(tester, _view(const AsyncData(0), isEmpty: (v) => v == 0), overrides: testOverrides());
    expect(find.text('Nothing here'), findsOneWidget);
    expect(find.text('value 0'), findsNothing);
  });

  testWidgets('content is rendered', (tester) async {
    await pumpScreen(tester, _view(const AsyncData(5)), overrides: testOverrides());
    expect(find.text('value 5'), findsOneWidget);
  });

  testWidgets('refreshing keeps the old content with a progress bar on top', (tester) async {
    final refreshing = const AsyncLoading<int>().copyWithPrevious(const AsyncData(5));
    await pumpScreen(tester, _view(refreshing), overrides: testOverrides());
    expect(find.text('value 5'), findsOneWidget);
    expect(find.byKey(const Key('refresh-progress')), findsOneWidget);
  });

  testWidgets('ConfigErrorApp shows the configuration message (M-SHELL-AC-12)', (tester) async {
    await tester.pumpWidget(const ConfigErrorApp(message: 'API_BASE_URL not configured'));
    expect(find.text('Configuration error'), findsOneWidget);
    expect(find.text('API_BASE_URL not configured'), findsOneWidget);
  });
}

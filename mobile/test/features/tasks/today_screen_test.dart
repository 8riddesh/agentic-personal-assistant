import 'dart:async';

import 'package:daily_assistant/features/app_shell/domain/app_error.dart';
import 'package:daily_assistant/features/app_shell/presentation/providers.dart';
import 'package:daily_assistant/features/tasks/domain/entities.dart';
import 'package:daily_assistant/features/tasks/presentation/today_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fakes.dart';
import '../../support/tasks_fakes.dart';

class _WakingStatus extends ServerStatusNotifier {
  @override
  ServerStatus build() => ServerStatus.waking;
}

Future<FakeDay> _pump(
  WidgetTester tester,
  Future<TodayState> Function() builder, {
  bool waking = false,
}) async {
  useTallScreen(tester);
  final fake = FakeDay(builder);
  await pumpScreen(
    tester,
    const TodayScreen(),
    overrides: testOverrides(extra: [
      authenticated(),
      dayOverride(fake),
      if (waking) serverStatusProvider.overrideWith(_WakingStatus.new),
    ]),
  );
  await tester.pump();
  return fake;
}

void main() {
  testWidgets('loading shows a spinner', (tester) async {
    final never = Completer<TodayState>();
    await _pump(tester, () => never.future);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });

  testWidgets('waking server shows the waking text while loading', (tester) async {
    final never = Completer<TodayState>();
    await _pump(tester, () => never.future, waking: true);
    expect(find.byKey(const Key('waking-text')), findsOneWidget);
  });

  testWidgets('error without cache shows ErrorView and Retry refreshes', (tester) async {
    final fake = await _pump(tester, () async => throw const ServerWakingTimeout());
    expect(find.text("Server didn't wake up. Retry."), findsOneWidget);
    await tester.tap(find.text('Retry'));
    expect(fake.refreshCalls, 1);
  });

  testWidgets('empty open day shows "Nothing planned yet" and an Add task button', (tester) async {
    await _pump(tester, () async => makeToday([]));
    expect(find.text('Nothing planned yet'), findsOneWidget);
    expect(find.text('Add task'), findsWidgets);
  });

  testWidgets('content: header, progress, tiles with time/title/category/predicted end and chips', (tester) async {
    await _pump(tester, () async {
      return makeToday([
        makeTask(
          id: 'a',
          title: 'Write report',
          startAt: DateTime.utc(2026, 11, 9, 14),
          predictedEndAt: DateTime.utc(2026, 11, 9, 15, 10),
        ),
        makeTask(id: 'b', title: 'Read book'),
        makeTask(id: 'c', title: 'Gym', status: TaskStatus.completed, startAt: DateTime.utc(2026, 11, 9, 7)),
      ]);
    });

    expect(find.text('Today · Mon 9 Nov'), findsOneWidget);
    expect(find.text('1 of 3 done'), findsOneWidget);
    expect(find.text('Write report'), findsOneWidget);
    expect(find.text('14:00'), findsOneWidget);
    expect(find.text('Work · ends ~15:10'), findsOneWidget);
    expect(find.text('Anytime'), findsOneWidget);
    expect(find.text('Planned'), findsNWidgets(2));
    // finished tasks sit in a collapsed section
    expect(find.text('Finished (1)'), findsOneWidget);
    expect(find.text('Gym'), findsNothing);
  });

  testWidgets('the Finished section expands to show terminal tasks', (tester) async {
    await _pump(tester, () async => makeToday([makeTask(id: 'c', title: 'Gym', status: TaskStatus.completed)]));
    await tester.tap(find.text('Finished (1)'));
    await tester.pumpAndSettle();
    expect(find.text('Gym'), findsOneWidget);
  });

  testWidgets('offline with cache: note with last update time and the Add button disabled', (tester) async {
    await _pump(tester, () async => makeToday([makeTask(title: 'Cached task')], fromCache: true));
    expect(find.text('Cached task'), findsOneWidget);
    expect(find.text('Offline · last updated 08:00'), findsOneWidget);
    final fab = tester.widget<FloatingActionButton>(find.byKey(const Key('add-task-fab')));
    expect(fab.onPressed, isNull);
  });

  testWidgets('open online day: the Add task button is enabled', (tester) async {
    await _pump(tester, () async => makeToday([makeTask()]));
    final fab = tester.widget<FloatingActionButton>(find.byKey(const Key('add-task-fab')));
    expect(fab.onPressed, isNotNull);
  });

  testWidgets('closed day: banner with View report, no Add button (M-TASKS-AC-15)', (tester) async {
    await _pump(
      tester,
      () async => makeToday(
        [makeTask(title: 'Done thing', status: TaskStatus.completed)],
        day: makeDay(state: DayState.closed, dailyReportId: 'rep-1'),
      ),
    );
    expect(find.text('Day closed at 19:40'), findsOneWidget);
    expect(find.text('View report'), findsOneWidget);
    expect(find.byKey(const Key('add-task-fab')), findsNothing);
  });

  testWidgets('tapping a planned task opens the status sheet', (tester) async {
    await _pump(tester, () async => makeToday([makeTask(id: 'a', title: 'Write report')]));
    await tester.tap(find.byKey(const Key('task-tile-a')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('status-option-completed')), findsOneWidget);
  });

  testWidgets('tapping a finished task opens read-only details', (tester) async {
    await _pump(tester, () async => makeToday([makeTask(id: 'c', title: 'Gym', status: TaskStatus.completed)]));
    await tester.tap(find.text('Finished (1)'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('task-tile-c')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('details-status')), findsOneWidget);
    expect(find.byKey(const Key('status-option-completed')), findsNothing);
  });
}

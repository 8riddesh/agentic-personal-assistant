import 'package:daily_assistant/features/app_shell/domain/local_date.dart';
import 'package:daily_assistant/features/tasks/domain/entities.dart';
import 'package:daily_assistant/features/tasks/presentation/task_tile.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fakes.dart';

Future<void> _pumpTile(WidgetTester tester, Task task, {Task? postponedTo}) => tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: TaskTile(task: task, location: utc, postponedTo: postponedTo)),
      ),
    );

void main() {
  setUpAll(initTz);

  testWidgets('anytime task shows "Anytime" and no predicted end', (tester) async {
    await _pumpTile(tester, makeTask(title: 'Read'));
    expect(find.text('Anytime'), findsOneWidget);
    expect(find.text('Work'), findsOneWidget);
  });

  testWidgets('timed task shows HH:mm and the predicted end', (tester) async {
    await _pumpTile(
      tester,
      makeTask(startAt: DateTime.utc(2026, 11, 9, 14), predictedEndAt: DateTime.utc(2026, 11, 9, 15, 10)),
    );
    expect(find.text('14:00'), findsOneWidget);
    expect(find.text('Work · ends ~15:10'), findsOneWidget);
  });

  testWidgets('"Not yet" chip when the check was answered not_yet', (tester) async {
    await _pumpTile(tester, makeTask(checkResponse: CheckResponse.notYet));
    expect(find.byKey(const Key('not-yet-chip')), findsOneWidget);
  });

  testWidgets('sync icon while an offline answer is pending', (tester) async {
    await _pumpTile(tester, makeTask(status: TaskStatus.completed, pendingStatus: 'completed'));
    expect(find.byKey(const Key('sync-icon')), findsOneWidget);
    await _pumpTile(tester, makeTask());
    expect(find.byKey(const Key('sync-icon')), findsNothing);
  });

  testWidgets('each status has its label', (tester) async {
    const labels = {
      TaskStatus.planned: 'Planned',
      TaskStatus.completed: 'Completed',
      TaskStatus.postponed: 'Postponed',
      TaskStatus.cancelled: 'Cancelled',
      TaskStatus.cantDo: "Can't do",
      TaskStatus.missed: 'Missed',
    };
    for (final entry in labels.entries) {
      await _pumpTile(tester, makeTask(status: entry.key));
      expect(find.text(entry.value), findsOneWidget, reason: entry.key.name);
    }
  });

  testWidgets('postponed shows where it went', (tester) async {
    final copy = makeTask(id: 'copy', startAt: DateTime.utc(2026, 11, 10, 10));
    await _pumpTile(tester, makeTask(status: TaskStatus.postponed), postponedTo: copy);
    expect(find.text('Work · postponed to Tue 10:00'), findsOneWidget);
  });

  testWidgets("can't do shows its reason", (tester) async {
    final t = Task(
      id: 'x',
      localDate: const LocalDate(2026, 11, 9),
      title: 'Dentist',
      category: 'Health',
      status: TaskStatus.cantDo,
      createdVia: CreatedVia.form,
      statusReason: 'Clinic closed',
    );
    await _pumpTile(tester, t);
    expect(find.text('Health · Clinic closed'), findsOneWidget);
  });
}

import 'package:daily_assistant/features/app_shell/data/kv_store.dart';
import 'package:daily_assistant/features/app_shell/domain/app_error.dart';
import 'package:daily_assistant/features/app_shell/domain/local_date.dart';
import 'package:daily_assistant/features/tasks/data/day_cache.dart';
import 'package:daily_assistant/features/tasks/domain/entities.dart';
import 'package:daily_assistant/features/tasks/domain/status_change.dart';
import 'package:daily_assistant/features/tasks/presentation/providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fakes.dart';
import '../../support/tasks_fakes.dart';

void main() {
  late InMemoryKeyValueStore kv;
  late FakeApiClient api;
  late ProviderContainer container;

  ProviderContainer build() => ProviderContainer(
        overrides: testOverrides(api: api, kv: kv, extra: [authenticated()]),
      );

  setUp(() {
    kv = InMemoryKeyValueStore();
    api = FakeApiClient({
      'GET /days/current': (_) => dayJson(),
      'GET /tasks': (_) => [taskJson(id: 'a', startAt: '2026-11-09T10:00:00Z')],
    });
  });

  tearDown(() => container.dispose());

  test('first load: GET /days/current then GET /tasks?date=<day> (M-TASKS-AC-01)', () async {
    container = build();
    final state = await container.read(currentDayControllerProvider.future);
    expect(api.calls.map((c) => c.toString()), ['GET /days/current', 'GET /tasks']);
    expect(api.calls.last.query, {'date': '2026-11-09'});
    expect(state.fromCache, isFalse);
    expect(state.tasks.single.id, 'a');
  });

  test('cache first: emits the cached day (fromCache) and then the server answer', () async {
    await DayCache(kv).replaceDay(makeDay(), [makeTask(id: 'cached')], DateTime.utc(2026, 11, 9, 7));
    container = build();
    final seen = <TodayState>[];
    container.listen<AsyncValue<TodayState>>(currentDayControllerProvider, (previous, next) {
      final v = next.value;
      if (v != null && !next.isLoading) seen.add(v);
    }, fireImmediately: true);

    await container.read(currentDayControllerProvider.future);
    await settle();

    expect(seen.first.fromCache, isTrue);
    expect(seen.first.tasks.single.id, 'cached');
    expect(seen.last.fromCache, isFalse);
    expect(seen.last.tasks.single.id, 'a');
  });

  test('refresh failure keeps the old content marked as cached', () async {
    container = build();
    await container.read(currentDayControllerProvider.future);
    api.handlers['GET /days/current'] = (_) => throw const NetworkError();

    await container.read(currentDayControllerProvider.notifier).refresh();

    final state = container.read(currentDayControllerProvider).value!;
    expect(state.fromCache, isTrue);
    expect(state.tasks.single.id, 'a');
  });

  test('a failing first load without cache is an error state', () async {
    api.handlers['GET /days/current'] = (_) => throw const ServerWakingTimeout();
    container = build();
    await expectLater(container.read(currentDayControllerProvider.future), throwsA(isA<ServerWakingTimeout>()));
  });

  test('a date change fetches GET /days/{previous} and reports an automatic close', () async {
    container = build();
    await container.read(currentDayControllerProvider.future);

    api.handlers['GET /days/current'] = (_) => dayJson(id: 'd2', localDate: '2026-11-10');
    api.handlers['GET /tasks'] = (_) => [];
    api.handlers['GET /days/2026-11-09'] = (_) => {
          ...dayJson(state: 'closed'),
          'close_mode': 'auto_midnight',
          'daily_report_id': 'rep-1',
        };

    await container.read(currentDayControllerProvider.notifier).refresh();

    expect(api.callsTo('GET', '/days/2026-11-09'), hasLength(1));
    final state = container.read(currentDayControllerProvider).value!;
    expect(state.day.localDate, LocalDate.parse('2026-11-10'));
    expect(state.autoClosedReportId, 'rep-1');
  });

  test('no previous-day lookup when the date did not change', () async {
    container = build();
    await container.read(currentDayControllerProvider.future);
    await container.read(currentDayControllerProvider.notifier).refresh();
    expect(api.calls.where((c) => c.path.startsWith('/days/2')), isEmpty);
  });

  test('applyTask replaces by id and inserts a new task of the open day (M-TASKS-AC-12)', () async {
    container = build();
    await container.read(currentDayControllerProvider.future);
    final controller = container.read(currentDayControllerProvider.notifier);

    await controller.applyTask(makeTask(id: 'a', title: 'Renamed'));
    await controller.applyTask(makeTask(id: 'b', title: 'Second'));
    await controller.applyTask(makeTask(id: 'other-day', localDate: LocalDate.parse('2026-11-12')));

    final tasks = container.read(currentDayControllerProvider).value!.tasks;
    expect(tasks.map((t) => t.id), ['a', 'b']);
    expect(tasks.first.title, 'Renamed');
    expect((await DayCache(kv).readLatest())?.tasks.map((t) => t.id), contains('b'));
  });

  test('changeStatus applies the returned task to the state', () async {
    api.handlers['POST /tasks/a/status'] = (_) => {'task': taskJson(id: 'a', status: 'cancelled'), 'created_task': null};
    container = build();
    final state = await container.read(currentDayControllerProvider.future);

    await container.read(currentDayControllerProvider.notifier).changeStatus(state.tasks.single, const Cancelled());

    expect(container.read(currentDayControllerProvider).value!.tasks.single.status, TaskStatus.cancelled);
  });

  test('changeStatus on a 409 refreshes and rethrows', () async {
    api.handlers['POST /tasks/a/status'] = (_) => throw const ConflictError(code: 'task.invalid_transition');
    container = build();
    final state = await container.read(currentDayControllerProvider.future);
    final before = api.callsTo('GET', '/days/current').length;

    await expectLater(
      container.read(currentDayControllerProvider.notifier).changeStatus(state.tasks.single, const Completed()),
      throwsA(isA<ConflictError>()),
    );
    await settle();

    expect(api.callsTo('GET', '/days/current').length, greaterThan(before));
  });

  test('createTask applies the new task and refreshes in the background', () async {
    api.handlers['POST /tasks'] = (_) => {'task': taskJson(id: 'new', title: 'New one'), 'template': null, 'replayed': false};
    container = build();
    await container.read(currentDayControllerProvider.future);

    final task = await container.read(currentDayControllerProvider.notifier).createTask(
          TaskDraft(title: 'New one', localDate: LocalDate.parse('2026-11-09'), isRecurring: false),
          overridden: false,
          via: CreatedVia.form,
        );

    expect(task.id, 'new');
    expect(container.read(currentDayControllerProvider).value!.tasks.map((t) => t.id), contains('new'));
  });

  test('logged out: the controller is in an error state and no request is made', () async {
    final loggedOut = ProviderContainer(overrides: testOverrides(api: api, kv: kv));
    addTearDown(loggedOut.dispose);
    await expectLater(loggedOut.read(currentDayControllerProvider.future), throwsA(isA<UnauthorizedError>()));
    expect(api.calls, isEmpty);
    container = build(); // satisfy tearDown
  });
}

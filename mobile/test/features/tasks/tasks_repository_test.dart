import 'package:daily_assistant/features/app_shell/data/kv_store.dart';
import 'package:daily_assistant/features/app_shell/domain/app_error.dart';
import 'package:daily_assistant/features/app_shell/domain/local_date.dart';
import 'package:daily_assistant/features/app_shell/domain/outbox.dart';
import 'package:daily_assistant/features/tasks/data/day_cache.dart';
import 'package:daily_assistant/features/tasks/data/tasks_api.dart';
import 'package:daily_assistant/features/tasks/data/tasks_repository.dart';
import 'package:daily_assistant/features/tasks/domain/entities.dart';
import 'package:daily_assistant/features/tasks/domain/status_change.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fakes.dart';

void main() {
  late InMemoryKeyValueStore store;
  late FakeApiClient api;
  late FakeClock clock;
  late OutboxService outbox;
  late DayCache cache;
  late TasksRepository repo;

  setUp(() {
    store = InMemoryKeyValueStore();
    api = FakeApiClient({
      'GET /days/current': (_) => dayJson(),
      'GET /tasks': (_) => [taskJson(id: 'a', startAt: '2026-11-09T10:00:00Z')],
    });
    clock = FakeClock(DateTime.utc(2026, 11, 9, 8));
    outbox = OutboxService(store: store, api: api, clock: clock);
    cache = DayCache(store);
    repo = TasksRepository(
      tasks: TasksApi(api),
      days: DayApi(api),
      feasibility: FeasibilityApi(api),
      cache: cache,
      outbox: outbox,
      clock: clock,
    );
  });

  tearDown(() => outbox.dispose());

  test('loadFresh calls GET /days/current then GET /tasks?date= and caches the result', () async {
    final state = await repo.loadFresh();
    expect(api.calls.map((c) => c.toString()), ['GET /days/current', 'GET /tasks']);
    expect(api.calls.last.query, {'date': '2026-11-09'});
    expect(state.fromCache, isFalse);
    expect(state.tasks.single.id, 'a');
    expect((await cache.readLatest())?.tasks.single.id, 'a');
  });

  test('readCached returns the cache flagged fromCache', () async {
    await repo.loadFresh();
    final cached = await repo.readCached();
    expect(cached?.fromCache, isTrue);
    expect(cached?.day.localDate, LocalDate.parse('2026-11-09'));
  });

  group('create', () {
    final draft = TaskDraft(
      title: ' Gym ',
      category: 'Health',
      localDate: LocalDate.parse('2026-11-09'),
      startAt: DateTime.utc(2026, 11, 9, 17),
      estimateMin: 60,
      isRecurring: true,
      recurrence: const Weekly({0, 2, 4}),
    );

    test('sends the assessment, override flag, created_via and an idempotency id', () async {
      api.handlers['POST /tasks'] = (_) => {'task': taskJson(id: 'new'), 'template': null, 'replayed': false};
      final task = await repo.create(draft, assessmentId: 'as-1', overridden: true, via: CreatedVia.chat);
      final body = api.callsTo('POST', '/tasks').single.body as Map;
      expect(task.id, 'new');
      expect(body['title'], 'Gym');
      expect(body['assessment_id'], 'as-1');
      expect(body['overridden'], true);
      expect(body['created_via'], 'chat');
      expect(body['is_recurring'], true);
      expect(body['recurrence'], {'freq': 'weekly', 'byweekday': [0, 2, 4]});
      expect(body['start_at'], '2026-11-09T17:00:00.000Z');
      expect(body['client_request_id'], isA<String>());
    });

    test('without assessment: no assessment_id and overridden false', () async {
      api.handlers['POST /tasks'] = (_) => taskJson(id: 'new');
      await repo.create(draft, overridden: false, via: CreatedVia.form, clientRequestId: 'req-1');
      final body = api.callsTo('POST', '/tasks').single.body as Map;
      expect(body.containsKey('assessment_id'), isFalse);
      expect(body['overridden'], false);
      expect(body['client_request_id'], 'req-1');
    });
  });

  group('setStatus', () {
    final task = makeTask(id: 'a', title: 'Write report', startAt: DateTime.utc(2026, 11, 9, 10));

    test('online: posts the status body with source', () async {
      api.handlers['POST /tasks/a/status'] = (_) => {'task': taskJson(id: 'a', status: 'completed'), 'created_task': null};
      final updated = await repo.setStatus(task, const CantDo('sick'), source: 'app');
      final body = api.callsTo('POST', '/tasks/a/status').single.body as Map;
      expect(body, {'status': 'cant_do', 'reason': 'sick', 'source': 'app'});
      expect(updated.status, TaskStatus.completed); // whatever the server answered
    });

    test('offline completed is queued in the outbox, cached with a pending status', () async {
      await cache.replaceDay(makeDay(), [task], clock.now);
      api.handlers['POST /tasks/a/status'] = (_) => throw const NetworkError();

      final updated = await repo.setStatus(task, const Completed());

      expect(updated.status, TaskStatus.completed);
      expect(updated.pendingStatus, 'completed');
      final queued = (await outbox.entries()).single;
      expect(queued.path, '/tasks/a/status');
      expect(queued.label, "Mark 'Write report' completed");
      // the completion time is fixed at answer time, not at sync time
      expect(queued.bodyJson, contains('"finished_at":"2026-11-09T08:00:00.000Z"'));
      expect((await cache.pendingStatuses())['a'], 'completed');
    });

    test('offline cancelled and cant_do are queued too', () async {
      api.handlers['POST /tasks/a/status'] = (_) => throw const ServerWakingTimeout();
      final cancelled = await repo.setStatus(task, const Cancelled(reason: 'skip'));
      final cantDo = await repo.setStatus(task, const CantDo('sick'));
      expect(cancelled.status, TaskStatus.cancelled);
      expect(cantDo.status, TaskStatus.cantDo);
      expect(cantDo.statusReason, 'sick');
      expect((await outbox.entries()).length, 2);
    });

    test('offline postponed needs the server and throws', () async {
      api.handlers['POST /tasks/a/status'] = (_) => throw const NetworkError();
      await expectLater(repo.setStatus(task, Postponed(DateTime.utc(2026, 11, 10, 9))), throwsA(isA<NetworkError>()));
      expect(await outbox.entries(), isEmpty);
    });

    test('a server 409 propagates (not queued)', () async {
      api.handlers['POST /tasks/a/status'] = (_) => throw const ConflictError(code: 'task.invalid_transition');
      await expectLater(repo.setStatus(task, const Completed()), throwsA(isA<ConflictError>()));
      expect(await outbox.entries(), isEmpty);
    });
  });

  test('loadFresh keeps an optimistic answer the server has not seen yet', () async {
    final planned = makeTask(id: 'a', startAt: DateTime.utc(2026, 11, 9, 10));
    await cache.replaceDay(makeDay(), [planned], clock.now);
    api.handlers['POST /tasks/a/status'] = (_) => throw const NetworkError();
    await repo.setStatus(planned, const Completed());

    final state = await repo.loadFresh(); // server still says planned

    final a = state.tasks.single;
    expect(a.status, TaskStatus.completed);
    expect(a.pendingStatus, 'completed');
  });

  test('once the outbox is empty the server state wins again', () async {
    final planned = makeTask(id: 'a');
    await cache.replaceDay(makeDay(), [planned.withOptimisticStatus(TaskStatus.completed)], clock.now);
    final state = await repo.loadFresh(); // nothing queued
    expect(state.tasks.single.status, TaskStatus.planned);
    expect(state.tasks.single.pendingStatus, isNull);
  });

  test('checkResponse sends done{finished_at} and not_yet{eta_min}', () async {
    api.handlers['POST /tasks/a/check-response'] = (_) => taskJson(id: 'a');
    await repo.checkResponse('a', response: CheckResponse.done, finishedAt: DateTime.utc(2026, 11, 9, 11));
    await repo.checkResponse('a', response: CheckResponse.notYet, etaMin: 30);
    final calls = api.callsTo('POST', '/tasks/a/check-response').toList();
    expect(calls[0].body, {'response': 'done', 'finished_at': '2026-11-09T11:00:00.000Z'});
    expect(calls[1].body, {'response': 'not_yet', 'eta_min': 30});
  });

  test('assess posts the draft', () async {
    api.handlers['POST /feasibility/assess'] = (_) => {
          'assessment_id': 'as',
          'verdict': 'go',
          'score': 0.9,
          'feasible_noul': 0.9,
          'recommended_action': 'proceed',
          'suggestion': 'ok',
        };
    final a = await repo.assess(TaskDraft(title: 'x', localDate: LocalDate.parse('2026-11-09'), isRecurring: false));
    expect(a.verdict, Verdict.go);
    expect((api.callsTo('POST', '/feasibility/assess').single.body as Map)['title'], 'x');
  });
}

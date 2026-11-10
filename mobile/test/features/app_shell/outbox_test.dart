import 'dart:convert';

import 'package:daily_assistant/features/app_shell/data/kv_store.dart';
import 'package:daily_assistant/features/app_shell/domain/app_error.dart';
import 'package:daily_assistant/features/app_shell/domain/outbox.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fakes.dart';

void main() {
  late InMemoryKeyValueStore store;
  late FakeApiClient api;
  late FakeClock clock;
  late OutboxService outbox;
  late List<ApiCall> sent;

  OutboxRequest req(String id, {String label = 'label'}) =>
      OutboxRequest(path: '/tasks/$id/check-response', body: {'response': 'done', 'id': id}, label: label);

  setUp(() {
    store = InMemoryKeyValueStore();
    api = FakeApiClient();
    clock = FakeClock(DateTime.utc(2026, 11, 9, 8));
    outbox = OutboxService(store: store, api: api, clock: clock);
    sent = api.calls;
  });

  tearDown(() => outbox.dispose());

  void ok(String id) => api.handlers['POST /tasks/$id/check-response'] = (_) => {'ok': true};

  test('flush sends entries FIFO, each with its stored idempotency key, and deletes them', () async {
    ok('a');
    ok('b');
    await outbox.enqueue(req('a'));
    await outbox.enqueue(req('b'));
    final keys = (await outbox.entries()).map((e) => e.idempotencyKey).toList();

    final result = await outbox.flush();

    expect(result.sent, 2);
    expect(sent.map((c) => c.path), ['/tasks/a/check-response', '/tasks/b/check-response']);
    expect(sent.map((c) => c.idempotencyKey), keys);
    expect(await outbox.entries(), isEmpty);
  });

  test('stops at the first network error and keeps the row (FIFO)', () async {
    api.handlers['POST /tasks/a/check-response'] = (_) => throw const NetworkError();
    ok('b');
    await outbox.enqueue(req('a'));
    await outbox.enqueue(req('b'));

    final result = await outbox.flush();

    expect(result.sent, 0);
    expect(result.remaining, 2);
    expect(sent.length, 1); // b was not attempted
    final entries = await outbox.entries();
    expect(entries.first.attempts, 1);
  });

  test('the same idempotency key is used on replay', () async {
    api.handlers['POST /tasks/a/check-response'] = (_) => throw const ServerWakingTimeout();
    await outbox.enqueue(req('a'));
    await outbox.flush();
    api.handlers['POST /tasks/a/check-response'] = (_) => {'ok': true};
    await outbox.flush();

    final keys = sent.map((c) => c.idempotencyKey).toList();
    expect(keys.length, 2);
    expect(keys[0], keys[1]);
  });

  test('409 deletes the row (superseded)', () async {
    api.handlers['POST /tasks/a/check-response'] = (_) => throw const ConflictError(code: 'task.invalid_transition');
    await outbox.enqueue(req('a'));
    final result = await outbox.flush();
    expect(result.sent, 0);
    expect(await outbox.entries(), isEmpty);
  });

  test('422 marks the row dead, continues with the next and surfaces the failure', () async {
    api.handlers['POST /tasks/a/check-response'] = (_) => throw const ValidationError(detail: 'bad');
    ok('b');
    await outbox.enqueue(req('a', label: "Mark 'A' completed"));
    await outbox.enqueue(req('b'));

    final emitted = <List<OutboxFailure>>[];
    final sub = outbox.failureStream.listen(emitted.add);
    final result = await outbox.flush();
    await settle();
    await sub.cancel();

    expect(result.dead, 1);
    expect(result.sent, 1);
    final failures = await outbox.failures();
    expect(failures.single.label, "Mark 'A' completed");
    expect(emitted, isNotEmpty);

    await outbox.dismiss(failures.single.id);
    expect(await outbox.failures(), isEmpty);
  });

  test('404 also marks the row dead', () async {
    api.handlers['POST /tasks/a/check-response'] = (_) => throw const NotFoundError();
    await outbox.enqueue(req('a'));
    await outbox.flush();
    expect((await outbox.entries()).single.state, 'dead');
  });

  test('401 stops and keeps the row for after re-login', () async {
    api.handlers['POST /tasks/a/check-response'] = (_) => throw const UnauthorizedError();
    ok('b');
    await outbox.enqueue(req('a'));
    await outbox.enqueue(req('b'));
    final result = await outbox.flush();
    expect(result.remaining, 2);
    expect(sent.length, 1);
  });

  test('a held lock prevents a concurrent flush (other isolate)', () async {
    ok('a');
    await outbox.enqueue(req('a'));
    await store.set(KvKeys.outboxLock, clock.now.add(const Duration(seconds: 30)).toIso8601String());

    final result = await outbox.flush();

    expect(result.skipped, isTrue);
    expect(sent, isEmpty);
  });

  test('an expired lock is taken over', () async {
    ok('a');
    await outbox.enqueue(req('a'));
    await store.set(KvKeys.outboxLock, clock.now.subtract(const Duration(seconds: 1)).toIso8601String());
    final result = await outbox.flush();
    expect(result.sent, 1);
  });

  test('the lock is released after a flush', () async {
    ok('a');
    await outbox.enqueue(req('a'));
    await outbox.flush();
    expect(await store.get(KvKeys.outboxLock), isNull);
  });

  test('flushes in one isolate are single-flight', () async {
    ok('a');
    await outbox.enqueue(req('a'));
    final results = await Future.wait([outbox.flush(), outbox.flush()]);
    expect(results.where((r) => r.skipped).length, 1);
    expect(sent.length, 1);
  });

  test('bodies are stored as JSON and replayed as objects', () async {
    ok('a');
    await outbox.enqueue(req('a'));
    await outbox.flush();
    expect(jsonEncode(sent.single.body), jsonEncode({'response': 'done', 'id': 'a'}));
  });
}

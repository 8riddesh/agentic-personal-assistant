import 'package:daily_assistant/features/app_shell/data/kv_store.dart';
import 'package:daily_assistant/features/app_shell/domain/local_date.dart';
import 'package:daily_assistant/features/tasks/data/day_cache.dart';
import 'package:daily_assistant/features/tasks/domain/entities.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fakes.dart';

void main() {
  late InMemoryKeyValueStore store;
  late DayCache cache;
  final fetched = DateTime.utc(2026, 11, 9, 8);

  setUp(() {
    store = InMemoryKeyValueStore();
    cache = DayCache(store);
  });

  Day day(String iso) => makeDay(localDate: LocalDate.parse(iso));

  test('replaceDay then readDay returns the day and its tasks', () async {
    await cache.replaceDay(day('2026-11-09'), [makeTask(id: 'a'), makeTask(id: 'b')], fetched);
    final cached = await cache.readDay(LocalDate.parse('2026-11-09'));
    expect(cached?.tasks.map((t) => t.id), ['a', 'b']);
    expect(cached?.fetchedAt, fetched);
  });

  test('replaceDay replaces the same date atomically (no leftovers)', () async {
    await cache.replaceDay(day('2026-11-09'), [makeTask(id: 'a'), makeTask(id: 'b')], fetched);
    await cache.replaceDay(day('2026-11-09'), [makeTask(id: 'c')], fetched);
    expect((await cache.readDay(LocalDate.parse('2026-11-09')))?.tasks.map((t) => t.id), ['c']);
  });

  test('dates older than yesterday are pruned, yesterday is kept', () async {
    await cache.replaceDay(day('2026-11-07'), [makeTask(id: 'old')], fetched);
    await cache.replaceDay(day('2026-11-08'), [makeTask(id: 'yesterday')], fetched);
    await cache.replaceDay(day('2026-11-09'), [makeTask(id: 'today')], fetched);
    expect(await cache.readDay(LocalDate.parse('2026-11-07')), isNull);
    expect(await cache.readDay(LocalDate.parse('2026-11-08')), isNotNull);
    expect(await cache.readDay(LocalDate.parse('2026-11-09')), isNotNull);
  });

  test('readLatest returns the most recent cached date', () async {
    await cache.replaceDay(day('2026-11-08'), [], fetched);
    await cache.replaceDay(day('2026-11-09'), [], fetched);
    expect((await cache.readLatest())?.day.localDate, LocalDate.parse('2026-11-09'));
  });

  test('readLatest on an empty cache is null', () async {
    expect(await cache.readLatest(), isNull);
  });

  test('upsertTask replaces by id or appends', () async {
    await cache.replaceDay(day('2026-11-09'), [makeTask(id: 'a', title: 'Old')], fetched);
    await cache.upsertTask(makeTask(id: 'a', title: 'New'));
    await cache.upsertTask(makeTask(id: 'b'));
    final tasks = (await cache.readDay(LocalDate.parse('2026-11-09')))!.tasks;
    expect(tasks.map((t) => t.id), ['a', 'b']);
    expect(tasks.first.title, 'New');
  });

  test('upsertTask for an uncached date is a no-op', () async {
    await cache.upsertTask(makeTask(id: 'x', localDate: LocalDate.parse('2026-12-01')));
    expect(await cache.readLatest(), isNull);
  });

  test('pendingStatuses lists optimistic answers', () async {
    await cache.replaceDay(
      day('2026-11-09'),
      [makeTask(id: 'a', status: TaskStatus.completed, pendingStatus: 'completed'), makeTask(id: 'b')],
      fetched,
    );
    expect(await cache.pendingStatuses(), {'a': 'completed'});
  });

  test('clear removes everything (logout)', () async {
    await cache.replaceDay(day('2026-11-09'), [makeTask()], fetched);
    await cache.clear();
    expect(await cache.readLatest(), isNull);
  });

  test('a corrupt cache document is a cache miss, not a crash', () async {
    await store.set(KvKeys.dayCache, '{not json');
    expect(await cache.readLatest(), isNull);
    await cache.replaceDay(day('2026-11-09'), [makeTask()], fetched);
    expect(await cache.readLatest(), isNotNull);
  });
}

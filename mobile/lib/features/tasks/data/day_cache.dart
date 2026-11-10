import 'dart:convert';

import '../../app_shell/data/kv_store.dart';
import '../../app_shell/domain/local_date.dart';
import '../domain/entities.dart';
import 'dto/dtos.dart';

class CachedDay {
  const CachedDay({required this.day, required this.tasks, required this.fetchedAt});

  final Day day;
  final List<Task> tasks;
  final DateTime fetchedAt;
}

/// Cache of the open day (and at most the previous one) for offline start-up and optimistic status answers.
///
/// Stored as one JSON document so [replaceDay] is atomic. Deviation from the spec's drift tables
/// `cached_days`/`cached_tasks` (see tasks/spec.md status): the content and rules are identical.
class DayCache {
  DayCache(this._store);

  final KeyValueStore _store;

  Future<Map<String, Map<String, dynamic>>> _load() async {
    final raw = await _store.get(KvKeys.dayCache);
    if (raw == null) return {};
    try {
      return (jsonDecode(raw) as Map).map((k, v) => MapEntry(k as String, (v as Map).cast<String, dynamic>()));
    } on FormatException {
      return {}; // corrupt cache is just a cache miss
    }
  }

  Future<void> _save(Map<String, Map<String, dynamic>> data) => _store.set(KvKeys.dayCache, jsonEncode(data));

  CachedDay _decode(Map<String, dynamic> e) => CachedDay(
        day: dayFromJson(e['day']),
        tasks: (e['tasks'] as List).map(taskFromJson).toList(),
        fetchedAt: DateTime.parse(e['fetched_at'] as String).toUtc(),
      );

  /// Stores [day] + [tasks] and drops dates older than yesterday (relative to [day]).
  Future<void> replaceDay(Day day, List<Task> tasks, DateTime fetchedAt) async {
    final data = await _load();
    final oldest = day.localDate.addDays(-1);
    data.removeWhere((iso, _) => LocalDate.parse(iso).isBefore(oldest));
    data[day.localDate.toIso()] = {
      'day': dayToJson(day),
      'tasks': tasks.map(taskToJson).toList(),
      'fetched_at': fetchedAt.toUtc().toIso8601String(),
    };
    await _save(data);
  }

  Future<CachedDay?> readDay(LocalDate date) async {
    final entry = (await _load())[date.toIso()];
    if (entry == null) return null;
    try {
      return _decode(entry);
    } on FormatException {
      return null;
    }
  }

  /// The most recent cached date (the last open day).
  Future<CachedDay?> readLatest() async {
    final data = await _load();
    if (data.isEmpty) return null;
    final latest = data.keys.map(LocalDate.parse).reduce((a, b) => a.isAfter(b) ? a : b);
    return readDay(latest);
  }

  /// Insert or replace one task in its day (no-op when that day is not cached).
  Future<void> upsertTask(Task task) async {
    final data = await _load();
    final entry = data[task.localDate.toIso()];
    if (entry == null) return;
    final tasks = (entry['tasks'] as List).map(taskFromJson).toList();
    final index = tasks.indexWhere((t) => t.id == task.id);
    if (index >= 0) {
      tasks[index] = task;
    } else {
      tasks.add(task);
    }
    entry['tasks'] = tasks.map(taskToJson).toList();
    await _save(data);
  }

  /// Ids of tasks carrying an optimistic status (and that status), across cached days.
  Future<Map<String, String>> pendingStatuses() async {
    final result = <String, String>{};
    for (final entry in (await _load()).values) {
      for (final t in (entry['tasks'] as List).map(taskFromJson)) {
        if (t.pendingStatus != null) result[t.id] = t.pendingStatus!;
      }
    }
    return result;
  }

  Future<void> clear() => _store.remove(KvKeys.dayCache);
}

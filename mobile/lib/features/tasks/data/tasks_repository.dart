import 'package:uuid/uuid.dart';

import '../../app_shell/domain/app_error.dart';
import '../../app_shell/domain/clock.dart';
import '../../app_shell/domain/local_date.dart';
import '../../app_shell/domain/outbox.dart';
import '../domain/entities.dart';
import '../domain/status_change.dart';
import 'day_cache.dart';
import 'tasks_api.dart';

/// API + cache + offline outbox fallback for status answers (tasks spec §5, §8).
class TasksRepository {
  TasksRepository({
    required TasksApi tasks,
    required DayApi days,
    required FeasibilityApi feasibility,
    required DayCache cache,
    required OutboxService outbox,
    required Clock clock,
    Uuid? uuid,
  })  : _tasks = tasks,
        _days = days,
        _feasibility = feasibility,
        _cache = cache,
        _outbox = outbox,
        _clock = clock,
        _uuid = uuid ?? const Uuid();

  final TasksApi _tasks;
  final DayApi _days;
  final FeasibilityApi _feasibility;
  final DayCache _cache;
  final OutboxService _outbox;
  final Clock _clock;
  final Uuid _uuid;

  Future<Day> currentDay() => _days.current();

  Future<Day> day(LocalDate date) => _days.day(date);

  Future<List<Task>> tasksFor(LocalDate date) => _tasks.list(date);

  /// Spec §8.9: `GET /days/current` -> `GET /tasks?date=` -> cache, keeping optimistic offline answers that the
  /// server has not seen yet.
  Future<TodayState> loadFresh() async {
    final day = await _days.current();
    var tasks = await _tasks.list(day.localDate);
    final now = _clock.nowUtc();

    if (await _outbox.pendingCount() > 0) {
      final pending = await _cache.pendingStatuses();
      tasks = [
        for (final t in tasks)
          if (pending.containsKey(t.id) && t.status == TaskStatus.planned)
            t.withOptimisticStatus(TaskStatus.parse(pending[t.id]!))
          else
            t,
      ];
    }
    await _cache.replaceDay(day, tasks, now);
    return TodayState(day: day, tasks: tasks, fetchedAt: now, fromCache: false);
  }

  Future<TodayState?> readCached() async {
    final cached = await _cache.readLatest();
    if (cached == null) return null;
    return TodayState(day: cached.day, tasks: cached.tasks, fetchedAt: cached.fetchedAt, fromCache: true);
  }

  Future<void> cacheTask(Task task) => _cache.upsertTask(task);

  Future<void> clearCache() => _cache.clear();

  Future<Assessment> assess(TaskDraft draft) => _feasibility.assess(draft.toJson());

  Future<Task> create(
    TaskDraft draft, {
    String? assessmentId,
    required bool overridden,
    required CreatedVia via,
    String? clientRequestId,
  }) {
    final body = <String, Object?>{
      ...draft.toJson(),
      if (assessmentId != null) 'assessment_id': assessmentId,
      'overridden': overridden,
      'created_via': via == CreatedVia.chat ? 'chat' : 'form',
      'client_request_id': clientRequestId ?? _uuid.v4(),
    };
    return _tasks.create(body);
  }

  Future<Task> patch(String id, Map<String, Object?> patch) => _tasks.patch(id, patch);

  /// Online first. When the network/cold start fails, Completed/Cancelled/CantDo are queued in the outbox and shown
  /// optimistically; Postponed needs the server (it creates the new task), so its error propagates.
  Future<Task> setStatus(Task task, StatusChange change, {String source = 'app'}) async {
    try {
      return await _tasks.setStatus(task.id, change.toJson(source: source));
    } on NetworkError {
      return _queueOffline(task, change, source);
    } on ServerWakingTimeout {
      return _queueOffline(task, change, source);
    }
  }

  Future<Task> _queueOffline(Task task, StatusChange change, String source) async {
    if (change is Postponed) throw const NetworkError();
    // A completion time is fixed now so the replay records when the user answered, not when it syncs.
    final StatusChange fixed = change is Completed ? Completed(finishedAt: change.finishedAt ?? _clock.nowUtc()) : change;
    final verb = switch (fixed) {
      Completed() => 'completed',
      Cancelled() => 'cancelled',
      CantDo() => "marked can't do",
      Postponed() => 'postponed',
    };
    await _outbox.enqueue(
      OutboxRequest(
        path: '/tasks/${task.id}/status',
        body: fixed.toJson(source: source),
        label: "Mark '${task.title}' $verb",
      ),
    );
    final optimistic = task.withOptimisticStatus(
      fixed.target,
      reason: switch (fixed) {
        CantDo(:final reason) => reason.trim(),
        Cancelled(:final reason) => reason?.trim(),
        _ => null,
      },
      actualEndAt: fixed is Completed ? fixed.finishedAt : null,
    );
    await _cache.upsertTask(optimistic);
    return optimistic;
  }

  Future<Task> checkResponse(String id, {required CheckResponse response, DateTime? finishedAt, int? etaMin}) {
    final body = <String, Object?>{
      'response': response.json,
      if (response == CheckResponse.done) 'finished_at': (finishedAt ?? _clock.nowUtc()).toUtc().toIso8601String(),
      if (response == CheckResponse.notYet && etaMin != null) 'eta_min': etaMin,
    };
    return _tasks.checkResponse(id, body);
  }
}

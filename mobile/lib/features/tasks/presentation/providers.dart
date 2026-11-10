import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app_shell/domain/app_error.dart';
import '../../app_shell/domain/auth_state.dart';
import '../../app_shell/domain/local_date.dart';
import '../../app_shell/presentation/providers.dart';
import '../data/day_cache.dart';
import '../data/tasks_api.dart';
import '../data/tasks_repository.dart';
import '../data/templates_repository.dart';
import '../domain/entities.dart';
import '../domain/status_change.dart';

final dayCacheProvider = Provider<DayCache>((ref) => DayCache(ref.watch(kvStoreProvider)));

final tasksApiProvider = Provider<TasksApi>((ref) => TasksApi(ref.watch(apiClientProvider)));
final dayApiProvider = Provider<DayApi>((ref) => DayApi(ref.watch(apiClientProvider)));
final feasibilityApiProvider = Provider<FeasibilityApi>((ref) => FeasibilityApi(ref.watch(apiClientProvider)));
final templatesApiProvider = Provider<TemplatesApi>((ref) => TemplatesApi(ref.watch(apiClientProvider)));

final tasksRepositoryProvider = Provider<TasksRepository>(
  (ref) => TasksRepository(
    tasks: ref.watch(tasksApiProvider),
    days: ref.watch(dayApiProvider),
    feasibility: ref.watch(feasibilityApiProvider),
    cache: ref.watch(dayCacheProvider),
    outbox: ref.watch(outboxServiceProvider),
    clock: ref.watch(clockProvider),
  ),
);

final templatesRepositoryProvider = Provider<TemplatesRepository>(
  (ref) => TemplatesRepository(ref.watch(templatesApiProvider)),
);

final categoriesProvider = Provider<List<String>>((_) => const ['Work', 'Learning', 'Health', 'Personal', 'Chores']);

/// The feasibility check (`POST /feasibility/assess`, verdict card) arrives with backend M2. While `false`,
/// "Add task" saves directly with `assessment_id: null` (the recurring-vs-one-time question is still mandatory).
final feasibilityEnabledProvider = Provider<bool>((_) => false);

/// Cards shown at the top of Today by other features (notification permission card), composed in `composition.dart`.
final todayHeaderSectionsProvider = Provider<List<Widget>>((_) => const []);

/// Open day + its tasks (spec §5). Cache first, then the server; every mutation flows through here so that the
/// notifications feature reconciles from a single source.
class CurrentDayController extends AsyncNotifier<TodayState> {
  @override
  Future<TodayState> build() async {
    // Wait for the session to be restored (it is still loading right after app start) instead of failing early.
    final auth = await ref.watch(authControllerProvider.future);
    if (auth is! Authenticated) throw const UnauthorizedError();

    final repo = ref.read(tasksRepositoryProvider);
    final cached = await repo.readCached();
    if (cached != null) {
      // Show the cache now; the server answer replaces it (a later event-loop turn, after this state is set).
      Future<void>(refresh);
      return cached;
    }
    return repo.loadFresh();
  }

  /// `GET /days/current` -> `GET /tasks?date=`. On failure the old content stays, marked `fromCache`.
  Future<void> refresh() async {
    final previous = state.valueOrNull;
    if (previous != null) state = const AsyncLoading<TodayState>().copyWithPrevious(state);
    final repo = ref.read(tasksRepositoryProvider);
    try {
      var fresh = await repo.loadFresh();
      if (previous != null && previous.day.localDate != fresh.day.localDate) {
        fresh = fresh.copyWith(autoClosedReportId: await _autoClosedReport(previous.day.localDate));
      }
      state = AsyncData(fresh);
    } on AppError catch (e, st) {
      state = previous != null ? AsyncData(previous.copyWith(fromCache: true)) : AsyncError(e, st);
    }
  }

  /// After a date change: was yesterday closed automatically, and is there a report to show?
  Future<String?> _autoClosedReport(LocalDate previousDate) async {
    try {
      final day = await ref.read(tasksRepositoryProvider).day(previousDate);
      if (day.closeMode == 'auto_midnight') return day.dailyReportId;
    } on AppError {
      // purely informational
    }
    return null;
  }

  /// Replace (or insert) a task in the open day and in the cache.
  Future<void> applyTask(Task task) async {
    final current = state.valueOrNull;
    if (current == null) return;
    final tasks = [...current.tasks];
    final index = tasks.indexWhere((t) => t.id == task.id);
    if (index >= 0) {
      tasks[index] = task;
    } else if (task.localDate == current.day.localDate) {
      tasks.add(task);
    }
    state = AsyncData(current.copyWith(tasks: tasks));
    await ref.read(tasksRepositoryProvider).cacheTask(task);
  }

  /// Used by reports after EOD close.
  Future<void> markDayClosed(Day day) async {
    final current = state.valueOrNull;
    if (current == null) return;
    state = AsyncData(current.copyWith(day: day));
  }

  // -- mutations: apply the returned task, then refresh in the background (spec §8.6) -----------------------

  Future<Task> createTask(
    TaskDraft draft, {
    String? assessmentId,
    required bool overridden,
    required CreatedVia via,
    String? clientRequestId,
  }) async {
    final task = await ref.read(tasksRepositoryProvider).create(
          draft,
          assessmentId: assessmentId,
          overridden: overridden,
          via: via,
          clientRequestId: clientRequestId,
        );
    await applyTask(task);
    unawaited(refresh());
    return task;
  }

  Future<Task> editTask(String id, Map<String, Object?> patch) async {
    final task = await ref.read(tasksRepositoryProvider).patch(id, patch);
    await applyTask(task);
    unawaited(refresh());
    return task;
  }

  Future<Task> changeStatus(Task task, StatusChange change, {String source = 'app'}) async {
    try {
      final updated = await ref.read(tasksRepositoryProvider).setStatus(task, change, source: source);
      await applyTask(updated);
      unawaited(refresh());
      return updated;
    } on ConflictError {
      unawaited(refresh()); // already terminal elsewhere: pick up the server state
      rethrow;
    } on NotFoundError {
      unawaited(refresh());
      rethrow;
    }
  }

  Future<Task> respondToCheck(String id, {required CheckResponse response, DateTime? finishedAt, int? etaMin}) async {
    final updated = await ref
        .read(tasksRepositoryProvider)
        .checkResponse(id, response: response, finishedAt: finishedAt, etaMin: etaMin);
    await applyTask(updated);
    unawaited(refresh());
    return updated;
  }
}

final currentDayControllerProvider = AsyncNotifierProvider<CurrentDayController, TodayState>(
  CurrentDayController.new,
);

/// Order 30: refresh the open day on launch/resume.
final class CurrentDayLifecycleHook implements LifecycleHook {
  const CurrentDayLifecycleHook();

  @override
  int get order => 30;

  @override
  Future<void> onLaunchOrResume(Ref ref) => ref.read(currentDayControllerProvider.notifier).refresh();
}

class TemplatesController extends AsyncNotifier<List<Template>> {
  @override
  Future<List<Template>> build() async {
    final auth = ref.watch(authControllerProvider).valueOrNull;
    if (auth is! Authenticated) throw const UnauthorizedError();
    return ref.read(templatesRepositoryProvider).list();
  }

  void _refreshToday() => unawaited(ref.read(currentDayControllerProvider.notifier).refresh());

  /// Optimistic toggle with rollback on error (rethrows so the UI can show a message).
  Future<void> toggleActive(String id, bool active) async {
    final previous = state.valueOrNull ?? const <Template>[];
    state = AsyncData([for (final t in previous) t.id == id ? t.copyWith(active: active) : t]);
    try {
      final updated = await ref.read(templatesRepositoryProvider).setActive(id, active);
      state = AsyncData([for (final t in state.valueOrNull ?? previous) t.id == id ? updated : t]);
      _refreshToday();
    } on AppError {
      state = AsyncData(previous);
      rethrow;
    }
  }

  Future<void> save(
    String id, {
    String? title,
    String? notes,
    String? category,
    LocalTime? startLocal,
    bool clearStart = false,
    int? defaultEstimateMin,
    Recurrence? recurrence,
  }) async {
    final updated = await ref.read(templatesRepositoryProvider).update(
          id,
          title: title,
          notes: notes,
          category: category,
          startLocal: startLocal,
          clearStart: clearStart,
          defaultEstimateMin: defaultEstimateMin,
          recurrence: recurrence,
        );
    state = AsyncData([for (final t in state.valueOrNull ?? const <Template>[]) t.id == id ? updated : t]);
    _refreshToday();
  }

  Future<void> delete(String id) async {
    await ref.read(templatesRepositoryProvider).delete(id);
    state = AsyncData([for (final t in state.valueOrNull ?? const <Template>[]) if (t.id != id) t]);
    _refreshToday();
  }
}

final templatesControllerProvider = AsyncNotifierProvider<TemplatesController, List<Template>>(
  TemplatesController.new,
);

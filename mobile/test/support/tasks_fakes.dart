import 'package:daily_assistant/features/app_shell/domain/auth_state.dart';
import 'package:daily_assistant/features/app_shell/presentation/providers.dart';
import 'package:daily_assistant/features/tasks/domain/entities.dart';
import 'package:daily_assistant/features/tasks/domain/status_change.dart';
import 'package:daily_assistant/features/tasks/presentation/providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'fakes.dart';

class CreateCall {
  CreateCall(this.draft, this.assessmentId, this.overridden, this.via);

  final TaskDraft draft;
  final String? assessmentId;
  final bool overridden;
  final CreatedVia via;
}

/// Today controller with scripted state that records mutations (widget tests).
class FakeDay extends CurrentDayController {
  FakeDay(this.builder);

  final Future<TodayState> Function() builder;
  int refreshCalls = 0;
  final List<StatusChange> changes = [];
  final List<CreateCall> creates = [];
  final List<Map<String, Object?>> edits = [];

  @override
  Future<TodayState> build() => builder();

  @override
  Future<void> refresh() async {
    refreshCalls++;
  }

  @override
  Future<Task> createTask(
    TaskDraft draft, {
    String? assessmentId,
    required bool overridden,
    required CreatedVia via,
    String? clientRequestId,
  }) async {
    creates.add(CreateCall(draft, assessmentId, overridden, via));
    return makeTask(id: 'new', title: draft.title);
  }

  @override
  Future<Task> changeStatus(Task task, StatusChange change, {String source = 'app'}) async {
    changes.add(change);
    return task.withOptimisticStatus(change.target);
  }

  @override
  Future<Task> editTask(String id, Map<String, Object?> patch) async {
    edits.add(patch);
    return makeTask(id: id);
  }
}

Override authenticated() => authControllerProvider.overrideWith(
      () => FakeAuthController(Authenticated(expiresAt: DateTime.utc(2026, 12, 9), email: 'me@example.com')),
    );

Override dayOverride(FakeDay fake) => currentDayControllerProvider.overrideWith(() => fake);

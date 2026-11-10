import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../../app_shell/domain/app_error.dart';
import '../../domain/entities.dart';
import '../../domain/override_rule.dart';
import '../providers.dart';

/// Where the add-task flow is (tasks spec §7.3).
enum AddPhase { editing, assessing, verdict, unavailable, saving }

class AddTaskState {
  const AddTaskState({
    this.phase = AddPhase.editing,
    this.draft,
    this.assessment,
    this.saveError,
    this.fieldErrors = const {},
    this.created,
  });

  final AddPhase phase;
  final TaskDraft? draft;
  final Assessment? assessment;

  /// "Couldn't save — Retry" while the card stays open.
  final String? saveError;
  final Map<String, String> fieldErrors;

  /// Set once the task exists; the screen pops with it.
  final Task? created;

  AddTaskState copyWith({
    AddPhase? phase,
    TaskDraft? draft,
    Assessment? assessment,
    bool clearAssessment = false,
    String? saveError,
    bool clearSaveError = false,
    Map<String, String>? fieldErrors,
    Task? created,
  }) =>
      AddTaskState(
        phase: phase ?? this.phase,
        draft: draft ?? this.draft,
        assessment: clearAssessment ? null : (assessment ?? this.assessment),
        saveError: clearSaveError ? null : (saveError ?? this.saveError),
        fieldErrors: fieldErrors ?? this.fieldErrors,
        created: created ?? this.created,
      );
}

/// assess -> verdict card -> create, with "Add without check" when the assessment is unavailable (P7/P10).
class AddTaskController extends AutoDisposeNotifier<AddTaskState> {
  CreatedVia _via = CreatedVia.form;
  String? _clientRequestId;
  String? _fingerprint;

  @override
  AddTaskState build() => const AddTaskState();

  void configure({required CreatedVia via}) => _via = via;

  /// "Check & add": assess the (already validated) draft. With the feasibility check disabled it saves directly.
  Future<void> submit(TaskDraft draft) async {
    // A new fingerprint = a new logical task = a new idempotency key.
    if (_fingerprint != draft.fingerprint) {
      _fingerprint = draft.fingerprint;
      _clientRequestId = const Uuid().v4();
    }
    state = AddTaskState(phase: AddPhase.assessing, draft: draft);

    if (!ref.read(feasibilityEnabledProvider)) {
      await _create(draft, assessmentId: null, overridden: false);
      return;
    }
    try {
      final assessment = await ref.read(tasksRepositoryProvider).assess(draft);
      state = AddTaskState(phase: AddPhase.verdict, draft: draft, assessment: assessment);
    } on ValidationError catch (e) {
      state = AddTaskState(fieldErrors: e.fieldErrors, draft: draft);
    } on AppError {
      state = AddTaskState(phase: AddPhase.unavailable, draft: draft);
    }
  }

  /// "Add" / "Add anyway".
  Future<void> confirmVerdict() {
    final assessment = state.assessment;
    final draft = state.draft;
    if (assessment == null || draft == null) return Future.value();
    return _create(draft, assessmentId: assessment.assessmentId, overridden: isOverride(assessment.verdict));
  }

  /// "Add without check" after the assessment failed.
  Future<void> addWithoutCheck() {
    final draft = state.draft;
    if (draft == null) return Future.value();
    return _create(draft, assessmentId: null, overridden: false);
  }

  /// "Retry" on the unavailable card.
  Future<void> retryAssessment() {
    final draft = state.draft;
    if (draft == null) return Future.value();
    return submit(draft);
  }

  /// "Adjust": back to the form, keeping every value; the old assessment is discarded (needs re-assessment).
  void adjust() {
    state = AddTaskState(draft: state.draft);
  }

  Future<void> _create(TaskDraft draft, {required String? assessmentId, required bool overridden}) async {
    final previous = state;
    state = previous.copyWith(phase: AddPhase.saving, clearSaveError: true);
    try {
      final task = await ref.read(currentDayControllerProvider.notifier).createTask(
            draft,
            assessmentId: assessmentId,
            overridden: overridden,
            via: _via,
            clientRequestId: _clientRequestId,
          );
      state = state.copyWith(created: task);
    } on ValidationError catch (e) {
      state = AddTaskState(draft: draft, fieldErrors: e.fieldErrors);
    } on AppError catch (e) {
      // keep the card (or the form) and let the user retry; creation is online-only
      final back = previous.assessment != null
          ? AddPhase.verdict
          : (ref.read(feasibilityEnabledProvider) ? AddPhase.unavailable : AddPhase.editing);
      state = AddTaskState(
        phase: back,
        draft: draft,
        assessment: previous.assessment,
        saveError: e is NetworkError || e is ServerWakingTimeout ? "Couldn't save — Retry" : e.userMessage,
      );
    }
  }
}

final addTaskControllerProvider = NotifierProvider.autoDispose<AddTaskController, AddTaskState>(
  AddTaskController.new,
);

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app_shell/domain/format.dart';
import '../../../app_shell/domain/local_date.dart';
import '../../../app_shell/presentation/providers.dart';
import '../../domain/entities.dart';
import '../../domain/start_at_resolver.dart';
import '../../domain/task_draft_validator.dart';
import '../providers.dart';
import 'add_task_controller.dart';
import 'recurrence_question.dart';
import 'verdict_card.dart';

/// Route payload of `/today/new`.
class AddTaskArgs {
  const AddTaskArgs({this.prefill, this.via = CreatedVia.form});

  final TaskDraft? prefill;
  final CreatedVia via;
}

/// Entry point shared with chat: pushes `/today/new` and resolves with the created task (or `null`).
abstract final class AddTaskFlow {
  static Future<Task?> start(BuildContext context, {TaskDraft? prefill, CreatedVia via = CreatedVia.form}) =>
      context.push<Task>('/today/new', extra: AddTaskArgs(prefill: prefill, via: via));
}

class AddTaskScreen extends ConsumerStatefulWidget {
  const AddTaskScreen({super.key, this.prefill, this.via = CreatedVia.form});

  final TaskDraft? prefill;
  final CreatedVia via;

  @override
  ConsumerState<AddTaskScreen> createState() => _AddTaskScreenState();
}

class _AddTaskScreenState extends ConsumerState<AddTaskScreen> {
  final _title = TextEditingController();
  final _notes = TextEditingController();
  final _estimate = TextEditingController();
  final _category = TextEditingController(text: 'Personal');
  final _titleFocus = FocusNode();
  final _estimateFocus = FocusNode();

  LocalDate? _date;
  LocalTime? _time;
  bool _anytime = true;
  bool? _isRecurring;
  Recurrence? _recurrence;
  Map<String, String> _errors = const {};
  bool _sheetOpen = false;

  @override
  void initState() {
    super.initState();
    final p = widget.prefill;
    if (p != null) {
      _title.text = p.title;
      _notes.text = p.notes ?? '';
      _category.text = p.category;
      _date = p.localDate;
      if (p.estimateMin != null) _estimate.text = '${p.estimateMin}';
      _isRecurring = p.isRecurring;
      _recurrence = p.recurrence;
    }
    // Providers must not be modified during build: configure after the first frame.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) ref.read(addTaskControllerProvider.notifier).configure(via: widget.via);
    });
  }

  @override
  void dispose() {
    _title.dispose();
    _notes.dispose();
    _estimate.dispose();
    _category.dispose();
    _titleFocus.dispose();
    _estimateFocus.dispose();
    super.dispose();
  }

  LocalDate _openDay() {
    final fromState = ref.read(currentDayControllerProvider).valueOrNull?.day.localDate;
    return fromState ?? LocalDate.fromTz(ref.read(clockProvider).nowUtc(), ref.read(appLocationProvider));
  }

  TaskDraft _buildDraft() {
    final date = _date ?? _openDay();
    final loc = ref.read(appLocationProvider);
    final notes = _notes.text.trim();
    return TaskDraft(
      title: _title.text,
      notes: notes.isEmpty ? null : notes,
      category: _category.text,
      localDate: date,
      startAt: _anytime ? null : resolveStartAt(date, _time ?? const LocalTime(9, 0), loc),
      estimateMin: int.tryParse(_estimate.text.trim()),
      isRecurring: _isRecurring,
      recurrence: _isRecurring == true ? _recurrence : null,
    );
  }

  Future<void> _submit() async {
    final draft = _buildDraft();
    final errors = validateTaskDraft(draft, openDay: _openDay());
    setState(() => _errors = errors);
    if (errors.isNotEmpty) return;
    await ref.read(addTaskControllerProvider.notifier).submit(draft);
  }

  Future<void> _pickDate() async {
    final open = _openDay();
    final initial = _date ?? open;
    final picked = await showDatePicker(
      context: context,
      initialDate: DateTime(initial.year, initial.month, initial.day),
      firstDate: DateTime(open.year, open.month, open.day),
      lastDate: DateTime(open.year, open.month, open.day).add(const Duration(days: maxDaysAhead)),
    );
    if (picked != null) setState(() => _date = LocalDate.fromDateTime(picked));
  }

  Future<void> _pickTime() async {
    final initial = _time ?? const LocalTime(9, 0);
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: initial.hour, minute: initial.minute),
    );
    if (picked != null) setState(() => _time = LocalTime(picked.hour, picked.minute));
  }

  void _onControllerChange(AddTaskState? previous, AddTaskState next) {
    final created = next.created;
    if (created != null && previous?.created == null) {
      if (_sheetOpen) {
        _sheetOpen = false;
        Navigator.of(context).pop(); // close the verdict sheet first
      }
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(const SnackBar(content: Text('Added')));
      Navigator.of(context).pop(created);
      return;
    }

    final needsSheet = next.phase == AddPhase.verdict || next.phase == AddPhase.unavailable || next.phase == AddPhase.saving;
    final hasCard = next.assessment != null || next.phase == AddPhase.unavailable || next.phase == AddPhase.verdict;
    if (needsSheet && hasCard && !_sheetOpen) {
      _openSheet();
    } else if (next.phase == AddPhase.editing && _sheetOpen) {
      _sheetOpen = false;
      Navigator.of(context).pop();
    }
    if (next.phase == AddPhase.editing && previous != null && previous.phase != AddPhase.editing) {
      // back from "Adjust" (or a server-side validation error): surface field errors, focus what was recommended
      setState(() => _errors = {..._errors, ...next.fieldErrors});
      _focusForAdjust(previous.assessment?.recommendedAction);
    }
  }

  void _focusForAdjust(RecommendedAction? action) {
    switch (action) {
      case RecommendedAction.reschedule:
        setState(() => _anytime = false);
      case RecommendedAction.split || RecommendedAction.shorten:
        _estimateFocus.requestFocus();
      case RecommendedAction.drop:
        _titleFocus.requestFocus();
      case RecommendedAction.proceed || null:
        break;
    }
  }

  void _openSheet() {
    _sheetOpen = true;
    showModalBottomSheet<void>(
      context: context,
      isDismissible: false,
      enableDrag: false,
      builder: (_) => const _FeasibilitySheet(),
    ).whenComplete(() => _sheetOpen = false);
  }

  String? _errorFor(String field, [String? alt]) => _errors[field] ?? (alt == null ? null : _errors[alt]);

  @override
  Widget build(BuildContext context) {
    ref.listen<AddTaskState>(addTaskControllerProvider, _onControllerChange);
    final state = ref.watch(addTaskControllerProvider);
    final feasibility = ref.watch(feasibilityEnabledProvider);
    final categories = ref.watch(categoriesProvider);
    final date = _date ?? _openDay();
    final busy = state.phase == AddPhase.assessing || state.phase == AddPhase.saving;
    final recurrenceAnswered = _isRecurring != null;

    return Scaffold(
      appBar: AppBar(title: const Text('New task')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            key: const Key('field-title'),
            controller: _title,
            focusNode: _titleFocus,
            textCapitalization: TextCapitalization.sentences,
            decoration: InputDecoration(labelText: 'Title', errorText: _errorFor(DraftField.title)),
          ),
          const SizedBox(height: 12),
          TextField(
            key: const Key('field-category'),
            controller: _category,
            decoration: InputDecoration(labelText: 'Category', errorText: _errorFor(DraftField.category)),
          ),
          Wrap(
            spacing: 6,
            children: [
              for (final c in categories)
                ActionChip(
                  key: Key('category-chip-$c'),
                  label: Text(c),
                  onPressed: () => setState(() => _category.text = c),
                ),
            ],
          ),
          const SizedBox(height: 12),
          ListTile(
            key: const Key('field-date'),
            contentPadding: EdgeInsets.zero,
            title: Text('Date: ${formatDayLabel(date)}'),
            subtitle: _errorFor(DraftField.date, 'start_at') == null ? null : Text(_errorFor(DraftField.date, 'start_at')!),
            trailing: const Icon(Icons.calendar_today),
            onTap: _pickDate,
          ),
          SwitchListTile(
            key: const Key('field-anytime'),
            contentPadding: EdgeInsets.zero,
            title: const Text('Anytime'),
            subtitle: const Text('Anytime tasks get no reminders or completion check'),
            value: _anytime,
            onChanged: (v) => setState(() => _anytime = v),
          ),
          if (!_anytime)
            ListTile(
              key: const Key('field-time'),
              contentPadding: EdgeInsets.zero,
              title: Text('Start time: ${(_time ?? const LocalTime(9, 0)).format()}'),
              trailing: const Icon(Icons.schedule),
              onTap: _pickTime,
            ),
          TextField(
            key: const Key('field-estimate'),
            controller: _estimate,
            focusNode: _estimateFocus,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: InputDecoration(
              labelText: 'Estimate (minutes)',
              errorText: _errorFor(DraftField.estimate, 'estimate_min'),
            ),
          ),
          Wrap(
            spacing: 6,
            children: [
              for (final m in const [15, 30, 60, 90])
                ChoiceChip(
                  key: Key('estimate-chip-$m'),
                  label: Text('$m'),
                  selected: _estimate.text == '$m',
                  onSelected: (_) => setState(() => _estimate.text = '$m'),
                ),
            ],
          ),
          const SizedBox(height: 12),
          TextField(
            key: const Key('field-notes'),
            controller: _notes,
            maxLines: 3,
            decoration: InputDecoration(labelText: 'Notes', errorText: _errorFor(DraftField.notes)),
          ),
          const SizedBox(height: 16),
          RecurrenceQuestion(
            isRecurring: _isRecurring,
            recurrence: _recurrence,
            errorText: _errorFor(DraftField.recurring) ?? _errorFor(DraftField.recurrence),
            onRecurringChanged: (v) => setState(() {
              _isRecurring = v;
              if (v == true) _recurrence ??= const Daily();
            }),
            onRecurrenceChanged: (r) => setState(() => _recurrence = r),
          ),
          if (state.saveError != null && state.phase == AddPhase.editing)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(
                state.saveError!,
                key: const Key('add-save-error'),
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          const SizedBox(height: 24),
          if (state.phase == AddPhase.assessing && feasibility)
            const Padding(
              padding: EdgeInsets.only(bottom: 8),
              child: Text('Checking your day…', key: Key('assessing-text')),
            ),
          FilledButton(
            key: const Key('submit-task'),
            onPressed: recurrenceAnswered && !busy ? _submit : null,
            child: Text(feasibility ? 'Check & add' : 'Add task'),
          ),
        ],
      ),
    );
  }
}

/// Body of the verdict bottom sheet; reads the flow state so it follows saving / error changes.
class _FeasibilitySheet extends ConsumerWidget {
  const _FeasibilitySheet();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(addTaskControllerProvider);
    final controller = ref.read(addTaskControllerProvider.notifier);
    final saving = state.phase == AddPhase.saving;
    final assessment = state.assessment;
    final draft = state.draft;
    if (assessment != null && draft != null) {
      return VerdictCard(
        assessment: assessment,
        draft: draft,
        location: ref.watch(appLocationProvider),
        saving: saving,
        saveError: state.saveError,
        onConfirm: controller.confirmVerdict,
        onAdjust: controller.adjust,
      );
    }
    return FeasibilityUnavailableCard(
      saving: saving,
      saveError: state.saveError,
      onAddWithoutCheck: controller.addWithoutCheck,
      onRetry: controller.retryAssessment,
      onAdjust: controller.adjust,
    );
  }
}

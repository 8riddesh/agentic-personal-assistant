import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:timezone/timezone.dart' as tz;

import '../../app_shell/domain/app_error.dart';
import '../../app_shell/domain/format.dart';
import '../../app_shell/domain/local_date.dart';
import '../../app_shell/presentation/providers.dart';
import '../domain/entities.dart';
import '../domain/start_at_resolver.dart';
import '../domain/status_change.dart';
import 'providers.dart';

/// The four choices offered for a planned task. `missed` is server-only and never offered.
enum StatusKind {
  completed('Completed'),
  postponed('Postponed'),
  cancelled('Cancelled'),
  cantDo("Can't do");

  const StatusKind(this.label);

  final String label;
}

abstract final class StatusSheet {
  /// Resolves with the updated task, or `null` when dismissed.
  static Future<Task?> show(BuildContext context, Task task, {StatusKind? preselect}) =>
      showModalBottomSheet<Task>(
        context: context,
        isScrollControlled: true,
        builder: (_) => StatusSheetBody(task: task, preselect: preselect),
      );
}

class StatusSheetBody extends ConsumerStatefulWidget {
  const StatusSheetBody({super.key, required this.task, this.preselect});

  final Task task;
  final StatusKind? preselect;

  @override
  ConsumerState<StatusSheetBody> createState() => _StatusSheetBodyState();
}

class _StatusSheetBodyState extends ConsumerState<StatusSheetBody> {
  final _reason = TextEditingController();
  StatusKind? _kind;
  DateTime? _finishedAt; // null = "Now"
  bool _pickedFinish = false;
  LocalDate? _postponeDate;
  LocalTime? _postponeTime;
  bool _submitting = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _kind = widget.preselect;
    _reason.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  StatusChange? _change() {
    switch (_kind) {
      case null:
        return null;
      case StatusKind.completed:
        return Completed(finishedAt: _finishedAt);
      case StatusKind.postponed:
        final date = _postponeDate;
        final time = _postponeTime;
        if (date == null || time == null) return null;
        final start = resolveStartAt(date, time, ref.read(appLocationProvider));
        return start == null ? null : Postponed(start);
      case StatusKind.cancelled:
        return Cancelled(reason: _reason.text);
      case StatusKind.cantDo:
        return CantDo(_reason.text);
    }
  }

  String? _validation(StatusChange? change) {
    if (change == null) return null;
    // A blank can't-do reason just keeps Confirm disabled (no error text while the user has not typed yet).
    if (change is CantDo && change.reason.trim().isEmpty) return null;
    return validateStatusChange(change, widget.task, ref.read(clockProvider).nowUtc());
  }

  Future<void> _confirm(StatusChange change) async {
    setState(() {
      _submitting = true;
      _error = null;
    });
    final messenger = ScaffoldMessenger.maybeOf(context);
    final navigator = Navigator.of(context);
    try {
      final updated = await ref.read(currentDayControllerProvider.notifier).changeStatus(widget.task, change);
      if (mounted) navigator.pop(updated);
    } on ConflictError {
      messenger?.showSnackBar(const SnackBar(content: Text('This task was already updated')));
      if (mounted) navigator.pop();
    } on NotFoundError {
      messenger?.showSnackBar(const SnackBar(content: Text('Task no longer exists')));
      if (mounted) navigator.pop();
    } on AppError catch (e) {
      if (mounted) {
        setState(() {
          _submitting = false;
          _error = e is NetworkError ? "You're offline" : e.userMessage;
        });
      }
    }
  }

  Future<void> _pickFinish() async {
    final loc = ref.read(appLocationProvider);
    final now = tz.TZDateTime.from(ref.read(clockProvider).nowUtc(), loc);
    final picked = await showTimePicker(context: context, initialTime: TimeOfDay(hour: now.hour, minute: now.minute));
    if (picked == null) return;
    final instant = localToUtc(widget.task.localDate, picked.hour, picked.minute, loc);
    setState(() {
      _finishedAt = instant;
      _pickedFinish = true;
    });
  }

  Future<void> _pickPostponeDate() async {
    final today = LocalDate.fromTz(ref.read(clockProvider).nowUtc(), ref.read(appLocationProvider));
    final initial = _postponeDate ?? today.addDays(1);
    final picked = await showDatePicker(
      context: context,
      initialDate: DateTime(initial.year, initial.month, initial.day),
      firstDate: DateTime(today.year, today.month, today.day),
      lastDate: DateTime(today.year, today.month, today.day).add(const Duration(days: 60)),
    );
    if (picked != null) setState(() => _postponeDate = LocalDate.fromDateTime(picked));
  }

  Future<void> _pickPostponeTime() async {
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: _postponeTime?.hour ?? 9, minute: _postponeTime?.minute ?? 0),
    );
    if (picked != null) setState(() => _postponeTime = LocalTime(picked.hour, picked.minute));
  }

  @override
  Widget build(BuildContext context) {
    final loc = ref.watch(appLocationProvider);
    final change = _change();
    final validation = _validation(change);
    final canConfirm = change != null && validation == null && !_submitting;
    final predictedEnd = widget.task.predictedEndAt;
    final nowUtc = ref.watch(clockProvider).nowUtc();

    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(widget.task.title, style: Theme.of(context).textTheme.titleMedium, maxLines: 2),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                children: [
                  for (final k in StatusKind.values)
                    ChoiceChip(
                      key: Key('status-option-${k.name}'),
                      label: Text(k.label),
                      selected: _kind == k,
                      onSelected: (_) => setState(() {
                        _kind = k;
                        _error = null;
                      }),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              if (_kind == StatusKind.completed) ...[
                const Text('Finished at'),
                Wrap(
                  spacing: 8,
                  children: [
                    ChoiceChip(
                      key: const Key('finish-now'),
                      label: const Text('Now'),
                      selected: _finishedAt == null,
                      onSelected: (_) => setState(() {
                        _finishedAt = null;
                        _pickedFinish = false;
                      }),
                    ),
                    if (predictedEnd != null && !predictedEnd.isAfter(nowUtc))
                      ChoiceChip(
                        key: const Key('finish-predicted'),
                        label: Text('At predicted end (${formatHm(predictedEnd, loc)})'),
                        selected: _finishedAt == predictedEnd,
                        onSelected: (_) => setState(() {
                          _finishedAt = predictedEnd;
                          _pickedFinish = false;
                        }),
                      ),
                    ChoiceChip(
                      key: const Key('finish-pick'),
                      label: Text(_pickedFinish && _finishedAt != null ? formatHm(_finishedAt!, loc) : 'Pick…'),
                      selected: _pickedFinish,
                      onSelected: (_) => _pickFinish(),
                    ),
                  ],
                ),
              ],
              if (_kind == StatusKind.postponed) ...[
                Row(
                  children: [
                    OutlinedButton(
                      key: const Key('postpone-date'),
                      onPressed: _pickPostponeDate,
                      child: Text(_postponeDate == null ? 'Pick date' : formatDayLabel(_postponeDate!)),
                    ),
                    const SizedBox(width: 8),
                    OutlinedButton(
                      key: const Key('postpone-time'),
                      onPressed: _pickPostponeTime,
                      child: Text(_postponeTime == null ? 'Pick time' : _postponeTime!.format()),
                    ),
                  ],
                ),
              ],
              if (_kind == StatusKind.cancelled || _kind == StatusKind.cantDo)
                TextField(
                  key: const Key('status-reason'),
                  controller: _reason,
                  maxLines: 2,
                  decoration: InputDecoration(
                    labelText: _kind == StatusKind.cantDo ? "Why can't you do it? (required)" : 'Reason (optional)',
                  ),
                ),
              if (validation != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(validation, key: const Key('status-validation'), style: TextStyle(color: Theme.of(context).colorScheme.error)),
                ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(_error!, key: const Key('status-error'), style: TextStyle(color: Theme.of(context).colorScheme.error)),
                ),
              const SizedBox(height: 16),
              Align(
                alignment: Alignment.centerRight,
                child: FilledButton(
                  key: const Key('status-confirm'),
                  onPressed: change != null && canConfirm ? () => _confirm(change) : null,
                  child: Text(_submitting ? 'Saving…' : 'Confirm'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

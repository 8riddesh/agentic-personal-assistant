import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app_shell/domain/app_error.dart';
import '../../app_shell/domain/format.dart';
import '../../app_shell/domain/local_date.dart';
import '../../app_shell/presentation/providers.dart';
import '../../app_shell/presentation/widgets/empty_view.dart';
import '../domain/entities.dart';
import '../domain/start_at_resolver.dart';
import 'providers.dart';

/// `/today/task/:id/edit` - planned tasks only; sends only the changed fields (tasks spec §7.5).
class EditTaskScreen extends ConsumerStatefulWidget {
  const EditTaskScreen({super.key, required this.taskId});

  final String taskId;

  @override
  ConsumerState<EditTaskScreen> createState() => _EditTaskScreenState();
}

class _EditTaskScreenState extends ConsumerState<EditTaskScreen> {
  final _title = TextEditingController();
  final _category = TextEditingController();
  final _estimate = TextEditingController();
  final _notes = TextEditingController();
  Task? _task;
  bool _anytime = true;
  LocalTime? _time;
  bool _saving = false;
  String? _error;

  Task? _find() {
    final tasks = ref.read(currentDayControllerProvider).valueOrNull?.tasks ?? const <Task>[];
    for (final t in tasks) {
      if (t.id == widget.taskId) return t;
    }
    return null;
  }

  void _seed(Task t) {
    _task = t;
    _title.text = t.title;
    _category.text = t.category;
    _estimate.text = t.estimateMin == null ? '' : '${t.estimateMin}';
    _notes.text = t.notes ?? '';
    final start = t.startAt;
    _anytime = start == null;
    if (start != null) {
      final loc = ref.read(appLocationProvider);
      final hm = formatHm(start, loc).split(':');
      _time = LocalTime(int.parse(hm[0]), int.parse(hm[1]));
    }
  }

  @override
  void dispose() {
    _title.dispose();
    _category.dispose();
    _estimate.dispose();
    _notes.dispose();
    super.dispose();
  }

  Future<void> _pickTime() async {
    final initial = _time ?? const LocalTime(9, 0);
    final picked = await showTimePicker(context: context, initialTime: TimeOfDay(hour: initial.hour, minute: initial.minute));
    if (picked != null) setState(() => _time = LocalTime(picked.hour, picked.minute));
  }

  Future<void> _save() async {
    final task = _task!;
    final loc = ref.read(appLocationProvider);
    final title = _title.text.trim();
    final category = _category.text.trim();
    if (title.isEmpty || title.length > 200) {
      setState(() => _error = 'Title must be 1–200 characters');
      return;
    }
    if (category.isEmpty || category.length > 32) {
      setState(() => _error = 'Category must be 1–32 characters');
      return;
    }
    final estimate = int.tryParse(_estimate.text.trim());
    if (estimate != null && (estimate < 5 || estimate > 720)) {
      setState(() => _error = 'Estimate must be 5–720 minutes');
      return;
    }

    final newStart = _anytime ? null : resolveStartAt(task.localDate, _time ?? const LocalTime(9, 0), loc);
    final notes = _notes.text.trim();
    final patch = <String, Object?>{
      if (title != task.title) 'title': title,
      if (category != task.category) 'category': category,
      if (estimate != task.estimateMin) 'estimate_min': estimate,
      if (notes != (task.notes ?? '')) 'notes': notes.isEmpty ? null : notes,
      if (newStart != task.startAt) 'start_at': newStart?.toUtc().toIso8601String(),
    };
    if (patch.isEmpty) {
      Navigator.of(context).pop();
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await ref.read(currentDayControllerProvider.notifier).editTask(task.id, patch);
      if (mounted) Navigator.of(context).pop();
    } on AppError catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = e.userMessage;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final task = _task ?? _find();
    if (task == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Edit task')),
        body: const EmptyView(message: 'This task no longer exists.'),
      );
    }
    if (_task == null) _seed(task);
    final editable = task.status == TaskStatus.planned;

    return Scaffold(
      appBar: AppBar(title: const Text('Edit task')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (!editable) const Text('Only planned tasks can be edited.', key: Key('not-editable')),
          TextField(key: const Key('edit-title'), controller: _title, enabled: editable, decoration: const InputDecoration(labelText: 'Title')),
          const SizedBox(height: 12),
          TextField(key: const Key('edit-category'), controller: _category, enabled: editable, decoration: const InputDecoration(labelText: 'Category')),
          SwitchListTile(
            key: const Key('edit-anytime'),
            contentPadding: EdgeInsets.zero,
            title: const Text('Anytime'),
            value: _anytime,
            onChanged: editable ? (v) => setState(() => _anytime = v) : null,
          ),
          if (!_anytime)
            ListTile(
              key: const Key('edit-time'),
              contentPadding: EdgeInsets.zero,
              title: Text('Start time: ${(_time ?? const LocalTime(9, 0)).format()}'),
              trailing: const Icon(Icons.schedule),
              onTap: editable ? _pickTime : null,
            ),
          TextField(
            key: const Key('edit-estimate'),
            controller: _estimate,
            enabled: editable,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: const InputDecoration(labelText: 'Estimate (minutes)'),
          ),
          const SizedBox(height: 12),
          TextField(key: const Key('edit-notes'), controller: _notes, maxLines: 3, decoration: const InputDecoration(labelText: 'Notes')),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(_error!, key: const Key('edit-error'), style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ),
          const SizedBox(height: 24),
          FilledButton(
            key: const Key('edit-save'),
            onPressed: _saving ? null : _save,
            child: Text(_saving ? 'Saving…' : 'Save'),
          ),
        ],
      ),
    );
  }
}

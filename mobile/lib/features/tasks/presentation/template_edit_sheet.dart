import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app_shell/domain/app_error.dart';
import '../../app_shell/domain/local_date.dart';
import '../domain/entities.dart';
import 'add_task/recurrence_question.dart';
import 'providers.dart';

/// Edit a recurring template (changes apply to days not yet created; tasks spec §7.7).
class TemplateEditSheet extends ConsumerStatefulWidget {
  const TemplateEditSheet({super.key, required this.template});

  final Template template;

  static Future<void> show(BuildContext context, Template template) => showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        builder: (_) => TemplateEditSheet(template: template),
      );

  @override
  ConsumerState<TemplateEditSheet> createState() => _TemplateEditSheetState();
}

class _TemplateEditSheetState extends ConsumerState<TemplateEditSheet> {
  late final TextEditingController _title = TextEditingController(text: widget.template.title);
  late final TextEditingController _category = TextEditingController(text: widget.template.category);
  late final TextEditingController _notes = TextEditingController(text: widget.template.notes ?? '');
  late final TextEditingController _estimate =
      TextEditingController(text: widget.template.defaultEstimateMin?.toString() ?? '');
  late bool _anytime = widget.template.startLocal == null;
  late LocalTime? _time = widget.template.startLocal;
  late Recurrence _recurrence = widget.template.recurrence;
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _title.dispose();
    _category.dispose();
    _notes.dispose();
    _estimate.dispose();
    super.dispose();
  }

  Future<void> _pickTime() async {
    final initial = _time ?? const LocalTime(9, 0);
    final picked = await showTimePicker(context: context, initialTime: TimeOfDay(hour: initial.hour, minute: initial.minute));
    if (picked != null) setState(() => _time = LocalTime(picked.hour, picked.minute));
  }

  Future<void> _save() async {
    final t = widget.template;
    final title = _title.text.trim();
    final category = _category.text.trim();
    final recurrence = _recurrence;
    if (title.isEmpty || title.length > 200 || category.isEmpty || category.length > 32) {
      setState(() => _error = 'Title (1–200) and category (1–32) are required');
      return;
    }
    if (recurrence is Weekly && recurrence.byWeekday.isEmpty) {
      setState(() => _error = 'Pick at least one weekday');
      return;
    }
    final estimate = int.tryParse(_estimate.text.trim());
    final start = _anytime ? null : (_time ?? const LocalTime(9, 0));
    final notes = _notes.text.trim();

    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await ref.read(templatesControllerProvider.notifier).save(
            t.id,
            title: title == t.title ? null : title,
            category: category == t.category ? null : category,
            notes: notes == (t.notes ?? '') ? null : notes,
            startLocal: start != null && start != t.startLocal ? start : null,
            clearStart: start == null && t.startLocal != null,
            defaultEstimateMin: estimate != null && estimate != t.defaultEstimateMin ? estimate : null,
            recurrence: recurrence == t.recurrence ? null : recurrence,
          );
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
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(key: const Key('tpl-title'), controller: _title, decoration: const InputDecoration(labelText: 'Title')),
              const SizedBox(height: 8),
              TextField(key: const Key('tpl-category'), controller: _category, decoration: const InputDecoration(labelText: 'Category')),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Anytime'),
                value: _anytime,
                onChanged: (v) => setState(() => _anytime = v),
              ),
              if (!_anytime)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text('Start time: ${(_time ?? const LocalTime(9, 0)).format()}'),
                  trailing: const Icon(Icons.schedule),
                  onTap: _pickTime,
                ),
              TextField(
                key: const Key('tpl-estimate'),
                controller: _estimate,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                decoration: const InputDecoration(labelText: 'Estimate (minutes)'),
              ),
              TextField(key: const Key('tpl-notes'), controller: _notes, maxLines: 2, decoration: const InputDecoration(labelText: 'Notes')),
              const SizedBox(height: 12),
              RecurrenceSelector(value: _recurrence, onChanged: (r) => setState(() => _recurrence = r)),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(_error!, key: const Key('tpl-error'), style: TextStyle(color: Theme.of(context).colorScheme.error)),
                ),
              const SizedBox(height: 16),
              Align(
                alignment: Alignment.centerRight,
                child: FilledButton(key: const Key('tpl-save'), onPressed: _saving ? null : _save, child: Text(_saving ? 'Saving…' : 'Save')),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

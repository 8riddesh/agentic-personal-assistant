import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app_shell/domain/app_error.dart';
import '../../app_shell/presentation/widgets/async_value_view.dart';
import '../../app_shell/presentation/widgets/empty_view.dart';
import '../domain/entities.dart';
import 'providers.dart';
import 'template_edit_sheet.dart';

/// `/today/templates`: recurring tasks. Templates are created only through "Recurring" on a new task.
class TemplatesScreen extends ConsumerWidget {
  const TemplatesScreen({super.key});

  void _snack(BuildContext context, String message) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));

  Future<void> _toggle(BuildContext context, WidgetRef ref, Template t, bool active) async {
    try {
      await ref.read(templatesControllerProvider.notifier).toggleActive(t.id, active);
    } on AppError catch (e) {
      if (context.mounted) _snack(context, e.userMessage);
    }
  }

  Future<void> _delete(BuildContext context, WidgetRef ref, Template t) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete template?'),
        content: const Text("Today's already-created task stays."),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Cancel')),
          FilledButton(key: const Key('delete-confirm'), onPressed: () => Navigator.of(ctx).pop(true), child: const Text('Delete')),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await ref.read(templatesControllerProvider.notifier).delete(t.id);
    } on AppError catch (e) {
      if (context.mounted) _snack(context, e.userMessage);
    }
  }

  String _subtitle(Template t) {
    final parts = <String>[t.recurrence.summary.replaceFirst('Repeats ', ''), t.startLocal?.format() ?? 'Anytime'];
    if (t.defaultEstimateMin != null) parts.add('${t.defaultEstimateMin} min');
    return parts.join(' · ');
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final value = ref.watch(templatesControllerProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Recurring tasks')),
      body: AsyncValueView<List<Template>>(
        value: value,
        onRetry: () => ref.invalidate(templatesControllerProvider),
        isEmpty: (list) => list.isEmpty,
        empty: const EmptyView(message: "No recurring tasks — add one with 'Recurring' on a new task"),
        data: (list) => ListView(
          children: [
            for (final t in list)
              ListTile(
                key: Key('template-${t.id}'),
                title: Text(t.title),
                subtitle: Text(_subtitle(t)),
                onTap: () => TemplateEditSheet.show(context, t),
                leading: Switch(
                  key: Key('template-switch-${t.id}'),
                  value: t.active,
                  onChanged: (v) => _toggle(context, ref, t, v),
                ),
                trailing: PopupMenuButton<String>(
                  key: Key('template-menu-${t.id}'),
                  onSelected: (v) {
                    if (v == 'delete') _delete(context, ref, t);
                  },
                  itemBuilder: (_) => const [PopupMenuItem(value: 'delete', child: Text('Delete'))],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

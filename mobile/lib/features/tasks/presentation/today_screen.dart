import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:timezone/timezone.dart' as tz;

import '../../app_shell/domain/format.dart';
import '../../app_shell/presentation/providers.dart';
import '../../app_shell/presentation/widgets/async_value_view.dart';
import '../../app_shell/presentation/widgets/empty_view.dart';
import '../domain/entities.dart';
import '../domain/today_sorter.dart';
import 'add_task/add_task_screen.dart';
import 'providers.dart';
import 'status_sheet.dart';
import 'task_tile.dart';

class TodayScreen extends ConsumerWidget {
  const TodayScreen({super.key});

  Future<void> _refresh(WidgetRef ref) => ref.read(currentDayControllerProvider.notifier).refresh();

  void _showDetails(BuildContext context, Task task, Task? postponedTo) {
    showModalBottomSheet<void>(
      context: context,
      builder: (_) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(task.title, style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              Text(statusLabel(task.status), key: const Key('details-status')),
              if (task.statusReason != null && task.statusReason!.isNotEmpty) Text(task.statusReason!),
              if (task.notes != null && task.notes!.isNotEmpty) ...[const SizedBox(height: 8), Text(task.notes!)],
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final location = ref.watch(appLocationProvider);
    final value = ref.watch(currentDayControllerProvider);

    // Yesterday closed automatically at midnight: tell the user once (spec §7.1).
    ref.listen<AsyncValue<TodayState>>(currentDayControllerProvider, (previous, next) {
      final id = next.valueOrNull?.autoClosedReportId;
      if (id != null && id != previous?.valueOrNull?.autoClosedReportId) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text('Yesterday closed automatically'),
            action: SnackBarAction(label: 'View report', onPressed: () => context.push('/reports/$id')),
          ),
        );
      }
    });

    final today = value.valueOrNull;
    final title = today == null ? 'Today' : 'Today · ${formatDayLabel(today.day.localDate)}';
    final canAdd = today != null && today.day.isOpen && !today.fromCache;

    return Scaffold(
      appBar: AppBar(
        title: Text(title, key: const Key('today-title')),
        actions: [
          IconButton(
            key: const Key('open-templates'),
            tooltip: 'Recurring tasks',
            icon: const Icon(Icons.repeat),
            onPressed: () => context.push('/today/templates'),
          ),
        ],
      ),
      floatingActionButton: today != null && today.day.isOpen
          ? FloatingActionButton.extended(
              key: const Key('add-task-fab'),
              onPressed: canAdd ? () => AddTaskFlow.start(context) : null,
              icon: const Icon(Icons.add),
              label: const Text('Add task'),
            )
          : null,
      body: AsyncValueView<TodayState>(
        value: value,
        onRetry: () => _refresh(ref),
        isEmpty: (s) => s.tasks.isEmpty && s.day.isOpen,
        empty: Column(
          children: [
            ...ref.watch(todayHeaderSectionsProvider),
            Expanded(
              child: EmptyView(
                message: 'Nothing planned yet',
                actionLabel: 'Add task',
                onAction: () => AddTaskFlow.start(context),
              ),
            ),
          ],
        ),
        data: (s) => _TodayContent(
          state: s,
          location: location,
          onRefresh: () => _refresh(ref),
          onTapTask: (task, postponedTo) async {
            if (task.isTerminal || !s.day.isOpen) {
              _showDetails(context, task, postponedTo);
            } else {
              await StatusSheet.show(context, task);
            }
          },
          onEditTask: (task) => context.push('/today/task/${task.id}/edit'),
          headers: ref.watch(todayHeaderSectionsProvider),
        ),
      ),
    );
  }
}

class _TodayContent extends StatelessWidget {
  const _TodayContent({
    required this.state,
    required this.location,
    required this.onRefresh,
    required this.onTapTask,
    required this.onEditTask,
    required this.headers,
  });

  final TodayState state;
  final tz.Location location;
  final Future<void> Function() onRefresh;
  final void Function(Task task, Task? postponedTo) onTapTask;
  final void Function(Task task) onEditTask;
  final List<Widget> headers;

  Task? _postponedTarget(Task t) {
    final id = t.postponedToTaskId;
    if (id == null) return null;
    for (final other in state.tasks) {
      if (other.id == id) return other;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final sections = sectionTasks(state.tasks);
    final done = state.tasks.where((t) => t.status == TaskStatus.completed).length;
    final day = state.day;

    return RefreshIndicator(
      onRefresh: onRefresh,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          ...headers,
          if (state.fromCache)
            Container(
              color: Theme.of(context).colorScheme.tertiaryContainer,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Text(
                'Offline · last updated ${formatHm(state.fetchedAt, location)}',
                key: const Key('offline-note'),
              ),
            ),
          if (!day.isOpen)
            ListTile(
              key: const Key('closed-banner'),
              tileColor: Theme.of(context).colorScheme.secondaryContainer,
              title: Text(
                day.closedAt == null
                    ? 'Day closed'
                    : 'Day closed at ${formatHm(day.closedAt!, location)}',
              ),
              trailing: day.dailyReportId == null ? null : const Text('View report'),
              onTap: day.dailyReportId == null ? null : () => context.push('/reports/${day.dailyReportId}'),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Text('$done of ${state.tasks.length} done', key: const Key('progress-text')),
          ),
          for (final t in sections.planned)
            TaskTile(
              task: t,
              location: location,
              onTap: () => onTapTask(t, null),
              onLongPress: day.isOpen ? () => onEditTask(t) : null,
            ),
          if (sections.finished.isNotEmpty)
            ExpansionTile(
              key: const Key('finished-section'),
              title: Text('Finished (${sections.finished.length})'),
              children: [
                for (final t in sections.finished)
                  TaskTile(
                    task: t,
                    location: location,
                    postponedTo: _postponedTarget(t),
                    onTap: () => onTapTask(t, _postponedTarget(t)),
                  ),
              ],
            ),
          const SizedBox(height: 88), // room for the FAB
        ],
      ),
    );
  }
}

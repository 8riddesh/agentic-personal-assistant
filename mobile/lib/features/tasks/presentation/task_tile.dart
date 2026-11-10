import 'package:flutter/material.dart';
import 'package:timezone/timezone.dart' as tz;

import '../../app_shell/domain/format.dart';
import '../../app_shell/presentation/theme.dart';
import '../domain/entities.dart';

String statusLabel(TaskStatus s) => switch (s) {
      TaskStatus.planned => 'Planned',
      TaskStatus.completed => 'Completed',
      TaskStatus.postponed => 'Postponed',
      TaskStatus.cancelled => 'Cancelled',
      TaskStatus.cantDo => "Can't do",
      TaskStatus.missed => 'Missed',
    };

class TaskTile extends StatelessWidget {
  const TaskTile({
    super.key,
    required this.task,
    required this.location,
    this.postponedTo,
    this.onTap,
    this.onLongPress,
  });

  final Task task;
  final tz.Location location;

  /// The copy created by a postponement, when it is known (to show "postponed to Tue 10:00").
  final Task? postponedTo;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  String _subtitle() {
    final parts = <String>[task.category];
    final end = task.predictedEndAt;
    if (!task.isTerminal && end != null) parts.add('ends ~${formatHm(end, location)}');
    if (task.status == TaskStatus.postponed) {
      final target = postponedTo?.startAt;
      parts.add(target == null ? 'postponed' : 'postponed to ${formatWeekdayTime(target, location)}');
    }
    final reason = task.statusReason;
    if (task.status == TaskStatus.cantDo && reason != null && reason.isNotEmpty) parts.add(reason);
    return parts.join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final start = task.startAt;
    return ListTile(
      key: Key('task-tile-${task.id}'),
      onTap: onTap,
      onLongPress: onLongPress,
      leading: SizedBox(
        width: 56,
        child: Text(
          start == null ? 'Anytime' : formatHm(start, location),
          key: const Key('tile-time'),
          style: Theme.of(context).textTheme.titleSmall,
        ),
      ),
      title: Text(task.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(_subtitle(), key: const Key('tile-subtitle'), maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: Wrap(
        spacing: 6,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          if (task.checkResponse == CheckResponse.notYet)
            const Chip(key: Key('not-yet-chip'), label: Text('Not yet'), visualDensity: VisualDensity.compact),
          if (task.pendingStatus != null) const Icon(Icons.sync, key: Key('sync-icon'), size: 18),
          Chip(
            key: const Key('status-chip'),
            label: Text(statusLabel(task.status), style: const TextStyle(color: Colors.white, fontSize: 12)),
            backgroundColor: AppStatusColors.of(task.status.json, scheme),
            visualDensity: VisualDensity.compact,
          ),
        ],
      ),
    );
  }
}

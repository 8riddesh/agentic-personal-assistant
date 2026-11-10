import 'entities.dart';

/// What the user chose in the status sheet. `missed` is never offered (server-only).
sealed class StatusChange {
  const StatusChange();

  TaskStatus get target;

  /// Request body of `POST /tasks/{id}/status`.
  Map<String, Object?> toJson({String source = 'app'});
}

final class Completed extends StatusChange {
  const Completed({this.finishedAt});

  final DateTime? finishedAt;

  @override
  TaskStatus get target => TaskStatus.completed;

  @override
  Map<String, Object?> toJson({String source = 'app'}) => {
        'status': 'completed',
        if (finishedAt != null) 'finished_at': finishedAt!.toUtc().toIso8601String(),
        'source': source,
      };
}

final class Postponed extends StatusChange {
  const Postponed(this.newStartAt);

  final DateTime newStartAt;

  @override
  TaskStatus get target => TaskStatus.postponed;

  @override
  Map<String, Object?> toJson({String source = 'app'}) => {
        'status': 'postponed',
        'new_start_at': newStartAt.toUtc().toIso8601String(),
        'source': source,
      };
}

final class Cancelled extends StatusChange {
  const Cancelled({this.reason});

  final String? reason;

  @override
  TaskStatus get target => TaskStatus.cancelled;

  @override
  Map<String, Object?> toJson({String source = 'app'}) => {
        'status': 'cancelled',
        if (reason != null && reason!.trim().isNotEmpty) 'reason': reason!.trim(),
        'source': source,
      };
}

final class CantDo extends StatusChange {
  const CantDo(this.reason);

  final String reason;

  @override
  TaskStatus get target => TaskStatus.cantDo;

  @override
  Map<String, Object?> toJson({String source = 'app'}) => {
        'status': 'cant_do',
        'reason': reason.trim(),
        'source': source,
      };
}

const int maxReasonLength = 500;

/// Client-side validation (spec §7.6). Returns a message, or `null` when the change is acceptable.
String? validateStatusChange(StatusChange change, Task task, DateTime nowUtc) {
  switch (change) {
    case Completed(:final finishedAt):
      final t = finishedAt ?? nowUtc;
      if (t.isAfter(nowUtc)) return "Finish time can't be in the future";
      final start = task.startAt;
      if (start != null && !t.isAfter(start)) return 'Finish time must be after the start time';
      return null;
    case Postponed(:final newStartAt):
      if (!newStartAt.isAfter(nowUtc)) return 'Pick a time in the future';
      if (task.startAt != null && newStartAt.isAtSameMomentAs(task.startAt!)) {
        return 'Pick a different time than the current start';
      }
      return null;
    case Cancelled(:final reason):
      if (reason != null && reason.trim().length > maxReasonLength) return 'Reason is too long (max 500)';
      return null;
    case CantDo(:final reason):
      final r = reason.trim();
      if (r.isEmpty) return 'A reason is required';
      if (r.length > maxReasonLength) return 'Reason is too long (max 500)';
      return null;
  }
}

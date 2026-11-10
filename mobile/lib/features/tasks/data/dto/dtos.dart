import '../../../app_shell/domain/local_date.dart';
import '../../domain/entities.dart';

DateTime? _dt(Object? v) => v == null ? null : DateTime.parse(v as String).toUtc();

/// `TaskDTO` (snake_case) -> entity. `pending_status` is an on-device extra written by [taskToJson].
Task taskFromJson(Object? json) {
  if (json is! Map) throw const FormatException('Unexpected task payload');
  return Task(
    id: json['id'] as String,
    localDate: LocalDate.parse(json['local_date'] as String),
    templateId: json['template_id'] as String?,
    originTemplateId: json['origin_template_id'] as String?,
    title: json['title'] as String,
    notes: json['notes'] as String?,
    category: json['category'] as String,
    startAt: _dt(json['start_at']),
    estimateMin: (json['estimate_min'] as num?)?.toInt(),
    predictedEndAt: _dt(json['predicted_end_at']),
    predictionMethod: json['prediction_method'] as String?,
    actualEndAt: _dt(json['actual_end_at']),
    status: TaskStatus.parse(json['status'] as String),
    statusReason: json['status_reason'] as String?,
    postponedToTaskId: json['postponed_to_task_id'] as String?,
    feasibilityId: json['feasibility_id'] as String?,
    feasibilityOverridden: json['feasibility_overridden'] as bool? ?? false,
    createdVia: CreatedVia.parse(json['created_via'] as String? ?? 'form'),
    checkResponse: json['check_response'] == null ? null : CheckResponse.parse(json['check_response'] as String),
    pendingStatus: json['pending_status'] as String?,
  );
}

Map<String, Object?> taskToJson(Task t) => {
      'id': t.id,
      'local_date': t.localDate.toIso(),
      'template_id': t.templateId,
      'origin_template_id': t.originTemplateId,
      'is_recurring': t.isRecurring,
      'title': t.title,
      'notes': t.notes,
      'category': t.category,
      'start_at': t.startAt?.toUtc().toIso8601String(),
      'estimate_min': t.estimateMin,
      'predicted_end_at': t.predictedEndAt?.toUtc().toIso8601String(),
      'prediction_method': t.predictionMethod,
      'actual_end_at': t.actualEndAt?.toUtc().toIso8601String(),
      'status': t.status.json,
      'status_reason': t.statusReason,
      'postponed_to_task_id': t.postponedToTaskId,
      'feasibility_id': t.feasibilityId,
      'feasibility_overridden': t.feasibilityOverridden,
      'created_via': t.createdVia.name,
      'check_response': t.checkResponse?.json,
      'pending_status': t.pendingStatus,
    };

/// Accepts a bare task, or a result wrapper (`{task, ...}`) as returned by `POST /tasks` and `POST .../status`.
Task taskFromResponse(Object? json) {
  if (json is Map && json['task'] is Map) return taskFromJson(json['task']);
  return taskFromJson(json);
}

Day dayFromJson(Object? json) {
  if (json is! Map) throw const FormatException('Unexpected day payload');
  return Day(
    id: json['id'] as String,
    localDate: LocalDate.parse(json['local_date'] as String),
    state: DayState.parse(json['state'] as String),
    openedAt: _dt(json['opened_at'])!,
    closedAt: _dt(json['closed_at']),
    closeMode: json['close_mode'] as String?,
    dailyReportId: json['daily_report_id'] as String?,
    weeklyReportId: json['weekly_report_id'] as String?,
  );
}

Map<String, Object?> dayToJson(Day d) => {
      'id': d.id,
      'local_date': d.localDate.toIso(),
      'state': d.state.name,
      'opened_at': d.openedAt.toUtc().toIso8601String(),
      'closed_at': d.closedAt?.toUtc().toIso8601String(),
      'close_mode': d.closeMode,
      'daily_report_id': d.dailyReportId,
      'weekly_report_id': d.weeklyReportId,
    };

Assessment assessmentFromJson(Object? json) {
  if (json is! Map) throw const FormatException('Unexpected assessment payload');
  return Assessment(
    assessmentId: json['assessment_id'] as String,
    verdict: Verdict.parse(json['verdict'] as String),
    score: (json['score'] as num).toDouble(),
    feasibleNoul: (json['feasible_noul'] as num).toDouble(),
    recommendedAction: RecommendedAction.parse(json['recommended_action'] as String),
    suggestion: json['suggestion'] as String? ?? '',
    predictedEndAt: _dt(json['predicted_end_at']),
    engine: json['engine'] as String?,
    degraded: json['degraded'] as bool? ?? false,
  );
}

Template templateFromJson(Object? json) {
  if (json is! Map) throw const FormatException('Unexpected template payload');
  return Template(
    id: json['id'] as String,
    title: json['title'] as String,
    notes: json['notes'] as String?,
    category: json['category'] as String,
    startLocal: json['start_local'] == null ? null : LocalTime.parse(json['start_local'] as String),
    recurrence: Recurrence.fromJson(json['recurrence']),
    defaultEstimateMin: (json['default_estimate_min'] as num?)?.toInt(),
    startsOn: json['starts_on'] == null ? null : LocalDate.parse(json['starts_on'] as String),
    active: json['active'] as bool? ?? true,
  );
}

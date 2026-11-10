import '../../app_shell/domain/format.dart';
import '../../app_shell/domain/local_date.dart';

enum TaskStatus {
  planned,
  completed,
  postponed,
  cancelled,
  cantDo,
  missed;

  /// Backend spelling (`cant_do`).
  String get json => this == TaskStatus.cantDo ? 'cant_do' : name;

  static TaskStatus parse(String s) => values.firstWhere(
        (v) => v.json == s,
        orElse: () => throw FormatException('Unknown task status', s),
      );
}

enum CheckResponse {
  done,
  notYet;

  String get json => this == CheckResponse.notYet ? 'not_yet' : name;

  static CheckResponse parse(String s) => values.firstWhere(
        (v) => v.json == s,
        orElse: () => throw FormatException('Unknown check response', s),
      );
}

enum CreatedVia {
  form,
  chat,
  template;

  static CreatedVia parse(String s) => values.firstWhere(
        (v) => v.name == s,
        orElse: () => throw FormatException('Unknown created_via', s),
      );
}

enum Verdict {
  go,
  caution,
  noGo;

  String get json => this == Verdict.noGo ? 'no_go' : name;

  static Verdict parse(String s) => values.firstWhere(
        (v) => v.json == s,
        orElse: () => throw FormatException('Unknown verdict', s),
      );
}

enum RecommendedAction {
  proceed,
  reschedule,
  split,
  shorten,
  drop;

  static RecommendedAction parse(String s) => values.firstWhere(
        (v) => v.name == s,
        orElse: () => throw FormatException('Unknown recommended action', s),
      );
}

enum DayState {
  open,
  closing,
  closed;

  static DayState parse(String s) => values.firstWhere(
        (v) => v.name == s,
        orElse: () => throw FormatException('Unknown day state', s),
      );
}

/// Daily, or weekly on chosen weekdays (0 = Monday ... 6 = Sunday).
sealed class Recurrence {
  const Recurrence();

  factory Recurrence.fromJson(Object? json) {
    if (json is! Map) throw const FormatException('Invalid recurrence');
    switch (json['freq']) {
      case 'daily':
        return const Daily();
      case 'weekly':
        final days = (json['byweekday'] as List).map((e) => (e as num).toInt()).toSet();
        return Weekly(days);
      default:
        throw FormatException('Unknown recurrence', json['freq']);
    }
  }

  Map<String, Object?> toJson();

  /// "Repeats every day" / "Repeats Mon, Wed, Fri".
  String get summary;
}

final class Daily extends Recurrence {
  const Daily();

  @override
  Map<String, Object?> toJson() => const {'freq': 'daily'};

  @override
  String get summary => 'Repeats every day';

  @override
  bool operator ==(Object other) => other is Daily;

  @override
  int get hashCode => 1;
}

final class Weekly extends Recurrence {
  const Weekly(this.byWeekday);

  final Set<int> byWeekday;

  List<int> get sortedDays => byWeekday.toList()..sort();

  @override
  Map<String, Object?> toJson() => {'freq': 'weekly', 'byweekday': sortedDays};

  @override
  String get summary => 'Repeats ${sortedDays.map(weekdayShort).join(', ')}';

  @override
  bool operator ==(Object other) =>
      other is Weekly && other.byWeekday.length == byWeekday.length && other.byWeekday.containsAll(byWeekday);

  @override
  int get hashCode => Object.hashAll(sortedDays);
}

class Task {
  const Task({
    required this.id,
    required this.localDate,
    required this.title,
    required this.category,
    required this.status,
    required this.createdVia,
    this.templateId,
    this.originTemplateId,
    this.notes,
    this.startAt,
    this.estimateMin,
    this.predictedEndAt,
    this.predictionMethod,
    this.actualEndAt,
    this.statusReason,
    this.postponedToTaskId,
    this.feasibilityId,
    this.feasibilityOverridden = false,
    this.checkResponse,
    this.pendingStatus,
  });

  final String id;
  final LocalDate localDate;
  final String? templateId;
  final String? originTemplateId;
  final String title;
  final String? notes;
  final String category;
  final DateTime? startAt;
  final int? estimateMin;
  final DateTime? predictedEndAt;
  final String? predictionMethod;
  final DateTime? actualEndAt;
  final TaskStatus status;
  final String? statusReason;
  final String? postponedToTaskId;
  final String? feasibilityId;
  final bool feasibilityOverridden;
  final CreatedVia createdVia;
  final CheckResponse? checkResponse;

  /// Optimistic status awaiting outbox sync (on-device only).
  final String? pendingStatus;

  bool get isTerminal => status != TaskStatus.planned;
  bool get isTimed => startAt != null;
  bool get isRecurring => originTemplateId != null;

  /// Optimistic local change (offline status answer).
  Task withOptimisticStatus(TaskStatus newStatus, {String? reason, DateTime? actualEndAt}) => Task(
        id: id,
        localDate: localDate,
        templateId: templateId,
        originTemplateId: originTemplateId,
        title: title,
        notes: notes,
        category: category,
        startAt: startAt,
        estimateMin: estimateMin,
        predictedEndAt: predictedEndAt,
        predictionMethod: predictionMethod,
        actualEndAt: actualEndAt ?? this.actualEndAt,
        status: newStatus,
        statusReason: reason ?? statusReason,
        postponedToTaskId: postponedToTaskId,
        feasibilityId: feasibilityId,
        feasibilityOverridden: feasibilityOverridden,
        createdVia: createdVia,
        checkResponse: checkResponse,
        pendingStatus: newStatus.json,
      );

  Task withoutPending() => Task(
        id: id,
        localDate: localDate,
        templateId: templateId,
        originTemplateId: originTemplateId,
        title: title,
        notes: notes,
        category: category,
        startAt: startAt,
        estimateMin: estimateMin,
        predictedEndAt: predictedEndAt,
        predictionMethod: predictionMethod,
        actualEndAt: actualEndAt,
        status: status,
        statusReason: statusReason,
        postponedToTaskId: postponedToTaskId,
        feasibilityId: feasibilityId,
        feasibilityOverridden: feasibilityOverridden,
        createdVia: createdVia,
        checkResponse: checkResponse,
      );
}

class Day {
  const Day({
    required this.id,
    required this.localDate,
    required this.state,
    required this.openedAt,
    this.closedAt,
    this.closeMode,
    this.dailyReportId,
    this.weeklyReportId,
  });

  final String id;
  final LocalDate localDate;
  final DayState state;
  final DateTime openedAt;
  final DateTime? closedAt;
  final String? closeMode;
  final String? dailyReportId;
  final String? weeklyReportId;

  bool get isOpen => state == DayState.open;
}

/// What the Today screen renders. [fromCache] = the server could not be reached; [autoClosedReportId] is set when
/// the previous day was closed automatically at midnight and has a report to show.
class TodayState {
  const TodayState({
    required this.day,
    required this.tasks,
    required this.fetchedAt,
    required this.fromCache,
    this.autoClosedReportId,
  });

  final Day day;
  final List<Task> tasks;
  final DateTime fetchedAt;
  final bool fromCache;
  final String? autoClosedReportId;

  TodayState copyWith({
    Day? day,
    List<Task>? tasks,
    DateTime? fetchedAt,
    bool? fromCache,
    String? autoClosedReportId,
  }) =>
      TodayState(
        day: day ?? this.day,
        tasks: tasks ?? this.tasks,
        fetchedAt: fetchedAt ?? this.fetchedAt,
        fromCache: fromCache ?? this.fromCache,
        autoClosedReportId: autoClosedReportId ?? this.autoClosedReportId,
      );
}

/// A task as the user is typing it (shared with feasibility / chat). [isRecurring] null = not answered yet.
class TaskDraft {
  const TaskDraft({
    required this.title,
    required this.localDate,
    this.notes,
    this.category = 'Personal',
    this.startAt,
    this.estimateMin,
    this.isRecurring,
    this.recurrence,
  });

  final String title;
  final String? notes;
  final String category;
  final LocalDate localDate;
  final DateTime? startAt;
  final int? estimateMin;
  final bool? isRecurring;
  final Recurrence? recurrence;

  /// Request body shared by `/feasibility/assess` and `/tasks` (before the create-only fields).
  Map<String, Object?> toJson() => {
        'local_date': localDate.toIso(),
        'title': title.trim(),
        if (notes != null && notes!.trim().isNotEmpty) 'notes': notes!.trim(),
        'category': category.trim(),
        if (startAt != null) 'start_at': startAt!.toUtc().toIso8601String(),
        if (estimateMin != null) 'estimate_min': estimateMin,
        'is_recurring': isRecurring ?? false,
        if (isRecurring == true && recurrence != null) 'recurrence': recurrence!.toJson(),
      };

  /// An [Assessment] is bound to this fingerprint: any field change invalidates it (spec §8.3).
  String get fingerprint => toJson().entries.map((e) => '${e.key}=${e.value}').join('|');
}

class Assessment {
  const Assessment({
    required this.assessmentId,
    required this.verdict,
    required this.score,
    required this.feasibleNoul,
    required this.recommendedAction,
    required this.suggestion,
    this.predictedEndAt,
    this.engine,
    this.degraded = false,
  });

  final String assessmentId;
  final Verdict verdict;
  final double score;
  final double feasibleNoul;
  final RecommendedAction recommendedAction;
  final String suggestion;
  final DateTime? predictedEndAt;
  final String? engine;
  final bool degraded;
}

class Template {
  const Template({
    required this.id,
    required this.title,
    required this.category,
    required this.recurrence,
    required this.active,
    this.notes,
    this.startLocal,
    this.defaultEstimateMin,
    this.startsOn,
  });

  final String id;
  final String title;
  final String? notes;
  final String category;
  final LocalTime? startLocal;
  final Recurrence recurrence;
  final int? defaultEstimateMin;
  final LocalDate? startsOn;
  final bool active;

  Template copyWith({bool? active}) => Template(
        id: id,
        title: title,
        notes: notes,
        category: category,
        startLocal: startLocal,
        recurrence: recurrence,
        defaultEstimateMin: defaultEstimateMin,
        startsOn: startsOn,
        active: active ?? this.active,
      );
}

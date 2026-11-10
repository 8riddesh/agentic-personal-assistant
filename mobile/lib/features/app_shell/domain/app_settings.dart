/// Server-side settings (`GET/PATCH /settings`).
class AppSettings {
  const AppSettings({
    required this.timezone,
    required this.reminderOffsetsMin,
    required this.reportEmail,
    required this.weekStart,
    this.timezoneConfirmed = false,
  });

  factory AppSettings.fromJson(Object? json) {
    if (json is! Map) throw const FormatException('Unexpected /settings response');
    final offsets = json['reminder_offsets_min'];
    return AppSettings(
      timezone: json['timezone'] as String? ?? 'UTC',
      reminderOffsetsMin: offsets is List ? offsets.whereType<num>().map((e) => e.toInt()).toList() : const [60, 30],
      reportEmail: json['report_email'] as String?,
      weekStart: (json['week_start'] as num?)?.toInt() ?? 1,
      timezoneConfirmed: json['timezone_confirmed'] as bool? ?? false,
    );
  }

  final String timezone;
  final List<int> reminderOffsetsMin;
  final String? reportEmail;
  final int weekStart;
  final bool timezoneConfirmed;

  /// "1 hour and 30 minutes before start; one completion check" (read-only: P5 fixes the offsets).
  String get reminderSummary {
    String label(int n) => n == 60 ? '1 hour' : (n % 60 == 0 ? '${n ~/ 60} hours' : '$n minutes');
    final shown = reminderOffsetsMin.take(2).map(label).toList();
    final before = shown.isEmpty ? 'no reminders' : '${shown.join(' and ')} before start';
    return '$before; one completion check';
  }
}

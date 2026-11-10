import 'package:timezone/timezone.dart' as tz;

/// A calendar date in the app's time zone (ISO `yyyy-MM-dd`), independent of any instant.
class LocalDate implements Comparable<LocalDate> {
  const LocalDate(this.year, this.month, this.day);

  factory LocalDate.parse(String iso) {
    final m = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(iso);
    if (m == null) throw FormatException('Invalid local date', iso);
    final y = int.parse(m.group(1)!);
    final mo = int.parse(m.group(2)!);
    final d = int.parse(m.group(3)!);
    final check = DateTime.utc(y, mo, d);
    if (check.year != y || check.month != mo || check.day != d) {
      throw FormatException('Invalid local date', iso);
    }
    return LocalDate(y, mo, d);
  }

  factory LocalDate.fromDateTime(DateTime d) => LocalDate(d.year, d.month, d.day);

  /// The local date of the instant [utc] in [loc].
  static LocalDate fromTz(DateTime utc, tz.Location loc) {
    final l = tz.TZDateTime.from(utc, loc);
    return LocalDate(l.year, l.month, l.day);
  }

  final int year;
  final int month;
  final int day;

  String toIso() =>
      '${year.toString().padLeft(4, '0')}-${month.toString().padLeft(2, '0')}-${day.toString().padLeft(2, '0')}';

  /// Calendar arithmetic (done in UTC so DST never shifts the result).
  LocalDate addDays(int n) => LocalDate.fromDateTime(DateTime.utc(year, month, day + n));

  /// 0 = Monday ... 6 = Sunday (same numbering as the backend `byweekday`).
  int get weekday0 => DateTime.utc(year, month, day).weekday - 1;

  tz.TZDateTime startOf(tz.Location loc) => tz.TZDateTime(loc, year, month, day);

  /// The next local midnight (exclusive end of this day). 23 or 25 hours after [startOf] on DST days.
  tz.TZDateTime endExclusive(tz.Location loc) => addDays(1).startOf(loc);

  bool isBefore(LocalDate o) => compareTo(o) < 0;
  bool isAfter(LocalDate o) => compareTo(o) > 0;

  @override
  int compareTo(LocalDate other) {
    if (year != other.year) return year.compareTo(other.year);
    if (month != other.month) return month.compareTo(other.month);
    return day.compareTo(other.day);
  }

  @override
  bool operator ==(Object other) =>
      other is LocalDate && other.year == year && other.month == month && other.day == day;

  @override
  int get hashCode => Object.hash(year, month, day);

  @override
  String toString() => toIso();
}

/// Wall-clock time of day without a date (`HH:mm`).
class LocalTime {
  const LocalTime(this.hour, this.minute);

  /// Accepts `HH:mm` and `HH:mm:ss`.
  factory LocalTime.parse(String s) {
    final m = RegExp(r'^(\d{2}):(\d{2})(?::\d{2})?$').firstMatch(s);
    if (m == null) throw FormatException('Invalid local time', s);
    return LocalTime(int.parse(m.group(1)!), int.parse(m.group(2)!));
  }

  final int hour;
  final int minute;

  String format() => '${hour.toString().padLeft(2, '0')}:${minute.toString().padLeft(2, '0')}';

  /// Backend `time` JSON.
  String toJson() => '${format()}:00';

  @override
  bool operator ==(Object other) => other is LocalTime && other.hour == hour && other.minute == minute;

  @override
  int get hashCode => Object.hash(hour, minute);

  @override
  String toString() => format();
}

/// Converts the wall-clock time [hour]:[minute] on [d] in [loc] to a UTC instant.
///
/// DST rules (match the backend, tasks spec §7.4): a time that does not exist (spring-forward gap) shifts forward
/// by the gap (03:30 -> 04:30); an ambiguous time (fall-back) takes its first occurrence.
DateTime localToUtc(LocalDate d, int hour, int minute, tz.Location loc) {
  final wall = DateTime.utc(d.year, d.month, d.day, hour, minute);
  Duration offsetAt(DateTime utc) => tz.TZDateTime.from(utc, loc).timeZoneOffset;

  final before = offsetAt(wall.subtract(const Duration(days: 1)));
  final after = offsetAt(wall.add(const Duration(days: 1)));
  final candidates = <DateTime>[];
  for (final o in <Duration>{before, after}) {
    final utc = wall.subtract(o);
    if (offsetAt(utc) == o) candidates.add(utc);
  }
  if (candidates.isEmpty) return wall.subtract(before); // inside the gap
  return candidates.reduce((a, b) => a.isBefore(b) ? a : b);
}

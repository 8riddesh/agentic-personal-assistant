import 'package:timezone/timezone.dart' as tz;

import 'local_date.dart';

const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
const _weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

String twoDigits(int n) => n.toString().padLeft(2, '0');

/// `HH:mm` (24 h) of the instant [utc] in [loc].
String formatHm(DateTime utc, tz.Location loc) {
  final l = tz.TZDateTime.from(utc, loc);
  return '${twoDigits(l.hour)}:${twoDigits(l.minute)}';
}

/// 0 = Monday ... 6 = Sunday.
String weekdayShort(int weekday0) => _weekdays[weekday0];

/// `Sun 8 Nov`.
String formatDayLabel(LocalDate d) => '${_weekdays[d.weekday0]} ${d.day} ${_months[d.month - 1]}';

/// `Tue 10:00` in [loc].
String formatWeekdayTime(DateTime utc, tz.Location loc) {
  final l = tz.TZDateTime.from(utc, loc);
  return '${_weekdays[l.weekday - 1]} ${formatHm(utc, loc)}';
}

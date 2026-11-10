import 'package:timezone/timezone.dart' as tz;

import '../../app_shell/domain/local_date.dart';

/// `(date, wall-clock time?, zone) -> UTC instant`; `null` time means "Anytime" (no reminders, no check).
///
/// A time inside the spring-forward gap shifts forward (03:30 -> 04:30); an ambiguous time takes its first
/// occurrence (spec §8.2). The result always lies in `[date.startOf, date.endExclusive)`.
DateTime? resolveStartAt(LocalDate date, LocalTime? time, tz.Location loc) {
  if (time == null) return null;
  return localToUtc(date, time.hour, time.minute, loc);
}

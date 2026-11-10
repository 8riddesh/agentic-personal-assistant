/// All time in the app comes from a [Clock] (never `DateTime.now()` in domain code) so rules are testable.
abstract interface class Clock {
  DateTime nowUtc();
}

class SystemClock implements Clock {
  const SystemClock();

  @override
  DateTime nowUtc() => DateTime.now().toUtc();
}

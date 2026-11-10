import 'dart:math';

final Random _defaultRandom = Random();

/// `min(2^attempt s, 16 s) + jitter(0..500 ms)` (app_shell spec §8.2). The retry interceptor calls it with
/// attempt = 1..4, i.e. ~2, 4, 8, 16 s.
Duration backoffDelay(int attempt, {Random? random}) {
  final capped = attempt < 0 ? 0 : (attempt > 10 ? 10 : attempt);
  final seconds = min(1 << capped, 16);
  final jitterMs = (random ?? _defaultRandom).nextInt(501);
  return Duration(seconds: seconds, milliseconds: jitterMs);
}

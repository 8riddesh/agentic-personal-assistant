import 'dart:math';

import 'package:daily_assistant/features/app_shell/domain/backoff.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('delay doubles per attempt and caps at 16 s (attempts 0..5)', () {
    const expectedSeconds = [1, 2, 4, 8, 16, 16];
    for (var attempt = 0; attempt < expectedSeconds.length; attempt++) {
      final d = backoffDelay(attempt, random: Random(7));
      final base = expectedSeconds[attempt] * 1000;
      expect(d.inMilliseconds, inInclusiveRange(base, base + 500), reason: 'attempt $attempt');
    }
  });

  test('jitter stays within 0..500 ms over many draws', () {
    final random = Random(1);
    for (var i = 0; i < 200; i++) {
      final d = backoffDelay(3, random: random);
      expect(d.inMilliseconds, inInclusiveRange(8000, 8500));
    }
  });

  test('retry schedule 1..4 is ~2, 4, 8, 16 s', () {
    final seconds = [for (var n = 1; n <= 4; n++) backoffDelay(n, random: Random(3)).inSeconds];
    expect(seconds, [2, 4, 8, 16]);
  });

  test('negative and huge attempts are clamped', () {
    expect(backoffDelay(-3, random: Random(1)).inSeconds, 1);
    expect(backoffDelay(500, random: Random(1)).inSeconds, 16);
  });
}

import 'package:daily_assistant/features/app_shell/domain/local_date.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/timezone.dart' as tz;

import '../../support/fakes.dart';

void main() {
  setUpAll(initTz);

  group('LocalDate', () {
    test('parse and format round-trip', () {
      final d = LocalDate.parse('2026-11-08');
      expect((d.year, d.month, d.day), (2026, 11, 8));
      expect(d.toIso(), '2026-11-08');
    });

    test('rejects malformed and impossible dates', () {
      for (final bad in ['2026-1-8', '2026-02-30', 'tomorrow', '']) {
        expect(() => LocalDate.parse(bad), throwsFormatException, reason: bad);
      }
    });

    test('addDays crosses month and year boundaries', () {
      expect(LocalDate.parse('2026-12-31').addDays(1).toIso(), '2027-01-01');
      expect(LocalDate.parse('2026-03-01').addDays(-1).toIso(), '2026-02-28');
    });

    test('weekday0 is Monday-based', () {
      expect(LocalDate.parse('2026-11-09').weekday0, 0); // Monday
      expect(LocalDate.parse('2026-11-15').weekday0, 6); // Sunday
    });

    test('ordering and equality', () {
      expect(LocalDate.parse('2026-11-08').compareTo(LocalDate.parse('2026-11-09')), lessThan(0));
      expect(LocalDate.parse('2026-11-08'), LocalDate(2026, 11, 8));
    });

    test('fromTz uses the zone (22:30Z is already tomorrow in Bucharest)', () {
      final instant = DateTime.utc(2026, 11, 8, 22, 30);
      expect(LocalDate.fromTz(instant, utc).toIso(), '2026-11-08');
      expect(LocalDate.fromTz(instant, bucharest).toIso(), '2026-11-09');
    });

    test('endExclusive spans 25 h on the DST end day and 23 h on the DST start day', () {
      final fallBack = LocalDate.parse('2026-10-25');
      expect(fallBack.endExclusive(bucharest).difference(fallBack.startOf(bucharest)), const Duration(hours: 25));
      final springForward = LocalDate.parse('2027-03-28');
      expect(
        springForward.endExclusive(bucharest).difference(springForward.startOf(bucharest)),
        const Duration(hours: 23),
      );
    });

    test('endExclusive is the next local midnight', () {
      final d = LocalDate.parse('2026-11-09');
      expect(d.endExclusive(bucharest).toUtc(), DateTime.utc(2026, 11, 9, 22));
    });
  });

  group('LocalTime', () {
    test('parse HH:mm and HH:mm:ss, format and JSON', () {
      expect(LocalTime.parse('09:05').format(), '09:05');
      expect(LocalTime.parse('18:00:00').toJson(), '18:00:00');
      expect(() => LocalTime.parse('9:00'), throwsFormatException);
    });
  });

  group('localToUtc', () {
    test('normal time', () {
      expect(localToUtc(LocalDate.parse('2026-11-09'), 10, 0, bucharest), DateTime.utc(2026, 11, 9, 8));
    });

    test('spring-forward gap shifts forward: 03:30 -> 04:30 EEST (01:30Z)', () {
      expect(localToUtc(LocalDate.parse('2027-03-28'), 3, 30, bucharest), DateTime.utc(2027, 3, 28, 1, 30));
    });

    test('fall-back ambiguity takes the first occurrence: 03:30 EEST (00:30Z)', () {
      expect(localToUtc(LocalDate.parse('2026-10-25'), 3, 30, bucharest), DateTime.utc(2026, 10, 25, 0, 30));
    });

    test('UTC zone is the identity', () {
      expect(localToUtc(LocalDate.parse('2026-11-09'), 10, 15, tz.UTC), DateTime.utc(2026, 11, 9, 10, 15));
    });
  });
}

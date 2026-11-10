import 'dart:convert';

import 'package:daily_assistant/features/notifications/domain/notification_ids.dart';
import 'package:daily_assistant/features/notifications/domain/notification_payload.dart';
import 'package:daily_assistant/features/notifications/domain/notification_texts.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('fnv1a32', () {
    test('matches the published FNV-1a test vectors', () {
      expect(fnv1a32(''), 0x811C9DC5);
      expect(fnv1a32('a'), 0xE40C292C);
      expect(fnv1a32('foobar'), 0xBF9CF968);
    });

    test('hashes UTF-8 bytes, so non-ASCII ids are stable', () {
      expect(fnv1a32('café'), fnv1a32('café'));
      expect(fnv1a32('café'), isNot(fnv1a32('cafe')));
    });
  });

  group('ids', () {
    test('every slot id of a task is distinct, consecutive and fits an Android int', () {
      final ids = [for (final s in NotificationSlot.values) notificationId('task-1', s)];
      expect(ids.toSet(), hasLength(4));
      expect(ids[1] - ids[0], 1);
      expect(ids.every((id) => id >= 0 && id < (1 << 30)), isTrue);
    });

    test('idFromBase is base * 4 + slot', () {
      expect(idFromBase(10, NotificationSlot.check), 42);
    });

    test('assignBases does not depend on input order and resolves collisions by probing', () {
      final forward = assignBases(['b', 'a', 'c'], hasher: (_) => 7);
      final backward = assignBases(['c', 'a', 'b'], hasher: (_) => 7);
      expect(forward, backward);
      expect(forward.values.toSet(), hasLength(3));
      expect(forward['a'], 7); // the smallest id keeps its natural base
    });

    test('duplicate ids collapse', () {
      expect(assignBases(['a', 'a']).keys, ['a']);
    });
  });

  group('payload', () {
    NotificationPayload sample({String title = 'Write report'}) => NotificationPayload(
          taskId: 't1',
          slot: NotificationSlot.check,
          fireAtUtc: DateTime.utc(2026, 11, 9, 15, 10),
          date: '2026-11-09',
          hash: 'abc123',
          title: title,
          startAtUtc: DateTime.utc(2026, 11, 9, 14),
        );

    test('round-trips', () {
      final decoded = NotificationPayload.decode(sample().encode())!;
      expect(decoded.taskId, 't1');
      expect(decoded.slot, NotificationSlot.check);
      expect(decoded.fireAtUtc, DateTime.utc(2026, 11, 9, 15, 10));
      expect(decoded.startAtUtc, DateTime.utc(2026, 11, 9, 14));
      expect((decoded.date, decoded.hash, decoded.title), ('2026-11-09', 'abc123', 'Write report'));
    });

    test('long titles are truncated so the payload stays small', () {
      final decoded = NotificationPayload.decode(sample(title: 'x' * 500).encode())!;
      expect(decoded.title.length, NotificationPayload.maxTitleLength);
    });

    test('garbage, unknown versions and bad slots decode to null', () {
      expect(NotificationPayload.decode(null), isNull);
      expect(NotificationPayload.decode(''), isNull);
      expect(NotificationPayload.decode('not json'), isNull);
      expect(NotificationPayload.decode('[1,2]'), isNull);
      final json = jsonDecode(sample().encode()) as Map<String, dynamic>;
      expect(NotificationPayload.decode(jsonEncode({...json, 'v': 99})), isNull);
      expect(NotificationPayload.decode(jsonEncode({...json, 's': 9})), isNull);
      expect(NotificationPayload.decode(jsonEncode({...json, 't': 5})), isNull);
    });

    test('startAt is optional', () {
      final p = NotificationPayload(
        taskId: 't',
        slot: NotificationSlot.reminder1,
        fireAtUtc: DateTime.utc(2026, 1, 1),
        date: '2026-01-01',
        hash: 'h',
        title: 'x',
      );
      expect(NotificationPayload.decode(p.encode())!.startAtUtc, isNull);
    });
  });

  group('texts', () {
    const texts = NotificationTexts();

    test('offsetLabel', () {
      expect(texts.offsetLabel(60), '1 hour');
      expect(texts.offsetLabel(120), '2 hours');
      expect(texts.offsetLabel(30), '30 min');
      expect(texts.offsetLabel(90), '90 min');
    });

    test('reminder: only the first one mentions the predicted end', () {
      final first = texts.reminder(offsetMin: 60, taskTitle: 'Gym', startHm: '18:00', endHm: '19:10', first: true);
      expect(first.title, 'In 1 hour: Gym');
      expect(first.body, 'Starts at 18:00 · ends ~19:10');
      final second = texts.reminder(offsetMin: 30, taskTitle: 'Gym', startHm: '18:00', endHm: '19:10');
      expect(second.body, 'Starts at 18:00');
    });

    test('check, follow-up and finish question', () {
      expect(texts.check(taskTitle: 'Gym', predictedHm: '19:10').title, 'Done with Gym?');
      expect(texts.followUp(taskTitle: 'Gym', fireHm: '19:40').body, 'You asked to be checked at 19:40.');
      expect(texts.finishQuestion(taskTitle: 'Gym').title, 'When did you finish Gym?');
    });
  });
}

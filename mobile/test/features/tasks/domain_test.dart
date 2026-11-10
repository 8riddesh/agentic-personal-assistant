import 'package:daily_assistant/features/app_shell/domain/local_date.dart';
import 'package:daily_assistant/features/tasks/domain/entities.dart';
import 'package:daily_assistant/features/tasks/domain/override_rule.dart';
import 'package:daily_assistant/features/tasks/domain/start_at_resolver.dart';
import 'package:daily_assistant/features/tasks/domain/status_change.dart';
import 'package:daily_assistant/features/tasks/domain/task_draft_validator.dart';
import 'package:daily_assistant/features/tasks/domain/today_sorter.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fakes.dart';

void main() {
  setUpAll(initTz);

  final openDay = LocalDate.parse('2026-11-09');

  TaskDraft draft({
    String title = 'Write report',
    String category = 'Work',
    LocalDate? date,
    int? estimate,
    bool? recurring = false,
    Recurrence? recurrence,
    String? notes,
  }) =>
      TaskDraft(
        title: title,
        category: category,
        localDate: date ?? openDay,
        estimateMin: estimate,
        isRecurring: recurring,
        recurrence: recurrence,
        notes: notes,
      );

  group('validateTaskDraft', () {
    test('a valid one-time draft has no errors', () {
      expect(validateTaskDraft(draft(), openDay: openDay), isEmpty);
    });

    test('title: blank and 201 characters are rejected, 200 is fine', () {
      expect(validateTaskDraft(draft(title: '   '), openDay: openDay), contains(DraftField.title));
      expect(validateTaskDraft(draft(title: 'x' * 201), openDay: openDay), contains(DraftField.title));
      expect(validateTaskDraft(draft(title: 'x' * 200), openDay: openDay), isEmpty);
    });

    test('category: blank and over 32 characters are rejected', () {
      expect(validateTaskDraft(draft(category: ''), openDay: openDay), contains(DraftField.category));
      expect(validateTaskDraft(draft(category: 'c' * 33), openDay: openDay), contains(DraftField.category));
    });

    test('estimate bounds 5..720', () {
      for (final bad in [4, 721]) {
        expect(validateTaskDraft(draft(estimate: bad), openDay: openDay), contains(DraftField.estimate), reason: '$bad');
      }
      for (final good in [5, 720]) {
        expect(validateTaskDraft(draft(estimate: good), openDay: openDay), isEmpty, reason: '$good');
      }
    });

    test('recurring unanswered is an error', () {
      expect(validateTaskDraft(draft(recurring: null), openDay: openDay), contains(DraftField.recurring));
    });

    test('recurring needs a recurrence; weekly needs at least one weekday', () {
      expect(validateTaskDraft(draft(recurring: true), openDay: openDay), contains(DraftField.recurrence));
      expect(
        validateTaskDraft(draft(recurring: true, recurrence: const Weekly({})), openDay: openDay),
        contains(DraftField.recurrence),
      );
      expect(validateTaskDraft(draft(recurring: true, recurrence: const Weekly({0, 2})), openDay: openDay), isEmpty);
      expect(validateTaskDraft(draft(recurring: true, recurrence: const Daily()), openDay: openDay), isEmpty);
    });

    test('date must be within the open day .. +60 days', () {
      expect(validateTaskDraft(draft(date: openDay.addDays(-1)), openDay: openDay), contains(DraftField.date));
      expect(validateTaskDraft(draft(date: openDay.addDays(61)), openDay: openDay), contains(DraftField.date));
      expect(validateTaskDraft(draft(date: openDay.addDays(60)), openDay: openDay), isEmpty);
    });

    test('notes up to 1000 characters', () {
      expect(validateTaskDraft(draft(notes: 'n' * 1001), openDay: openDay), contains(DraftField.notes));
      expect(validateTaskDraft(draft(notes: 'n' * 1000), openDay: openDay), isEmpty);
    });
  });

  group('TaskDraft JSON', () {
    test('weekly recurrence is sent as sorted byweekday (M-TASKS-AC-03)', () {
      final json = draft(recurring: true, recurrence: const Weekly({4, 0, 2})).toJson();
      expect(json['is_recurring'], true);
      expect(json['recurrence'], {'freq': 'weekly', 'byweekday': [0, 2, 4]});
      expect(json['local_date'], '2026-11-09');
    });

    test('a one-time draft carries no recurrence and no start_at when anytime', () {
      final json = draft().toJson();
      expect(json['is_recurring'], false);
      expect(json.containsKey('recurrence'), isFalse);
      expect(json.containsKey('start_at'), isFalse);
    });

    test('any field change changes the fingerprint (assessment invalidation)', () {
      final a = draft().fingerprint;
      expect(draft(title: 'Other').fingerprint, isNot(a));
      expect(draft(estimate: 30).fingerprint, isNot(a));
      expect(draft(recurring: true, recurrence: const Daily()).fingerprint, isNot(a));
      expect(draft().fingerprint, a);
    });
  });

  group('resolveStartAt', () {
    test('a normal time', () {
      expect(resolveStartAt(LocalDate.parse('2026-11-09'), const LocalTime(10, 0), bucharest), DateTime.utc(2026, 11, 9, 8));
    });

    test('spring-forward: 03:30 does not exist and becomes 04:30 local (01:30Z)', () {
      expect(resolveStartAt(LocalDate.parse('2027-03-28'), const LocalTime(3, 30), bucharest), DateTime.utc(2027, 3, 28, 1, 30));
    });

    test('fall-back: 03:30 picks the first occurrence (00:30Z)', () {
      expect(resolveStartAt(LocalDate.parse('2026-10-25'), const LocalTime(3, 30), bucharest), DateTime.utc(2026, 10, 25, 0, 30));
    });

    test('anytime resolves to null', () {
      expect(resolveStartAt(LocalDate.parse('2026-11-09'), null, bucharest), isNull);
    });

    test('the result lies inside the local day', () {
      final d = LocalDate.parse('2026-11-09');
      final start = resolveStartAt(d, const LocalTime(23, 59), bucharest)!;
      expect(start.isBefore(d.endExclusive(bucharest)), isTrue);
      expect(start.isBefore(d.startOf(bucharest)), isFalse);
    });
  });

  group('sectionTasks', () {
    test('planned: timed ascending, then anytime by title; terminal go to Finished', () {
      final tasks = [
        makeTask(id: 'z', title: 'Zebra'),
        makeTask(id: 'late', title: 'Late', startAt: DateTime.utc(2026, 11, 9, 15)),
        makeTask(id: 'a', title: 'apple'),
        makeTask(id: 'early', title: 'Early', startAt: DateTime.utc(2026, 11, 9, 9)),
        makeTask(id: 'done', title: 'Done', status: TaskStatus.completed, startAt: DateTime.utc(2026, 11, 9, 7)),
        makeTask(id: 'miss', title: 'Missed', status: TaskStatus.missed),
      ];
      final sections = sectionTasks(tasks);
      expect(sections.planned.map((t) => t.id), ['early', 'late', 'a', 'z']);
      expect(sections.finished.map((t) => t.id), ['done', 'miss']);
    });
  });

  test('override rule: go is not an override, caution and no_go are', () {
    expect(isOverride(Verdict.go), isFalse);
    expect(isOverride(Verdict.caution), isTrue);
    expect(isOverride(Verdict.noGo), isTrue);
  });

  group('validateStatusChange', () {
    final now = DateTime.utc(2026, 11, 9, 12);
    final timed = makeTask(startAt: DateTime.utc(2026, 11, 9, 10));

    test('completed: finished before the start is rejected', () {
      expect(validateStatusChange(Completed(finishedAt: DateTime.utc(2026, 11, 9, 9)), timed, now), isNotNull);
    });

    test('completed: finishing right at the start is rejected, after it is fine', () {
      expect(validateStatusChange(Completed(finishedAt: DateTime.utc(2026, 11, 9, 10)), timed, now), isNotNull);
      expect(validateStatusChange(Completed(finishedAt: DateTime.utc(2026, 11, 9, 11)), timed, now), isNull);
    });

    test('completed: the future is rejected; "now" is fine; anytime tasks have no lower bound', () {
      expect(validateStatusChange(Completed(finishedAt: DateTime.utc(2026, 11, 9, 13)), timed, now), isNotNull);
      expect(validateStatusChange(const Completed(), timed, now), isNull);
      expect(validateStatusChange(Completed(finishedAt: DateTime.utc(2026, 11, 9, 1)), makeTask(), now), isNull);
    });

    test('postponed: a time in the past is rejected', () {
      expect(validateStatusChange(Postponed(DateTime.utc(2026, 11, 9, 11)), timed, now), isNotNull);
      expect(validateStatusChange(Postponed(DateTime.utc(2026, 11, 10, 9)), timed, now), isNull);
    });

    test('postponed: the same start is rejected', () {
      final future = makeTask(startAt: DateTime.utc(2026, 11, 10, 9));
      expect(validateStatusChange(Postponed(DateTime.utc(2026, 11, 10, 9)), future, now), isNotNull);
    });

    test("can't do: a blank reason is rejected, a reason is fine, over 500 chars is rejected", () {
      expect(validateStatusChange(const CantDo('   '), timed, now), isNotNull);
      expect(validateStatusChange(const CantDo('sick'), timed, now), isNull);
      expect(validateStatusChange(CantDo('x' * 501), timed, now), isNotNull);
    });

    test('cancelled: reason is optional', () {
      expect(validateStatusChange(const Cancelled(), timed, now), isNull);
      expect(validateStatusChange(const Cancelled(reason: 'no longer needed'), timed, now), isNull);
    });
  });

  group('StatusChange JSON', () {
    test('completed / postponed / cancelled / cant_do bodies', () {
      expect(Completed(finishedAt: DateTime.utc(2026, 11, 9, 11)).toJson(), {
        'status': 'completed',
        'finished_at': '2026-11-09T11:00:00.000Z',
        'source': 'app',
      });
      expect(const Completed().toJson().containsKey('finished_at'), isFalse);
      expect(Postponed(DateTime.utc(2026, 11, 10, 9)).toJson(), {
        'status': 'postponed',
        'new_start_at': '2026-11-10T09:00:00.000Z',
        'source': 'app',
      });
      expect(const Cancelled(reason: ' x ').toJson(), {'status': 'cancelled', 'reason': 'x', 'source': 'app'});
      expect(const Cancelled().toJson().containsKey('reason'), isFalse);
      expect(const CantDo(' sick ').toJson(), {'status': 'cant_do', 'reason': 'sick', 'source': 'app'});
    });
  });

  group('Recurrence', () {
    test('summaries and equality', () {
      expect(const Daily().summary, 'Repeats every day');
      expect(const Weekly({4, 0, 2}).summary, 'Repeats Mon, Wed, Fri');
      expect(const Weekly({0, 2}), const Weekly({2, 0}));
      expect(const Weekly({0}), isNot(const Weekly({1})));
    });

    test('JSON round trip', () {
      expect(Recurrence.fromJson({'freq': 'daily'}), const Daily());
      expect(Recurrence.fromJson({'freq': 'weekly', 'byweekday': [0, 2, 4]}), const Weekly({0, 2, 4}));
      expect(() => Recurrence.fromJson({'freq': 'monthly'}), throwsFormatException);
    });
  });
}

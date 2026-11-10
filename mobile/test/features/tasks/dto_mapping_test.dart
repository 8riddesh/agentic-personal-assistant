import 'package:daily_assistant/features/app_shell/domain/local_date.dart';
import 'package:daily_assistant/features/tasks/data/dto/dtos.dart';
import 'package:daily_assistant/features/tasks/domain/entities.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fakes.dart';

void main() {
  group('enums', () {
    test('every status value maps both ways (cant_do)', () {
      for (final s in TaskStatus.values) {
        expect(TaskStatus.parse(s.json), s);
      }
      expect(TaskStatus.cantDo.json, 'cant_do');
      expect(TaskStatus.parse('cant_do'), TaskStatus.cantDo);
      expect(() => TaskStatus.parse('weird'), throwsFormatException);
    });

    test('verdict no_go and check response not_yet', () {
      expect(Verdict.parse('no_go'), Verdict.noGo);
      expect(Verdict.noGo.json, 'no_go');
      expect(CheckResponse.parse('not_yet'), CheckResponse.notYet);
      expect(CheckResponse.parse('done'), CheckResponse.done);
    });

    test('recommended action, day state, created via', () {
      for (final a in ['proceed', 'reschedule', 'split', 'shorten', 'drop']) {
        expect(RecommendedAction.parse(a).name, a);
      }
      for (final s in ['open', 'closing', 'closed']) {
        expect(DayState.parse(s).name, s);
      }
      for (final v in ['form', 'chat', 'template']) {
        expect(CreatedVia.parse(v).name, v);
      }
    });
  });

  group('task', () {
    test('parses a TaskDTO as the backend sends it', () {
      final t = taskFromJson(taskJson(
        startAt: '2026-11-09T17:00:00Z',
        predictedEndAt: '2026-11-09T18:10:00Z',
        checkResponse: 'not_yet',
        originTemplateId: 'tpl-1',
      ));
      expect(t.localDate, LocalDate.parse('2026-11-09'));
      expect(t.startAt, DateTime.utc(2026, 11, 9, 17));
      expect(t.predictedEndAt, DateTime.utc(2026, 11, 9, 18, 10));
      expect(t.checkResponse, CheckResponse.notYet);
      expect(t.isRecurring, isTrue);
      expect(t.isTimed, isTrue);
      expect(t.isTerminal, isFalse);
    });

    test('anytime task: no start, not terminal', () {
      final t = taskFromJson(taskJson());
      expect(t.startAt, isNull);
      expect(t.isTimed, isFalse);
    });

    test('toJson/fromJson round trip keeps every field incl. cant_do and pending status', () {
      final original = makeTask(
        status: TaskStatus.cantDo,
        startAt: DateTime.utc(2026, 11, 9, 9),
        pendingStatus: 'cant_do',
      );
      final copy = taskFromJson(taskToJson(original));
      expect(copy.status, TaskStatus.cantDo);
      expect(copy.pendingStatus, 'cant_do');
      expect(copy.startAt, original.startAt);
      expect(copy.title, original.title);
    });

    test('taskFromResponse unwraps {task, template, replayed}', () {
      final t = taskFromResponse({'task': taskJson(id: 'wrapped'), 'template': null, 'replayed': false});
      expect(t.id, 'wrapped');
      expect(taskFromResponse(taskJson(id: 'bare')).id, 'bare');
    });

    test('unknown status is a FormatException, not a silent default', () {
      expect(() => taskFromJson(taskJson(status: 'exploded')), throwsFormatException);
    });
  });

  group('day / assessment / template', () {
    test('day', () {
      final d = dayFromJson(dayJson(state: 'closed'));
      expect(d.state, DayState.closed);
      expect(d.isOpen, isFalse);
      expect(d.closeMode, 'user');
      expect(dayFromJson(dayToJson(d)).localDate, d.localDate);
    });

    test('assessment', () {
      final a = assessmentFromJson({
        'assessment_id': 'a1',
        'verdict': 'no_go',
        'score': 0.31,
        'feasible_noul': 0.2,
        'recommended_action': 'shorten',
        'suggestion': 'Make it shorter.',
        'predicted_end_at': '2026-11-09T15:10:00Z',
        'engine': 'groq_fallback',
        'degraded': true,
      });
      expect(a.verdict, Verdict.noGo);
      expect(a.recommendedAction, RecommendedAction.shorten);
      expect(a.degraded, isTrue);
      expect(a.predictedEndAt, DateTime.utc(2026, 11, 9, 15, 10));
    });

    test('template with weekly recurrence and start time', () {
      final t = templateFromJson({
        'id': 'tpl',
        'title': 'Gym',
        'notes': null,
        'category': 'Health',
        'start_local': '18:00:00',
        'recurrence': {'freq': 'weekly', 'byweekday': [0, 2, 4]},
        'default_estimate_min': 60,
        'starts_on': '2026-11-09',
        'active': true,
      });
      expect(t.startLocal, const LocalTime(18, 0));
      expect(t.recurrence, const Weekly({0, 2, 4}));
      expect(t.copyWith(active: false).active, isFalse);
    });

    test('template without start time is anytime', () {
      final t = templateFromJson({
        'id': 'tpl',
        'title': 'Read',
        'category': 'Learning',
        'start_local': null,
        'recurrence': {'freq': 'daily'},
        'active': false,
      });
      expect(t.startLocal, isNull);
      expect(t.recurrence, const Daily());
      expect(t.active, isFalse);
    });
  });
}

// Parses REAL backend responses (recorded by backend/scripts/export_mobile_fixtures.py) with the app's DTOs and
// feeds the real request bodies of the Dart code to the same scenario. A backend change that breaks the app fails
// here instead of crashing on a phone.
import 'dart:convert';
import 'dart:io';

import 'package:daily_assistant/features/app_shell/data/auth_api.dart';
import 'package:daily_assistant/features/app_shell/data/problem_mapper.dart';
import 'package:daily_assistant/features/app_shell/domain/app_error.dart';
import 'package:daily_assistant/features/app_shell/domain/app_settings.dart';
import 'package:daily_assistant/features/app_shell/domain/local_date.dart';
import 'package:daily_assistant/features/tasks/data/dto/dtos.dart';
import 'package:daily_assistant/features/tasks/domain/entities.dart';
import 'package:daily_assistant/features/tasks/domain/status_change.dart' as change;
import 'package:flutter_test/flutter_test.dart';

late Map<String, dynamic> fx;

Map<String, dynamic> body(String name) => (fx[name]['body'] as Map).cast<String, dynamic>();
int status(String name) => fx[name]['status'] as int;

void main() {
  setUpAll(() {
    final file = File('test/fixtures/backend_responses.json');
    expect(file.existsSync(), isTrue, reason: 'run backend/scripts/export_mobile_fixtures.py');
    fx = (jsonDecode(file.readAsStringSync()) as Map).cast<String, dynamic>();
  });

  group('auth + settings', () {
    test('login response', () {
      final result = LoginResult.fromJson(body('login'));
      expect(result.accessToken, isNotEmpty);
      expect(result.expiresAt, DateTime.utc(2026, 12, 9, 8)); // 30 days after the fixed clock
    });

    test('settings: the device timezone sent at login was applied and confirmed', () {
      final s = AppSettings.fromJson(body('settings'));
      expect(s.timezone, 'Europe/Bucharest');
      expect(s.timezoneConfirmed, isTrue);
      expect(s.reminderOffsetsMin, [60, 30]);
      expect(s.reportEmail, isNull);
      expect(s.weekStart, 1);
    });

    test('wrong password is a 401 the app maps to UnauthorizedError', () {
      expect(status('login_wrong_password'), 401);
      expect(mapProblem(401, body('login_wrong_password')), isA<UnauthorizedError>());
      expect(body('login_wrong_password')['code'], 'invalid_credentials');
    });

    test('a missing token is a 401 as well', () {
      expect(mapProblem(status('unauthorized'), body('unauthorized')), isA<UnauthorizedError>());
    });
  });

  group('days', () {
    test('GET /days/current', () {
      final day = dayFromJson(body('day_current'));
      expect(day.localDate, const LocalDate(2026, 11, 9)); // Bucharest: 10:00 on Monday
      expect(day.state, DayState.open);
      expect(day.closedAt, isNull);
      expect(day.dailyReportId, isNull);
    });

    test('after EOD the day is closed with a close mode', () {
      final day = dayFromJson(body('day_after_close'));
      expect(day.state, DayState.closed);
      expect(day.closeMode, 'user');
      expect(day.closedAt, isNotNull);
    });

    test('POST /days/current/close answers 202 then 200 (idempotent)', () {
      expect(status('close_day'), 202);
      expect(body('close_day')['state'], 'closing');
      expect(body('close_day')['missed_count'], isA<int>());
      expect(status('close_again'), 200);
      expect(body('close_again')['already_closed'], isTrue);
    });

    test('GET /days/current/unresolved lists the still-planned tasks', () {
      final json = body('unresolved');
      expect(json['local_date'], '2026-11-09');
      final tasks = (json['tasks'] as List).map(taskFromJson).toList();
      expect(tasks, isNotEmpty);
      expect(tasks.every((t) => t.status == TaskStatus.planned), isTrue);
    });
  });

  group('tasks', () {
    test('POST /tasks returns {task, template, replayed}; one-time timed task', () {
      expect(status('create_timed_task'), 201);
      final json = body('create_timed_task');
      expect(json['template'], isNull);
      expect(json['replayed'], isFalse);
      final task = taskFromResponse(json);
      expect(task.title, 'Write report');
      expect(task.category, 'Work'); // normalised by the server from "work"
      expect(task.status, TaskStatus.planned);
      expect(task.startAt, DateTime.utc(2026, 11, 9, 7));
      expect(task.estimateMin, 60);
      expect(task.localDate, const LocalDate(2026, 11, 9));
      expect(task.isRecurring, isFalse);
      expect(task.createdVia, CreatedVia.form);
      expect(task.predictedEndAt, isNull); // no predictor in M1
    });

    test('idempotent replay of the same client_request_id is a 200', () {
      expect(status('create_replay'), 200);
      expect(body('create_replay')['replayed'], isTrue);
      expect(taskFromResponse(body('create_replay')).id, taskFromResponse(body('create_timed_task')).id);
    });

    test('recurring task comes with its template', () {
      final json = body('create_recurring_task');
      final task = taskFromResponse(json);
      expect(task.isRecurring, isTrue);
      expect(task.templateId, isNotNull);
      final template = templateFromJson(json['template']);
      expect(template.recurrence, const Weekly({0, 2, 4}));
      expect(template.startsOn, const LocalDate(2026, 11, 9));
      expect(template.active, isTrue);
      expect(template.defaultEstimateMin, 45);
    });

    test('anytime task has no start', () {
      expect(taskFromResponse(body('create_anytime_task')).startAt, isNull);
    });

    test('GET /tasks?date= is a list of tasks', () {
      final list = fx['tasks_today']['body'] as List;
      final tasks = list.map(taskFromJson).toList();
      expect(tasks.length, 6);
      expect(tasks.map((t) => t.title), containsAll(['Write report', 'Gym', 'Read']));
    });

    test('PATCH /tasks/{id} returns a bare task', () {
      final task = taskFromJson(body('patch_task'));
      expect((task.title, task.estimateMin), ('Read paper', 30));
    });

    test('GET /templates', () {
      final templates = (fx['templates']['body'] as List).map(templateFromJson).toList();
      expect(templates.single.title, 'Gym');
    });
  });

  group('status changes', () {
    test('completed: the app sends finished_at/source and gets a completed task', () {
      final sent = const change.Completed(finishedAt: null).toJson();
      expect(sent.keys, containsAll(['status', 'source']));
      final task = taskFromResponse(body('status_completed'));
      expect(task.status, TaskStatus.completed);
      expect(task.actualEndAt, DateTime.utc(2026, 11, 9, 7, 50));
    });

    test('cancelled and cant_do keep their reasons', () {
      expect(taskFromResponse(body('status_cancelled')).statusReason, 'not needed');
      final cantDo = taskFromResponse(body('status_cant_do'));
      expect((cantDo.status, cantDo.statusReason), (TaskStatus.cantDo, 'clinic closed'));
    });

    test('postponed: the original links to the new copy, which is a planned task on the new day', () {
      final json = body('status_postponed');
      final original = taskFromJson(json['task']);
      final copy = taskFromJson(json['created_task']);
      expect(original.status, TaskStatus.postponed);
      expect(original.postponedToTaskId, copy.id);
      expect(copy.status, TaskStatus.planned);
      expect(copy.localDate, const LocalDate(2026, 11, 10));
      expect(copy.startAt, DateTime.utc(2026, 11, 10, 9));
    });

    test('the Dart request bodies use the field names the backend accepts', () {
      // (same shapes as the recorded requests that the backend answered with 200)
      expect(change.Postponed(DateTime.utc(2026, 11, 10, 9)).toJson(source: 'eod'), {
        'status': 'postponed',
        'new_start_at': '2026-11-10T09:00:00.000Z',
        'source': 'eod',
      });
      expect(const change.CantDo('clinic closed').toJson(), {
        'status': 'cant_do',
        'reason': 'clinic closed',
        'source': 'app',
      });
      expect(const change.Cancelled(reason: ' not needed ').toJson(), {
        'status': 'cancelled',
        'reason': 'not needed',
        'source': 'app',
      });
    });
  });

  group('errors', () {
    test('409 invalid transition carries the code the UI switches on', () {
      expect(status('status_invalid_transition'), 409);
      final error = mapProblem(409, body('status_invalid_transition'));
      expect(error, isA<ConflictError>());
      expect((error as ConflictError).code, 'task.invalid_transition');
    });

    test('409 no completion check for an anytime task', () {
      final error = mapProblem(409, body('check_response_not_yet')) as ConflictError;
      expect(error.code, 'task.no_check');
    });

    test('422 validation problem: field errors by field name, no echoed input', () {
      final json = body('validation_error');
      expect(status('validation_error'), 422);
      expect(json['code'], 'validation_failed');
      final error = mapProblem(422, json) as ValidationError;
      expect(error.fieldErrors.keys, contains('is_recurring'));
    });
  });
}

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:daily_assistant/features/app_shell/data/api_client.dart';
import 'package:daily_assistant/features/app_shell/data/app_config.dart';
import 'package:daily_assistant/features/app_shell/data/interceptors/waking_interceptor.dart';
import 'package:daily_assistant/features/app_shell/data/kv_store.dart';
import 'package:daily_assistant/features/app_shell/data/token_store.dart';
import 'package:daily_assistant/features/app_shell/domain/auth_state.dart';
import 'package:daily_assistant/features/app_shell/domain/clock.dart';
import 'package:daily_assistant/features/app_shell/domain/local_date.dart';
import 'package:daily_assistant/features/app_shell/presentation/providers.dart';
import 'package:daily_assistant/features/notifications/domain/notification_planner.dart';
import 'package:daily_assistant/features/notifications/domain/notifications_gateway.dart';
import 'package:daily_assistant/features/notifications/domain/reconcile_diff.dart';
import 'package:daily_assistant/features/tasks/domain/entities.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/data/latest.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;

bool _tzReady = false;

/// Loads the tz database once per test isolate.
void initTz() {
  if (_tzReady) return;
  tz_data.initializeTimeZones();
  _tzReady = true;
}

tz.Location get bucharest {
  initTz();
  return tz.getLocation('Europe/Bucharest');
}

tz.Location get utc {
  initTz();
  return tz.getLocation('UTC');
}

final AppConfig testConfig = AppConfig.parse('https://api.test');

class FakeClock implements Clock {
  FakeClock(this.now);

  DateTime now;

  @override
  DateTime nowUtc() => now;

  void advance(Duration d) => now = now.add(d);
}

class ApiCall {
  ApiCall(this.method, this.path, {this.body, this.query, this.idempotencyKey});

  final String method;
  final String path;
  final Object? body;
  final Map<String, dynamic>? query;
  final String? idempotencyKey;

  @override
  String toString() => '$method $path';
}

/// Scripted [ApiClient]: handlers are keyed `"GET /path"` and return the raw JSON (or throw an AppError).
class FakeApiClient implements ApiClient {
  FakeApiClient([Map<String, FutureOr<Object?> Function(ApiCall call)>? handlers]) : handlers = handlers ?? {};

  final Map<String, FutureOr<Object?> Function(ApiCall call)> handlers;
  final List<ApiCall> calls = [];

  Iterable<ApiCall> callsTo(String method, String path) => calls.where((c) => c.method == method && c.path == path);

  Future<T> _handle<T>(ApiCall call, T Function(Object? json) decode) async {
    calls.add(call);
    final handler = handlers['${call.method} ${call.path}'];
    if (handler == null) throw StateError('No handler for ${call.method} ${call.path}');
    return decode(await handler(call));
  }

  @override
  Future<T> get<T>(String path, {Map<String, dynamic>? query, required T Function(Object? json) decode}) =>
      _handle(ApiCall('GET', path, query: query), decode);

  @override
  Future<T> post<T>(
    String path, {
    Object? body,
    String? idempotencyKey,
    bool retryable = false,
    required T Function(Object? json) decode,
  }) =>
      _handle(ApiCall('POST', path, body: body, idempotencyKey: idempotencyKey), decode);

  @override
  Future<T> put<T>(String path, {Object? body, required T Function(Object? json) decode}) =>
      _handle(ApiCall('PUT', path, body: body), decode);

  @override
  Future<T> patch<T>(String path, {Object? body, required T Function(Object? json) decode}) =>
      _handle(ApiCall('PATCH', path, body: body), decode);

  @override
  Future<void> delete(String path) => _handle<void>(ApiCall('DELETE', path), (_) {});

  @override
  Future<Uint8List> getBytes(String path) => throw UnimplementedError();
}

/// Dio adapter that answers from a script, one entry per request (the last entry repeats).
class ScriptedAdapter implements HttpClientAdapter {
  ScriptedAdapter(this.script);

  final List<FutureOr<ResponseBody> Function(RequestOptions options)> script;
  final List<RequestOptions> requests = [];

  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    requests.add(options);
    final index = requests.length - 1 < script.length ? requests.length - 1 : script.length - 1;
    return script[index](options);
  }

  @override
  void close({bool force = false}) {}
}

ResponseBody jsonBody(String json, int status) =>
    ResponseBody.fromString(json, status, headers: {
      Headers.contentTypeHeader: [Headers.jsonContentType],
    });

FutureOr<ResponseBody> Function(RequestOptions) respond(int status, [String body = '{}']) =>
    (options) => jsonBody(body, status);

FutureOr<ResponseBody> Function(RequestOptions) failConnection() => (options) => throw DioException(
      requestOptions: options,
      type: DioExceptionType.connectionError,
      error: const SocketException('no route to host'),
    );

class RecordingSink implements ServerStatusSink {
  final List<ServerStatus> statuses = [];

  @override
  void report(ServerStatus status) => statuses.add(status);
}

/// Auth controller stuck in a given state (widget tests).
class FakeAuthController extends AuthController {
  FakeAuthController(this.initial);

  final AuthState initial;

  @override
  Future<AuthState> build() async => initial;
}

/// Provider overrides that keep a widget/controller test off the network and off the device.
List<Override> testOverrides({
  FakeApiClient? api,
  InMemoryKeyValueStore? kv,
  InMemorySecureKeyValue? secure,
  FakeClock? clock,
  tz.Location? location,
  String deviceTimezone = 'UTC',
  List<Override> extra = const [],
}) =>
    [
      appConfigProvider.overrideWithValue(testConfig),
      kvStoreProvider.overrideWithValue(kv ?? InMemoryKeyValueStore()),
      secureKvProvider.overrideWithValue(secure ?? InMemorySecureKeyValue()),
      clockProvider.overrideWithValue(clock ?? FakeClock(DateTime.utc(2026, 11, 9, 8))),
      apiClientProvider.overrideWithValue(api ?? FakeApiClient()),
      deviceTimezoneProvider.overrideWithValue(deviceTimezone),
      appLocationProvider.overrideWithValue(location ?? utc),
      ...extra,
    ];

Future<void> pumpScreen(WidgetTester tester, Widget screen, {List<Override> overrides = const []}) async {
  await tester.pumpWidget(ProviderScope(overrides: overrides, child: MaterialApp(home: screen)));
  await tester.pump();
}

Map<String, Object?> taskJson({
  String id = 't1',
  String localDate = '2026-11-09',
  String title = 'Write report',
  String status = 'planned',
  String? startAt,
  String? predictedEndAt,
  String category = 'Work',
  String? checkResponse,
  String? originTemplateId,
  String? statusReason,
}) =>
    {
      'id': id,
      'local_date': localDate,
      'template_id': originTemplateId,
      'origin_template_id': originTemplateId,
      'is_recurring': originTemplateId != null,
      'title': title,
      'notes': null,
      'category': category,
      'start_at': startAt,
      'estimate_min': 60,
      'predicted_end_at': predictedEndAt,
      'prediction_method': null,
      'actual_end_at': null,
      'actual_end_source': null,
      'status': status,
      'status_reason': statusReason,
      'postponed_to_task_id': null,
      'feasibility_id': null,
      'feasibility_overridden': false,
      'created_via': 'form',
      'check_response': checkResponse,
    };

Map<String, Object?> dayJson({String id = 'd1', String localDate = '2026-11-09', String state = 'open'}) => {
      'id': id,
      'local_date': localDate,
      'state': state,
      'opened_at': '2026-11-09T06:00:00Z',
      'closed_at': state == 'open' ? null : '2026-11-09T19:40:00Z',
      'close_mode': state == 'open' ? null : 'user',
      'daily_report_id': null,
      'weekly_report_id': null,
    };

Task makeTask({
  String id = 't1',
  String title = 'Write report',
  LocalDate localDate = const LocalDate(2026, 11, 9),
  TaskStatus status = TaskStatus.planned,
  DateTime? startAt,
  DateTime? predictedEndAt,
  CheckResponse? checkResponse,
  String? pendingStatus,
}) =>
    Task(
      id: id,
      localDate: localDate,
      title: title,
      category: 'Work',
      status: status,
      createdVia: CreatedVia.form,
      startAt: startAt,
      predictedEndAt: predictedEndAt,
      checkResponse: checkResponse,
      pendingStatus: pendingStatus,
    );

Day makeDay({DayState state = DayState.open, LocalDate localDate = const LocalDate(2026, 11, 9), String? dailyReportId}) => Day(
      id: 'd1',
      localDate: localDate,
      state: state,
      openedAt: DateTime.utc(2026, 11, 9, 6),
      closedAt: state == DayState.open ? null : DateTime.utc(2026, 11, 9, 19, 40),
      dailyReportId: dailyReportId,
    );

TodayState makeToday(List<Task> tasks, {Day? day, bool fromCache = false}) => TodayState(
      day: day ?? makeDay(),
      tasks: tasks,
      fetchedAt: DateTime.utc(2026, 11, 9, 8),
      fromCache: fromCache,
    );

/// Notifications gateway that records what reconcile does.
class FakeGateway implements NotificationsGateway {
  final List<DesiredNotification> scheduled = [];
  final List<int> cancelled = [];
  List<PendingNotification> pendingList = [];
  List<int> active = [];
  Set<int> failingIds = {};
  bool enabled = true;
  bool exact = true;
  int pendingCalls = 0;
  Duration latency = Duration.zero;
  bool cancelledAll = false;
  int permissionRequests = 0;

  @override
  Future<void> schedule(DesiredNotification notification) async {
    if (failingIds.contains(notification.id)) throw StateError('past instant');
    scheduled.add(notification);
    pendingList = [
      ...pendingList.where((p) => p.id != notification.id),
      PendingNotification(id: notification.id, payload: notification.payload),
    ];
  }

  @override
  Future<List<PendingNotification>> pending() async {
    pendingCalls++;
    if (latency > Duration.zero) await Future<void>.delayed(latency);
    return List.of(pendingList);
  }

  @override
  Future<List<int>> activeIds() async => List.of(active);

  @override
  Future<void> cancel(int id) async {
    cancelled.add(id);
    pendingList = pendingList.where((p) => p.id != id).toList();
    active = active.where((a) => a != id).toList();
  }

  @override
  Future<void> cancelAll() async {
    cancelledAll = true;
    pendingList = [];
    active = [];
  }

  @override
  Future<bool> areEnabled() async => enabled;

  @override
  Future<bool> canScheduleExact() async => exact;

  @override
  Future<bool> requestPermission() async {
    permissionRequests++;
    enabled = true;
    return true;
  }

  @override
  Future<void> requestExactAlarms() async {}
}

/// Convenience: a UTC instant from a Bucharest wall-clock time (EET/EEST aware).
DateTime bucharestTime(int y, int m, int d, int h, [int min = 0, int s = 0]) {
  final local = tz.TZDateTime(bucharest, y, m, d, h, min, s);
  return local.toUtc();
}

/// Lets queued microtasks and zero-delay timers run.
Future<void> settle() => pumpEventQueue();

/// A phone-sized, tall viewport so long lists / forms are fully on screen.
void useTallScreen(WidgetTester tester) {
  tester.view.physicalSize = const Size(800, 2000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

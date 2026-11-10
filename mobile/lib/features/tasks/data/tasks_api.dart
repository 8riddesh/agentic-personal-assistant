import '../../app_shell/data/api_client.dart';
import '../../app_shell/domain/local_date.dart';
import '../domain/entities.dart';
import 'dto/dtos.dart';

/// `/tasks…`, `/days…`, `/feasibility/assess`, `/templates…` (thin wrappers over [ApiClient]).
class TasksApi {
  TasksApi(this._api);

  final ApiClient _api;

  Future<List<Task>> list(LocalDate date) => _api.get(
        '/tasks',
        query: {'date': date.toIso()},
        decode: (json) => (json as List).map(taskFromJson).toList(),
      );

  Future<Task> create(Map<String, Object?> body) => _api.post('/tasks', body: body, decode: taskFromResponse);

  Future<Task> patch(String id, Map<String, Object?> body) =>
      _api.patch('/tasks/$id', body: body, decode: taskFromJson);

  Future<Task> setStatus(String id, Map<String, Object?> body, {String? idempotencyKey}) =>
      _api.post('/tasks/$id/status', body: body, idempotencyKey: idempotencyKey, decode: taskFromResponse);

  Future<Task> checkResponse(String id, Map<String, Object?> body) =>
      _api.post('/tasks/$id/check-response', body: body, decode: taskFromJson);
}

class DayApi {
  DayApi(this._api);

  final ApiClient _api;

  Future<Day> current() => _api.get('/days/current', decode: dayFromJson);

  Future<Day> day(LocalDate date) => _api.get('/days/${date.toIso()}', decode: dayFromJson);
}

class FeasibilityApi {
  FeasibilityApi(this._api);

  final ApiClient _api;

  Future<Assessment> assess(Map<String, Object?> body) =>
      _api.post('/feasibility/assess', body: body, retryable: true, decode: assessmentFromJson);
}

class TemplatesApi {
  TemplatesApi(this._api);

  final ApiClient _api;

  Future<List<Template>> list() =>
      _api.get('/templates', decode: (json) => (json as List).map(templateFromJson).toList());

  Future<Template> patch(String id, Map<String, Object?> body) =>
      _api.patch('/templates/$id', body: body, decode: templateFromJson);

  Future<void> delete(String id) => _api.delete('/templates/$id');
}

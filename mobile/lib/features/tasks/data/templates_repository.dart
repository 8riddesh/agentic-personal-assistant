import '../../app_shell/domain/local_date.dart';
import '../domain/entities.dart';
import 'tasks_api.dart';

/// Template management (`/templates`). Templates are created only through `POST /tasks` with `is_recurring`.
class TemplatesRepository {
  TemplatesRepository(this._api);

  final TemplatesApi _api;

  Future<List<Template>> list() => _api.list();

  Future<Template> setActive(String id, bool active) => _api.patch(id, {'active': active});

  Future<Template> update(
    String id, {
    String? title,
    String? notes,
    String? category,
    LocalTime? startLocal,
    bool clearStart = false,
    int? defaultEstimateMin,
    Recurrence? recurrence,
  }) =>
      _api.patch(id, {
        if (title != null) 'title': title,
        if (notes != null) 'notes': notes,
        if (category != null) 'category': category,
        if (startLocal != null) 'start_local': startLocal.toJson(),
        if (clearStart) 'start_local': null,
        if (defaultEstimateMin != null) 'default_estimate_min': defaultEstimateMin,
        if (recurrence != null) 'recurrence': recurrence.toJson(),
      });

  Future<void> delete(String id) => _api.delete(id);
}

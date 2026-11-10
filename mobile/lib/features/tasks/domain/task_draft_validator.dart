import '../../app_shell/domain/local_date.dart';
import 'entities.dart';

/// Field keys used in the error map (also the keys of backend `fieldErrors`).
abstract final class DraftField {
  static const title = 'title';
  static const category = 'category';
  static const date = 'date';
  static const estimate = 'estimate';
  static const notes = 'notes';
  static const recurring = 'recurring';
  static const recurrence = 'recurrence';
}

const int maxDaysAhead = 60;

/// Pure validation (spec §7.3). An empty map means the draft may be assessed.
Map<String, String> validateTaskDraft(TaskDraft d, {required LocalDate openDay}) {
  final errors = <String, String>{};

  final title = d.title.trim();
  if (title.isEmpty) {
    errors[DraftField.title] = 'Title is required';
  } else if (title.length > 200) {
    errors[DraftField.title] = 'Title is too long (max 200)';
  }

  final category = d.category.trim();
  if (category.isEmpty) {
    errors[DraftField.category] = 'Category is required';
  } else if (category.length > 32) {
    errors[DraftField.category] = 'Category is too long (max 32)';
  }

  if (d.localDate.isBefore(openDay) || d.localDate.isAfter(openDay.addDays(maxDaysAhead))) {
    errors[DraftField.date] = 'Pick a date within the next $maxDaysAhead days';
  }

  final est = d.estimateMin;
  if (est != null && (est < 5 || est > 720)) {
    errors[DraftField.estimate] = 'Estimate must be 5–720 minutes';
  }

  if (d.notes != null && d.notes!.length > 1000) {
    errors[DraftField.notes] = 'Notes are too long (max 1000)';
  }

  if (d.isRecurring == null) {
    errors[DraftField.recurring] = 'Choose one-time or recurring';
  } else if (d.isRecurring == true) {
    final r = d.recurrence;
    if (r == null) {
      errors[DraftField.recurrence] = 'Choose how often it repeats';
    } else if (r is Weekly && r.byWeekday.isEmpty) {
      errors[DraftField.recurrence] = 'Pick at least one weekday';
    }
  }
  return errors;
}

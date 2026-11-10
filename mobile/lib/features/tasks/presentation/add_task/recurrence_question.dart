import 'package:flutter/material.dart';

import '../../../app_shell/domain/format.dart';
import '../../domain/entities.dart';

/// "Every day" / "Chosen weekdays" with Mon…Sun chips. Used by the recurring question and by template editing.
class RecurrenceSelector extends StatelessWidget {
  const RecurrenceSelector({super.key, required this.value, required this.onChanged});

  final Recurrence? value;
  final ValueChanged<Recurrence> onChanged;

  @override
  Widget build(BuildContext context) {
    final current = value;
    final weekly = current is Weekly;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SegmentedButton<String>(
          key: const Key('repeat-kind'),
          emptySelectionAllowed: true,
          segments: const [
            ButtonSegment(value: 'daily', label: Text('Every day')),
            ButtonSegment(value: 'weekly', label: Text('Chosen weekdays')),
          ],
          selected: {
            if (current is Daily) 'daily',
            if (weekly) 'weekly',
          },
          onSelectionChanged: (s) {
            if (s.isEmpty) return;
            onChanged(s.first == 'daily' ? const Daily() : Weekly(current is Weekly ? current.byWeekday : {}));
          },
        ),
        if (current is Weekly)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Wrap(
              spacing: 6,
              children: [
                for (var d = 0; d < 7; d++)
                  FilterChip(
                    key: Key('weekday-$d'),
                    label: Text(weekdayShort(d)),
                    selected: current.byWeekday.contains(d),
                    onSelected: (on) {
                      final days = {...current.byWeekday};
                      if (on) {
                        days.add(d);
                      } else {
                        days.remove(d);
                      }
                      onChanged(Weekly(days));
                    },
                  ),
              ],
            ),
          ),
      ],
    );
  }
}

/// The mandatory "Recurring or one-time?" question: no default selection (spec §7.3, §8.1).
class RecurrenceQuestion extends StatelessWidget {
  const RecurrenceQuestion({
    super.key,
    required this.isRecurring,
    required this.recurrence,
    required this.onRecurringChanged,
    required this.onRecurrenceChanged,
    this.errorText,
  });

  final bool? isRecurring;
  final Recurrence? recurrence;
  final ValueChanged<bool?> onRecurringChanged;
  final ValueChanged<Recurrence> onRecurrenceChanged;
  final String? errorText;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Recurring or one-time?', style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 8),
        SegmentedButton<bool>(
          key: const Key('recurring-question'),
          emptySelectionAllowed: true,
          segments: const [
            ButtonSegment(value: false, label: Text('One-time')),
            ButtonSegment(value: true, label: Text('Recurring')),
          ],
          selected: {if (isRecurring != null) isRecurring!},
          onSelectionChanged: (s) => onRecurringChanged(s.isEmpty ? null : s.first),
        ),
        if (errorText != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(errorText!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ),
        if (isRecurring == true) ...[
          const SizedBox(height: 12),
          RecurrenceSelector(value: recurrence, onChanged: onRecurrenceChanged),
        ],
      ],
    );
  }
}

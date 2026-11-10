import 'package:flutter/material.dart';
import 'package:timezone/timezone.dart' as tz;

import '../../../app_shell/domain/format.dart';
import '../../domain/entities.dart';

String recommendedActionLabel(RecommendedAction a) => switch (a) {
      RecommendedAction.proceed => 'Go ahead',
      RecommendedAction.reschedule => 'Reschedule',
      RecommendedAction.split => 'Split into parts',
      RecommendedAction.shorten => 'Shorten it',
      RecommendedAction.drop => 'Drop it',
    };

String verdictLabel(Verdict v) => switch (v) {
      Verdict.go => 'Go',
      Verdict.caution => 'Caution',
      Verdict.noGo => 'No-go',
    };

Color verdictColor(Verdict v) => switch (v) {
      Verdict.go => Colors.green,
      Verdict.caution => Colors.amber.shade800,
      Verdict.noGo => Colors.red,
    };

/// Feasibility verdict shown before anything is saved (tasks spec §7.4). Advice only (P7): always addable.
class VerdictCard extends StatelessWidget {
  const VerdictCard({
    super.key,
    required this.assessment,
    required this.draft,
    required this.location,
    required this.onConfirm,
    required this.onAdjust,
    this.saving = false,
    this.saveError,
  });

  final Assessment assessment;
  final TaskDraft draft;
  final tz.Location location;
  final VoidCallback onConfirm;
  final VoidCallback onAdjust;
  final bool saving;
  final String? saveError;

  @override
  Widget build(BuildContext context) {
    final a = assessment;
    final fits = a.feasibleNoul >= 0.5;
    final percent = (a.score * 100).round();
    final fitsPercent = (a.feasibleNoul * 100).round();
    final predicted = a.predictedEndAt;
    final recurrence = draft.isRecurring == true && draft.recurrence != null ? draft.recurrence!.summary : 'One-time';

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Chip(
                    key: const Key('verdict-badge'),
                    label: Text(verdictLabel(a.verdict), style: const TextStyle(color: Colors.white)),
                    backgroundColor: verdictColor(a.verdict),
                  ),
                  const SizedBox(width: 12),
                  Text('Feasibility $percent%', key: const Key('verdict-score')),
                ],
              ),
              const SizedBox(height: 8),
              LinearProgressIndicator(value: a.score.clamp(0.0, 1.0)),
              const SizedBox(height: 12),
              Text(
                'Fits before your next commitment: ${fits ? 'Yes' : 'No'} ($fitsPercent%)',
                key: const Key('verdict-fits'),
              ),
              Text(
                'Recommended: ${recommendedActionLabel(a.recommendedAction)}',
                key: const Key('verdict-recommended'),
              ),
              if (a.suggestion.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(a.suggestion, key: const Key('verdict-suggestion')),
              ],
              if (predicted != null && draft.startAt != null)
                Text('Predicted to end ~${formatHm(predicted, location)}', key: const Key('verdict-predicted')),
              if (a.degraded)
                const Text('Basic check only — AI unavailable', key: Key('verdict-degraded')),
              Text(recurrence, key: const Key('verdict-recurrence')),
              if (saveError != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    saveError!,
                    key: const Key('verdict-save-error'),
                    style: TextStyle(color: Theme.of(context).colorScheme.error),
                  ),
                ),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(key: const Key('verdict-adjust'), onPressed: saving ? null : onAdjust, child: const Text('Adjust')),
                  const SizedBox(width: 8),
                  FilledButton(
                    key: const Key('verdict-confirm'),
                    onPressed: saving ? null : onConfirm,
                    child: Text(saving ? 'Saving…' : (a.verdict == Verdict.go ? 'Add' : 'Add anyway')),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Shown when the assessment failed: the task can still be added (P7/P10).
class FeasibilityUnavailableCard extends StatelessWidget {
  const FeasibilityUnavailableCard({
    super.key,
    required this.onAddWithoutCheck,
    required this.onRetry,
    required this.onAdjust,
    this.saving = false,
    this.saveError,
  });

  final VoidCallback onAddWithoutCheck;
  final VoidCallback onRetry;
  final VoidCallback onAdjust;
  final bool saving;
  final String? saveError;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Feasibility check unavailable', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            const Text("I couldn't check your day right now. You can still add the task."),
            if (saveError != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(saveError!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
              ),
            const SizedBox(height: 16),
            Wrap(
              alignment: WrapAlignment.end,
              spacing: 8,
              children: [
                TextButton(key: const Key('unavailable-adjust'), onPressed: saving ? null : onAdjust, child: const Text('Adjust')),
                TextButton(key: const Key('unavailable-retry'), onPressed: saving ? null : onRetry, child: const Text('Retry')),
                FilledButton(
                  key: const Key('unavailable-add'),
                  onPressed: saving ? null : onAddWithoutCheck,
                  child: Text(saving ? 'Saving…' : 'Add without check'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

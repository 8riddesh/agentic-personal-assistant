import 'entities.dart';

class TodaySections {
  const TodaySections({required this.planned, required this.finished});

  final List<Task> planned;
  final List<Task> finished;
}

int _byStartThenTitle(Task a, Task b) {
  final sa = a.startAt;
  final sb = b.startAt;
  if (sa != null && sb != null) {
    final c = sa.compareTo(sb);
    if (c != 0) return c;
  } else if (sa != null) {
    return -1; // timed before anytime
  } else if (sb != null) {
    return 1;
  }
  return a.title.toLowerCase().compareTo(b.title.toLowerCase());
}

/// Planned: timed by `start_at`, then anytime by title. Finished: every terminal task, same ordering.
TodaySections sectionTasks(List<Task> tasks) {
  final planned = tasks.where((t) => !t.isTerminal).toList()..sort(_byStartThenTitle);
  final finished = tasks.where((t) => t.isTerminal).toList()..sort(_byStartThenTitle);
  return TodaySections(planned: planned, finished: finished);
}

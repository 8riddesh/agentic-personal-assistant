/// Notification titles and bodies (notifications spec §7.1). Pure: callers pass already-formatted `HH:mm` strings.
class NotificationTexts {
  const NotificationTexts();

  /// 60 -> "1 hour", 120 -> "2 hours", other n -> "n min".
  String offsetLabel(int minutes) {
    if (minutes == 60) return '1 hour';
    if (minutes > 60 && minutes % 60 == 0) return '${minutes ~/ 60} hours';
    return '$minutes min';
  }

  ({String title, String body}) reminder({
    required int offsetMin,
    required String taskTitle,
    required String startHm,
    String? endHm,
    bool first = false,
  }) {
    final ends = first && endHm != null ? ' · ends ~$endHm' : '';
    return (title: 'In ${offsetLabel(offsetMin)}: $taskTitle', body: 'Starts at $startHm$ends');
  }

  ({String title, String body}) check({required String taskTitle, required String predictedHm}) =>
      (title: 'Done with $taskTitle?', body: 'It was predicted to end at $predictedHm.');

  ({String title, String body}) followUp({required String taskTitle, required String fireHm}) =>
      (title: 'Done with $taskTitle now?', body: 'You asked to be checked at $fireHm.');

  ({String title, String body}) finishQuestion({required String taskTitle}) =>
      (title: 'When did you finish $taskTitle?', body: 'Tap to pick a time.');
}

import 'dart:convert';

import 'notification_ids.dart';

/// Payload carried by every scheduled notification (<= 1 KB). Its hash `h` is what reconcile compares.
class NotificationPayload {
  const NotificationPayload({
    required this.taskId,
    required this.slot,
    required this.fireAtUtc,
    required this.date,
    required this.hash,
    required this.title,
    this.startAtUtc,
  });

  static const int version = 1;
  static const int maxTitleLength = 120;

  final String taskId;
  final NotificationSlot slot;
  final DateTime fireAtUtc;

  /// Local date of the day the task belongs to (`YYYY-MM-DD`).
  final String date;
  final String hash;
  final String title;
  final DateTime? startAtUtc;

  String encode() {
    final shortTitle = title.length > maxTitleLength ? title.substring(0, maxTitleLength) : title;
    return jsonEncode({
      'v': version,
      't': taskId,
      's': slot.index,
      'f': fireAtUtc.toUtc().toIso8601String(),
      'd': date,
      'h': hash,
      'n': shortTitle,
      if (startAtUtc != null) 'st': startAtUtc!.toUtc().toIso8601String(),
    });
  }

  /// `null` for garbage or an unknown version (ignored / cancelled by reconcile).
  static NotificationPayload? decode(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      final json = jsonDecode(raw);
      if (json is! Map || json['v'] != version) return null;
      final slotIndex = json['s'] as int;
      if (slotIndex < 0 || slotIndex >= NotificationSlot.values.length) return null;
      return NotificationPayload(
        taskId: json['t'] as String,
        slot: NotificationSlot.values[slotIndex],
        fireAtUtc: DateTime.parse(json['f'] as String).toUtc(),
        date: json['d'] as String,
        hash: json['h'] as String,
        title: json['n'] as String,
        startAtUtc: json['st'] == null ? null : DateTime.parse(json['st'] as String).toUtc(),
      );
    } on FormatException {
      return null;
    } on TypeError {
      return null;
    }
  }
}

import 'dart:convert';

/// One of at most four notifications per task (P5 attention budget: <= 2 reminders + 1 check; slot 3 only after the
/// user explicitly asked for a follow-up).
enum NotificationSlot { reminder1, reminder2, check, followUp }

typedef IdHasher = int Function(String taskId);

/// 32-bit FNV-1a over the UTF-8 bytes (offset basis 0x811C9DC5, prime 0x01000193).
int fnv1a32(String input) {
  var hash = 0x811C9DC5;
  for (final byte in utf8.encode(input)) {
    hash ^= byte;
    hash = (hash * 0x01000193) & 0xFFFFFFFF;
  }
  return hash;
}

const int _baseMask = 0x0FFFFFFF; // 28 bits
const int _probeStep = 0x9E3779B;

int baseFor(String taskId, {IdHasher hasher = fnv1a32}) => hasher(taskId) & _baseMask;

/// `base * 4 + slot`: `0 <= id < 2^30` (fits an Android int).
int idFromBase(int base, NotificationSlot slot) => base * 4 + slot.index;

/// The deterministic id of one slot (without collision probing).
int notificationId(String taskId, NotificationSlot slot, {IdHasher hasher = fnv1a32}) =>
    idFromBase(baseFor(taskId, hasher: hasher), slot);

/// Collision-free bases for a set of tasks. Tasks are processed in ascending id order, so the result does not depend
/// on input order; a task whose base is taken moves by a fixed step until free.
Map<String, int> assignBases(Iterable<String> taskIds, {IdHasher hasher = fnv1a32}) {
  final sorted = taskIds.toSet().toList()..sort();
  final used = <int>{};
  final result = <String, int>{};
  for (final id in sorted) {
    var base = baseFor(id, hasher: hasher);
    while (used.contains(base)) {
      base = (base + _probeStep) & _baseMask;
    }
    used.add(base);
    result[id] = base;
  }
  return result;
}

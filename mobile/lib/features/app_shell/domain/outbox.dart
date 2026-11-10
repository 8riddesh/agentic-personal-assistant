import 'dart:async';
import 'dart:convert';

import 'package:uuid/uuid.dart';

import '../data/api_client.dart';
import '../data/kv_store.dart';
import 'app_error.dart';
import 'clock.dart';

/// A request that must survive being offline (app_shell spec §8.6). POST only.
class OutboxRequest {
  const OutboxRequest({required this.path, required this.body, required this.label});

  final String path;
  final Map<String, Object?> body;

  /// Human text for the failure snackbar (on-device only).
  final String label;
}

class OutboxEntry {
  const OutboxEntry({
    required this.id,
    required this.idempotencyKey,
    required this.path,
    required this.bodyJson,
    required this.label,
    required this.createdAt,
    this.attempts = 0,
    this.nextAttemptAt,
    this.state = 'pending',
    this.lastError,
  });

  factory OutboxEntry.fromJson(Map<String, dynamic> j) => OutboxEntry(
        id: (j['id'] as num).toInt(),
        idempotencyKey: j['key'] as String,
        path: j['path'] as String,
        bodyJson: j['body'] as String,
        label: j['label'] as String,
        createdAt: DateTime.parse(j['created_at'] as String).toUtc(),
        attempts: (j['attempts'] as num?)?.toInt() ?? 0,
        nextAttemptAt: j['next_attempt_at'] == null ? null : DateTime.parse(j['next_attempt_at'] as String).toUtc(),
        state: j['state'] as String? ?? 'pending',
        lastError: j['last_error'] as String?,
      );

  final int id;
  final String idempotencyKey;
  final String path;
  final String bodyJson;
  final String label;
  final DateTime createdAt;
  final int attempts;
  final DateTime? nextAttemptAt;

  /// `pending` or `dead` (sent rows are deleted).
  final String state;
  final String? lastError;

  OutboxEntry copyWith({int? attempts, DateTime? nextAttemptAt, String? state, String? lastError}) => OutboxEntry(
        id: id,
        idempotencyKey: idempotencyKey,
        path: path,
        bodyJson: bodyJson,
        label: label,
        createdAt: createdAt,
        attempts: attempts ?? this.attempts,
        nextAttemptAt: nextAttemptAt ?? this.nextAttemptAt,
        state: state ?? this.state,
        lastError: lastError ?? this.lastError,
      );

  Map<String, Object?> toJson() => {
        'id': id,
        'key': idempotencyKey,
        'path': path,
        'body': bodyJson,
        'label': label,
        'created_at': createdAt.toIso8601String(),
        'attempts': attempts,
        'next_attempt_at': nextAttemptAt?.toIso8601String(),
        'state': state,
        'last_error': lastError,
      };
}

/// A dead entry surfaced to the user ("Couldn't sync: <label>").
class OutboxFailure {
  const OutboxFailure({required this.id, required this.label, this.error});

  final int id;
  final String label;
  final String? error;
}

class OutboxFlushResult {
  const OutboxFlushResult({this.sent = 0, this.dead = 0, this.remaining = 0, this.skipped = false});

  static const OutboxFlushResult skippedResult = OutboxFlushResult(skipped: true);

  final int sent;
  final int dead;

  /// Pending rows left (stopped on a network error / 401).
  final int remaining;

  /// Another flush was already running (in this isolate, or holding the lock).
  final bool skipped;
}

/// FIFO offline queue with `Idempotency-Key` replay. Works from any isolate (no Riverpod).
class OutboxService {
  OutboxService({
    required KeyValueStore store,
    required ApiClient api,
    required Clock clock,
    Uuid? uuid,
    Duration lockTtl = const Duration(seconds: 60),
  })  : _store = store,
        _api = api,
        _clock = clock,
        _uuid = uuid ?? const Uuid(),
        _lockTtl = lockTtl;

  final KeyValueStore _store;
  final ApiClient _api;
  final Clock _clock;
  final Uuid _uuid;
  final Duration _lockTtl;
  final StreamController<List<OutboxFailure>> _failures = StreamController<List<OutboxFailure>>.broadcast();
  bool _flushing = false;

  Stream<List<OutboxFailure>> get failureStream => _failures.stream;

  Future<({int nextId, List<OutboxEntry> entries})> _load() async {
    final raw = await _store.get(KvKeys.outboxEntries);
    if (raw == null) return (nextId: 1, entries: <OutboxEntry>[]);
    final decoded = jsonDecode(raw) as Map<String, dynamic>;
    final entries = (decoded['entries'] as List)
        .map((e) => OutboxEntry.fromJson((e as Map).cast<String, dynamic>()))
        .toList();
    return (nextId: (decoded['next_id'] as num).toInt(), entries: entries);
  }

  Future<void> _save(int nextId, List<OutboxEntry> entries) =>
      _store.set(KvKeys.outboxEntries, jsonEncode({'next_id': nextId, 'entries': entries.map((e) => e.toJson()).toList()}));

  Future<List<OutboxEntry>> entries() async => (await _load()).entries;

  Future<int> pendingCount() async => (await entries()).where((e) => e.state == 'pending').length;

  Future<void> enqueue(OutboxRequest r) async {
    final data = await _load();
    final entry = OutboxEntry(
      id: data.nextId,
      idempotencyKey: _uuid.v4(),
      path: r.path,
      bodyJson: jsonEncode(r.body),
      label: r.label,
      createdAt: _clock.nowUtc(),
    );
    await _save(data.nextId + 1, [...data.entries, entry]);
  }

  Future<bool> _acquireLock() async {
    final raw = await _store.get(KvKeys.outboxLock);
    final now = _clock.nowUtc();
    if (raw != null) {
      final expires = DateTime.tryParse(raw);
      if (expires != null && expires.isAfter(now)) return false;
    }
    await _store.set(KvKeys.outboxLock, now.add(_lockTtl).toIso8601String());
    return true;
  }

  Future<void> _replace(OutboxEntry updated) async {
    final data = await _load();
    await _save(data.nextId, [for (final e in data.entries) e.id == updated.id ? updated : e]);
  }

  Future<void> _remove(int id) async {
    final data = await _load();
    await _save(data.nextId, data.entries.where((e) => e.id != id).toList());
  }

  /// Sends pending rows in id order (spec §8.6). Single-flight, guarded by an expiring lock row so a second isolate
  /// does not double-send.
  Future<OutboxFlushResult> flush() async {
    if (_flushing) return OutboxFlushResult.skippedResult;
    _flushing = true;
    var locked = false;
    try {
      locked = await _acquireLock();
      if (!locked) return OutboxFlushResult.skippedResult;

      var sent = 0;
      var dead = 0;
      final pending = (await entries()).where((e) => e.state == 'pending').toList()
        ..sort((a, b) => a.id.compareTo(b.id));
      for (final e in pending) {
        try {
          await _api.post<Object?>(
            e.path,
            body: jsonDecode(e.bodyJson),
            idempotencyKey: e.idempotencyKey,
            decode: (json) => json,
          );
          await _remove(e.id);
          sent++;
        } on ConflictError {
          await _remove(e.id); // state already changed elsewhere: superseded
        } on UnauthorizedError {
          break; // keep the row; sent after re-login
        } on NetworkError {
          await _replace(e.copyWith(attempts: e.attempts + 1, lastError: 'offline'));
          break;
        } on ServerWakingTimeout {
          await _replace(e.copyWith(attempts: e.attempts + 1, lastError: 'server_waking'));
          break;
        } on ServerError catch (err) {
          await _replace(e.copyWith(attempts: e.attempts + 1, lastError: 'http_${err.status}'));
          break;
        } on NotFoundError {
          await _replace(e.copyWith(state: 'dead', lastError: 'not_found'));
          dead++;
        } on ValidationError {
          await _replace(e.copyWith(state: 'dead', lastError: 'invalid'));
          dead++;
        } on AppError catch (err) {
          await _replace(e.copyWith(attempts: e.attempts + 1, lastError: err.runtimeType.toString()));
          break;
        }
      }
      final remaining = await pendingCount();
      if (dead > 0 && !_failures.isClosed) _failures.add(await failures());
      return OutboxFlushResult(sent: sent, dead: dead, remaining: remaining);
    } finally {
      if (locked) await _store.remove(KvKeys.outboxLock);
      _flushing = false;
    }
  }

  Future<List<OutboxFailure>> failures() async => [
        for (final e in await entries())
          if (e.state == 'dead') OutboxFailure(id: e.id, label: e.label, error: e.lastError),
      ];

  /// "Dismiss" on the failure snackbar: deletes the dead row.
  Future<void> dismiss(int id) async {
    await _remove(id);
    if (!_failures.isClosed) _failures.add(await failures());
  }

  Future<void> dispose() => _failures.close();
}

import 'package:shared_preferences/shared_preferences.dart';

/// Small non-secret key/value persistence (app_kv, outbox rows, day cache).
///
/// Deviation from the specs (see app_shell/spec.md status): drift/SQLite needs build_runner codegen, which cannot be
/// run in this environment, so M1 persists JSON documents behind this interface. The production implementation uses
/// `SharedPreferencesAsync`, which reads through to the platform on every call (safe across isolates).
abstract interface class KeyValueStore {
  Future<String?> get(String key);
  Future<void> set(String key, String value);
  Future<void> remove(String key);
}

class PrefsKeyValueStore implements KeyValueStore {
  PrefsKeyValueStore([SharedPreferencesAsync? prefs]) : _prefs = prefs ?? SharedPreferencesAsync();

  final SharedPreferencesAsync _prefs;

  @override
  Future<String?> get(String key) => _prefs.getString(key);

  @override
  Future<void> set(String key, String value) => _prefs.setString(key, value);

  @override
  Future<void> remove(String key) => _prefs.remove(key);
}

/// In-memory implementation (tests and previews).
class InMemoryKeyValueStore implements KeyValueStore {
  final Map<String, String> values = {};

  @override
  Future<String?> get(String key) async => values[key];

  @override
  Future<void> set(String key, String value) async {
    values[key] = value;
  }

  @override
  Future<void> remove(String key) async {
    values.remove(key);
  }
}

/// Well-known `app_kv` keys.
abstract final class KvKeys {
  static const tzSynced = 'tz.synced';
  static const batteryGuideShown = 'battery_guide.shown';
  static const notifPermAsked = 'notif_perm.asked';
  static const outboxEntries = 'outbox.entries';
  static const outboxLock = 'outbox.lock';
  static const dayCache = 'cache.days';
}

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../domain/clock.dart';

/// Minimal secure key/value port (the JWT lives here - P12).
abstract interface class SecureKeyValue {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

class FlutterSecureKeyValue implements SecureKeyValue {
  FlutterSecureKeyValue([FlutterSecureStorage? storage])
      : _storage = storage ?? const FlutterSecureStorage(aOptions: _androidOptions);

  // One constant options instance, shared with any background isolate (app_shell spec §4.1).
  static const AndroidOptions _androidOptions = AndroidOptions(encryptedSharedPreferences: true);

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) => _storage.write(key: key, value: value);

  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}

class InMemorySecureKeyValue implements SecureKeyValue {
  final Map<String, String> values = {};
  bool failReads = false;

  @override
  Future<String?> read(String key) async {
    if (failReads) throw StateError('keystore unavailable');
    return values[key];
  }

  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }
}

class StoredToken {
  const StoredToken({required this.token, required this.expiresAt, this.email});

  final String token;
  final DateTime expiresAt;
  final String? email;
}

/// JWT persistence (app_shell spec §4.1). No Riverpod: usable from any isolate.
class TokenStore {
  TokenStore(this._kv, this._clock);

  static const keyJwt = 'auth.jwt';
  static const keyExpiresAt = 'auth.expires_at';
  static const keyEmail = 'auth.email';

  /// A token this close to expiry is treated as absent.
  static const expirySkew = Duration(seconds: 60);

  final SecureKeyValue _kv;
  final Clock _clock;

  /// `null` when there is no token, it expires within 60 s, or the keystore cannot be read (then storage is
  /// cleared: treated as logged out).
  Future<StoredToken?> read() async {
    try {
      final token = await _kv.read(keyJwt);
      final expiresRaw = await _kv.read(keyExpiresAt);
      if (token == null || token.isEmpty || expiresRaw == null) return null;
      final expiresAt = DateTime.tryParse(expiresRaw)?.toUtc();
      if (expiresAt == null) return null;
      if (!expiresAt.isAfter(_clock.nowUtc().add(expirySkew))) return null;
      return StoredToken(token: token, expiresAt: expiresAt, email: await _kv.read(keyEmail));
    } catch (_) {
      await _clearQuietly();
      return null;
    }
  }

  /// Last login email (prefill only); survives [clear].
  Future<String?> lastEmail() async {
    try {
      return await _kv.read(keyEmail);
    } catch (_) {
      return null;
    }
  }

  Future<void> write({required String token, required DateTime expiresAt, required String email}) async {
    await _kv.write(keyJwt, token);
    await _kv.write(keyExpiresAt, expiresAt.toUtc().toIso8601String());
    await _kv.write(keyEmail, email);
  }

  /// Removes the token and expiry (the email stays as a login prefill).
  Future<void> clear() async {
    await _kv.delete(keyJwt);
    await _kv.delete(keyExpiresAt);
  }

  Future<void> _clearQuietly() async {
    try {
      await clear();
    } catch (_) {
      // nothing else to do: the next read will fail the same way and report "absent"
    }
  }
}

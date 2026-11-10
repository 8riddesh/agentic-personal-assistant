import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:timezone/timezone.dart' as tz;

import '../data/api_client.dart';
import '../data/app_config.dart';
import '../data/auth_api.dart';
import '../data/interceptors/waking_interceptor.dart';
import '../data/kv_store.dart';
import '../data/token_store.dart';
import '../domain/app_error.dart';
import '../domain/app_settings.dart';
import '../domain/auth_state.dart';
import '../domain/clock.dart';
import '../domain/outbox.dart';

export '../data/interceptors/waking_interceptor.dart' show ServerStatus;

// ---------------------------------------------------------------- infrastructure (overridden in main.dart)

final appConfigProvider = Provider<AppConfig>((ref) => throw UnimplementedError('override appConfigProvider'));

final kvStoreProvider = Provider<KeyValueStore>((ref) => throw UnimplementedError('override kvStoreProvider'));

final secureKvProvider = Provider<SecureKeyValue>((ref) => FlutterSecureKeyValue());

final clockProvider = Provider<Clock>((_) => const SystemClock());

/// IANA zone of the device (e.g. `Europe/Bucharest`); overridden at bootstrap.
final deviceTimezoneProvider = Provider<String>((_) => 'UTC');

final tokenStoreProvider = Provider<TokenStore>(
  (ref) => TokenStore(ref.watch(secureKvProvider), ref.watch(clockProvider)),
);

/// Hooks run on logout, in order (composed in `composition.dart`: cancel notifications, clear caches).
final logoutHooksProvider = Provider<List<Future<void> Function()>>((_) => const []);

/// Extra rows contributed to the Settings screen by other features (notifications permission / battery guide).
final settingsExtraSectionsProvider = Provider<List<Widget>>((_) => const []);

// ---------------------------------------------------------------- server status

class ServerStatusNotifier extends Notifier<ServerStatus> implements ServerStatusSink {
  @override
  ServerStatus build() => ServerStatus.ok;

  @override
  void report(ServerStatus status) {
    if (state != status) state = status;
  }
}

final serverStatusProvider = NotifierProvider<ServerStatusNotifier, ServerStatus>(ServerStatusNotifier.new);

class _SafeStatusSink implements ServerStatusSink {
  _SafeStatusSink(this._ref);

  final Ref _ref;

  @override
  void report(ServerStatus status) {
    try {
      _ref.read(serverStatusProvider.notifier).report(status);
    } catch (_) {
      // provider already disposed (late timer callback): nothing to update
    }
  }
}

// ---------------------------------------------------------------- http

final apiClientProvider = Provider<ApiClient>((ref) {
  final dio = buildDio(
    config: ref.watch(appConfigProvider),
    tokens: ref.watch(tokenStoreProvider),
    onUnauthorized: () => ref.read(authControllerProvider.notifier).logout(
          reason: 'Session expired — please log in again',
        ),
    status: _SafeStatusSink(ref),
  );
  ref.onDispose(() => dio.close(force: true));
  return DioApiClient(dio);
});

final authApiProvider = Provider<AuthApi>((ref) => AuthApi(ref.watch(apiClientProvider)));

final settingsApiProvider = Provider<SettingsApi>((ref) => SettingsApi(ref.watch(apiClientProvider)));

// ---------------------------------------------------------------- auth

class AuthController extends AsyncNotifier<AuthState> {
  static const sessionExpiredReason = 'Session expired — please log in again';

  @override
  Future<AuthState> build() async {
    final token = await ref.read(tokenStoreProvider).read();
    if (token == null) return const Unauthenticated();
    return Authenticated(expiresAt: token.expiresAt, email: token.email);
  }

  /// Throws [AppError] on failure (the login screen renders it).
  Future<void> login(String email, String password) async {
    final trimmed = email.trim();
    final result = await ref.read(authApiProvider).login(
          email: trimmed,
          password: password,
          timezone: ref.read(deviceTimezoneProvider),
        );
    await ref.read(tokenStoreProvider).write(token: result.accessToken, expiresAt: result.expiresAt, email: trimmed);
    await _syncTimezoneOnce();
    state = AsyncData(Authenticated(expiresAt: result.expiresAt, email: trimmed));
  }

  /// Post-login task (spec §8.4): `GET /settings`; when `tz.synced` is absent, `PATCH` the device zone once.
  Future<void> _syncTimezoneOnce() async {
    try {
      final kv = ref.read(kvStoreProvider);
      final settingsApi = ref.read(settingsApiProvider);
      await settingsApi.get();
      if (await kv.get(KvKeys.tzSynced) == null) {
        await settingsApi.patch({'timezone': ref.read(deviceTimezoneProvider)});
        await kv.set(KvKeys.tzSynced, '1');
      }
    } on AppError {
      // never blocks a login; the Settings screen offers a manual sync
    }
  }

  /// Clears the token, then runs the logout hooks. Concurrent calls collapse into one.
  Future<void> logout({String? reason}) async {
    if (state.valueOrNull is Unauthenticated) return;
    state = AsyncData(Unauthenticated(reason: reason));
    await ref.read(tokenStoreProvider).clear();
    for (final hook in ref.read(logoutHooksProvider)) {
      try {
        await hook();
      } catch (_) {
        // a failing hook must not keep the user logged in
      }
    }
  }

  /// Token expiry check on launch/resume: expired => logout. Returns whether the session is still valid.
  Future<bool> enforceValidToken() async {
    final token = await ref.read(tokenStoreProvider).read();
    if (token == null) {
      await logout(reason: sessionExpiredReason);
      return false;
    }
    return true;
  }
}

final authControllerProvider = AsyncNotifierProvider<AuthController, AuthState>(AuthController.new);

/// Email used at the last login (prefill + Settings account row).
final storedEmailProvider = FutureProvider<String?>((ref) => ref.watch(tokenStoreProvider).lastEmail());

// ---------------------------------------------------------------- settings

class SettingsController extends AsyncNotifier<AppSettings> {
  @override
  Future<AppSettings> build() async {
    final auth = ref.watch(authControllerProvider).valueOrNull;
    if (auth is! Authenticated) throw const UnauthorizedError();
    return ref.read(settingsApiProvider).get();
  }

  /// `null` clears the address.
  Future<void> setReportEmail(String? email) async {
    state = AsyncData(await ref.read(settingsApiProvider).patch({'report_email': email}));
  }

  Future<void> syncTimezoneFromDevice() async {
    state = AsyncData(await ref.read(settingsApiProvider).patch({'timezone': ref.read(deviceTimezoneProvider)}));
    await ref.read(kvStoreProvider).set(KvKeys.tzSynced, '1');
  }
}

final settingsControllerProvider = AsyncNotifierProvider<SettingsController, AppSettings>(SettingsController.new);

/// Location of `AppSettings.timezone` (falls back to the device zone while settings load).
final appLocationProvider = Provider<tz.Location>((ref) {
  final name = ref.watch(settingsControllerProvider).valueOrNull?.timezone;
  if (name != null) {
    try {
      return tz.getLocation(name);
    } catch (_) {
      // unknown zone name: fall through to the device zone
    }
  }
  return tz.local;
});

// ---------------------------------------------------------------- outbox

final outboxServiceProvider = Provider<OutboxService>((ref) {
  final service = OutboxService(
    store: ref.watch(kvStoreProvider),
    api: ref.watch(apiClientProvider),
    clock: ref.watch(clockProvider),
  );
  ref.onDispose(service.dispose);
  return service;
});

final outboxFailuresProvider = StreamProvider<List<OutboxFailure>>((ref) async* {
  final service = ref.watch(outboxServiceProvider);
  yield await service.failures();
  yield* service.failureStream;
});

// ---------------------------------------------------------------- lifecycle

abstract interface class LifecycleHook {
  int get order;

  Future<void> onLaunchOrResume(Ref ref);
}

/// Thrown by a hook to stop the rest of the chain (token expired).
class LifecycleAbort implements Exception {
  const LifecycleAbort();
}

/// Composed in `composition.dart` (tasks, notifications hooks); app_shell contributes orders 10 and 20.
final lifecycleHooksProvider = Provider<List<LifecycleHook>>((_) => const []);

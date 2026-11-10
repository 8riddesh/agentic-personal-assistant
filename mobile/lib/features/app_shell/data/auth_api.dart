import '../domain/app_settings.dart';
import 'api_client.dart';

class LoginResult {
  const LoginResult({required this.accessToken, required this.expiresAt});

  factory LoginResult.fromJson(Object? json) {
    if (json is! Map) throw const FormatException('Unexpected login response');
    return LoginResult(
      accessToken: json['access_token'] as String,
      expiresAt: DateTime.parse(json['expires_at'] as String).toUtc(),
    );
  }

  final String accessToken;
  final DateTime expiresAt;
}

/// `POST /auth/login` (public). Retryable: safe to repeat (cold start).
class AuthApi {
  AuthApi(this._api);

  final ApiClient _api;

  Future<LoginResult> login({required String email, required String password, String? timezone}) => _api.post(
        '/auth/login',
        body: {'email': email, 'password': password, if (timezone != null) 'timezone': timezone},
        retryable: true,
        decode: LoginResult.fromJson,
      );
}

/// `GET/PATCH /settings`.
class SettingsApi {
  SettingsApi(this._api);

  final ApiClient _api;

  Future<AppSettings> get() => _api.get('/settings', decode: AppSettings.fromJson);

  /// Any subset of `{timezone, report_email}`; `report_email: null` clears it.
  Future<AppSettings> patch(Map<String, Object?> patch) =>
      _api.patch('/settings', body: patch, decode: AppSettings.fromJson);
}

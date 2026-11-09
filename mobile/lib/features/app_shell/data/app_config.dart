/// Build-time configuration (app_shell spec §5, §9). The APK holds only the backend URL - never a secret (P12).
///
/// Supplied with `--dart-define=API_BASE_URL=https://<service>.onrender.com`.
class AppConfig {
  const AppConfig._(this.apiBaseUrl);

  /// Backend root, without a trailing slash and without `/api/v1`.
  final Uri apiBaseUrl;

  static const String _apiBaseUrlDefine = String.fromEnvironment('API_BASE_URL');

  /// Reads `API_BASE_URL`. Throws [StateError] when it is missing or invalid so that `main()` can show the
  /// configuration error screen (M-SHELL-AC-12).
  factory AppConfig.fromEnvironment() => AppConfig.parse(_apiBaseUrlDefine);

  /// Pure parser behind [AppConfig.fromEnvironment] (unit-testable: `String.fromEnvironment` is compile-time).
  factory AppConfig.parse(String raw) {
    final value = raw.trim();
    if (value.isEmpty) {
      throw StateError('API_BASE_URL not configured');
    }
    final uri = Uri.tryParse(value);
    final validScheme = uri != null && (uri.scheme == 'https' || uri.scheme == 'http');
    if (uri == null || !validScheme || uri.host.isEmpty) {
      throw StateError('API_BASE_URL is not a valid http(s) URL');
    }
    // Normalise: drop a trailing slash (paths are appended with a leading slash).
    final path = uri.path.endsWith('/') ? uri.path.substring(0, uri.path.length - 1) : uri.path;
    return AppConfig._(uri.replace(path: path));
  }
}

import 'package:dio/dio.dart';

/// Result of `GET /health` (public, at the backend root - not under /api/v1).
class HealthStatus {
  const HealthStatus({required this.status, required this.db, required this.version, required this.env});

  factory HealthStatus.fromJson(Object? json) {
    if (json is! Map<String, dynamic>) {
      throw const FormatException('Unexpected /health response');
    }
    return HealthStatus(
      status: json['status'] as String? ?? 'unknown',
      db: json['db'] as String? ?? 'unknown',
      version: json['version'] as String? ?? '?',
      env: json['env'] as String? ?? '?',
    );
  }

  final String status;
  final String db;
  final String version;
  final String env;

  bool get isOk => status == 'ok';
}

abstract interface class HealthApi {
  Future<HealthStatus> check();
}

class DioHealthApi implements HealthApi {
  DioHealthApi(Uri apiBaseUrl, {Dio? dio})
      : _dio = dio ??
            Dio(
              BaseOptions(
                baseUrl: apiBaseUrl.toString(),
                // Render's free instance can take up to ~60 s to wake up (plan §2.3).
                connectTimeout: const Duration(seconds: 20),
                receiveTimeout: const Duration(seconds: 75),
                headers: {'Accept': 'application/json'},
                // A degraded server answers 503 with a valid HealthDTO body: let it through.
                validateStatus: (status) => status != null && (status == 200 || status == 503),
              ),
            );

  final Dio _dio;

  @override
  Future<HealthStatus> check() async {
    final response = await _dio.get<Object?>('/health');
    return HealthStatus.fromJson(response.data);
  }
}

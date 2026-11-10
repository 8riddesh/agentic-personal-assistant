import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';

import '../domain/app_error.dart';
import 'app_config.dart';
import 'interceptors/auth_interceptor.dart';
import 'interceptors/retry_interceptor.dart';
import 'interceptors/waking_interceptor.dart';
import 'problem_mapper.dart';
import 'token_store.dart';

/// Typed HTTP facade. Every method throws [AppError] subclasses only.
abstract interface class ApiClient {
  Future<T> get<T>(String path, {Map<String, dynamic>? query, required T Function(Object? json) decode});

  /// [retryable] marks POSTs that are safe to repeat (login, assess, chat). A non-null [idempotencyKey] is sent as
  /// the `Idempotency-Key` header and also makes the POST retryable.
  Future<T> post<T>(
    String path, {
    Object? body,
    String? idempotencyKey,
    bool retryable = false,
    required T Function(Object? json) decode,
  });

  Future<T> put<T>(String path, {Object? body, required T Function(Object? json) decode});

  Future<T> patch<T>(String path, {Object? body, required T Function(Object? json) decode});

  Future<void> delete(String path);

  Future<Uint8List> getBytes(String path);
}

/// Builds the Dio instance (interceptor order: Waking -> Auth -> Retry; app_shell spec §8.1). No body logging:
/// bodies contain personal text.
Dio buildDio({
  required AppConfig config,
  required TokenStore tokens,
  FutureOr<void> Function()? onUnauthorized,
  ServerStatusSink? status,
  HttpClientAdapter? adapter,
  Future<void> Function(Duration)? retryDelay,
  Duration retryBudget = const Duration(seconds: 120),
}) {
  final dio = Dio(
    BaseOptions(
      baseUrl: '${config.apiBaseUrl}/api/v1',
      connectTimeout: const Duration(seconds: 20),
      sendTimeout: const Duration(seconds: 30),
      receiveTimeout: const Duration(seconds: 75),
      headers: {'Accept': 'application/json, application/problem+json'},
    ),
  );
  if (adapter != null) dio.httpClientAdapter = adapter;
  if (status != null) dio.interceptors.add(WakingInterceptor(status));
  dio.interceptors.add(AuthInterceptor(tokens, onUnauthorized: onUnauthorized));
  dio.interceptors.add(RetryInterceptor(dio, delay: retryDelay, budget: retryBudget));
  return dio;
}

class DioApiClient implements ApiClient {
  DioApiClient(this._dio);

  final Dio _dio;

  Future<T> _run<T>(Future<T> Function() action) async {
    try {
      return await action();
    } on DioException catch (e) {
      throw mapDioException(e);
    } on AppError {
      rethrow;
    } on FormatException catch (e) {
      throw UnknownError(e);
    } on TypeError catch (e) {
      throw UnknownError(e);
    }
  }

  @override
  Future<T> get<T>(String path, {Map<String, dynamic>? query, required T Function(Object? json) decode}) =>
      _run(() async {
        final r = await _dio.get<Object?>(path, queryParameters: query);
        return decode(r.data);
      });

  @override
  Future<T> post<T>(
    String path, {
    Object? body,
    String? idempotencyKey,
    bool retryable = false,
    required T Function(Object? json) decode,
  }) =>
      _run(() async {
        final r = await _dio.post<Object?>(
          path,
          data: body,
          options: Options(
            headers: idempotencyKey == null ? null : {'Idempotency-Key': idempotencyKey},
            extra: {'retryable': retryable},
          ),
        );
        return decode(r.data);
      });

  @override
  Future<T> put<T>(String path, {Object? body, required T Function(Object? json) decode}) => _run(() async {
        final r = await _dio.put<Object?>(path, data: body);
        return decode(r.data);
      });

  @override
  Future<T> patch<T>(String path, {Object? body, required T Function(Object? json) decode}) => _run(() async {
        final r = await _dio.patch<Object?>(path, data: body);
        return decode(r.data);
      });

  @override
  Future<void> delete(String path) => _run(() async {
        await _dio.delete<Object?>(path);
      });

  @override
  Future<Uint8List> getBytes(String path) => _run(() async {
        final r = await _dio.get<List<int>>(path, options: Options(responseType: ResponseType.bytes));
        return Uint8List.fromList(r.data ?? const <int>[]);
      });
}

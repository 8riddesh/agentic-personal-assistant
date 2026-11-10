import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:dio/dio.dart';

import '../../domain/backoff.dart';
import '../problem_mapper.dart';

/// Cold-start retry with backoff (app_shell spec §8.2).
///
/// Retryable: connection error, connect/receive timeout, HTTP 502/503/504. GET/PUT/PATCH/DELETE are retried; POST
/// only when it carries an `Idempotency-Key` header or `extra['retryable'] == true`. Up to [maxRetries] retries
/// within [budget] (sum of the planned delays); a plain "no network" failure is retried at most once.
class RetryInterceptor extends Interceptor {
  RetryInterceptor(
    this._dio, {
    this.maxRetries = 4,
    this.budget = const Duration(seconds: 120),
    Future<void> Function(Duration)? delay,
    Random? random,
  })  : _delay = delay ?? Future<void>.delayed,
        _random = random;

  final Dio _dio;
  final int maxRetries;
  final Duration budget;
  final Future<void> Function(Duration) _delay;
  final Random? _random;

  static const _innerKey = 'retry_inner';

  bool _isNetworkDown(DioException e) =>
      e.type == DioExceptionType.connectionError && (e.error is SocketException || e.response == null);

  bool _isRetryable(DioException e) {
    final method = e.requestOptions.method.toUpperCase();
    if (method == 'POST') {
      final hasKey = e.requestOptions.headers.containsKey('Idempotency-Key');
      if (!hasKey && e.requestOptions.extra['retryable'] != true) return false;
    }
    final status = e.response?.statusCode;
    return e.type == DioExceptionType.connectionError ||
        e.type == DioExceptionType.connectionTimeout ||
        e.type == DioExceptionType.receiveTimeout ||
        (e.type == DioExceptionType.badResponse && (status == 502 || status == 503 || status == 504));
  }

  @override
  Future<void> onError(DioException err, ErrorInterceptorHandler handler) async {
    final options = err.requestOptions;
    if (options.extra[_innerKey] == true || !_isRetryable(err)) {
      handler.next(err);
      return;
    }

    final cap = _isNetworkDown(err) ? 1 : maxRetries;
    var waited = Duration.zero;
    var last = err;
    for (var n = 1; n <= cap; n++) {
      final wait = backoffDelay(n, random: _random);
      if (waited + wait > budget) break;
      waited += wait;
      await _delay(wait);
      try {
        final response = await _dio.fetch<dynamic>(options.copyWith(extra: {...options.extra, _innerKey: true}));
        handler.resolve(response);
        return;
      } on DioException catch (e) {
        last = e;
        if (!_isRetryable(e)) break;
      }
    }
    options.extra[retriesExhaustedKey] = true;
    handler.next(last.copyWith(requestOptions: options));
  }
}

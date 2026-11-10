import 'dart:async';

import 'package:dio/dio.dart';

import '../token_store.dart';

/// Adds `Authorization: Bearer <jwt>` and reports 401s (app_shell spec §8.1, §8.4).
class AuthInterceptor extends Interceptor {
  AuthInterceptor(this._tokens, {this.onUnauthorized});

  /// Paths that never carry a token and whose 401 is not a "session expired".
  static const publicPaths = {'/auth/login', '/health'};

  final TokenStore _tokens;
  final FutureOr<void> Function()? onUnauthorized;
  bool _firing = false;

  bool _isPublic(RequestOptions o) => publicPaths.contains(o.path);

  @override
  Future<void> onRequest(RequestOptions options, RequestInterceptorHandler handler) async {
    if (!_isPublic(options)) {
      final token = await _tokens.read();
      if (token != null) options.headers['Authorization'] = 'Bearer ${token.token}';
    }
    handler.next(options);
  }

  @override
  Future<void> onError(DioException err, ErrorInterceptorHandler handler) async {
    if (err.response?.statusCode == 401 && !_isPublic(err.requestOptions) && !_firing) {
      // Several parallel requests fail together: only the first triggers the logout. Stragglers arriving later
      // carry a stale token, which is no longer stored, so they are ignored too.
      _firing = true;
      try {
        final sent = err.requestOptions.headers['Authorization'];
        final current = await _tokens.read();
        if (sent != null && current != null && sent == 'Bearer ${current.token}') {
          await onUnauthorized?.call();
        }
      } finally {
        _firing = false;
      }
    }
    handler.next(err);
  }
}

import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';

import '../domain/app_error.dart';

/// `extra` flag set by the retry interceptor when every retry failed.
const String retriesExhaustedKey = 'retries_exhausted';

/// DioException -> [AppError] (app_shell spec §8.5).
AppError mapDioException(DioException e) {
  // if-chain instead of an exhaustive switch: newer dio versions add enum values (e.g. transformTimeout).
  final type = e.type;
  if (type == DioExceptionType.connectionTimeout ||
      type == DioExceptionType.receiveTimeout ||
      type == DioExceptionType.sendTimeout) {
    return const ServerWakingTimeout();
  }
  if (type == DioExceptionType.connectionError) {
    return e.error is SocketException || e.response == null ? const NetworkError() : UnknownError(e);
  }
  if (type == DioExceptionType.badResponse) {
    final response = e.response;
    final status = response?.statusCode ?? 0;
    if (e.requestOptions.extra[retriesExhaustedKey] == true && (status == 502 || status == 503 || status == 504)) {
      return const ServerWakingTimeout();
    }
    return mapProblem(status, response?.data);
  }
  if (e.error is SocketException) return const NetworkError();
  return UnknownError(e);
}

/// HTTP status + (problem+json | FastAPI | non-JSON) body -> typed error.
AppError mapProblem(int status, Object? body) {
  final map = _asMap(body);
  final detail = map == null ? null : _detailString(map);
  switch (status) {
    case 401:
      return UnauthorizedError(detail);
    case 404:
      return NotFoundError(detail);
    case 409:
      return ConflictError(code: _conflictCode(map), detail: detail);
    case 400:
    case 422:
      return ValidationError(fieldErrors: map == null ? const {} : _fieldErrors(map), detail: detail);
  }
  if (status >= 500) return ServerError(status: status, detail: detail);
  return UnknownError('HTTP $status');
}

Map<String, dynamic>? _asMap(Object? data) {
  if (data is Map) return data.cast<String, dynamic>();
  if (data is String && data.trimLeft().startsWith('{')) {
    try {
      final decoded = jsonDecode(data);
      if (decoded is Map) return decoded.cast<String, dynamic>();
    } on FormatException {
      return null;
    }
  }
  return null;
}

String? _detailString(Map<String, dynamic> map) {
  final detail = map['detail'];
  if (detail is String) return detail;
  return null;
}

String? _conflictCode(Map<String, dynamic>? map) {
  if (map == null) return null;
  final code = map['code'];
  if (code is String && code.isNotEmpty) return code;
  final type = map['type'];
  if (type is String && type.isNotEmpty) {
    final segments = type.split('/').where((s) => s.isNotEmpty).toList();
    if (segments.isNotEmpty) return segments.last;
  }
  return null;
}

/// Both `errors: [{loc, msg}]` (our backend) and FastAPI's `detail: [{loc, msg}]`.
Map<String, String> _fieldErrors(Map<String, dynamic> map) {
  final raw = map['errors'] is List ? map['errors'] : (map['detail'] is List ? map['detail'] : null);
  final result = <String, String>{};
  if (raw is List) {
    for (final item in raw) {
      if (item is! Map) continue;
      final loc = item['loc'];
      final msg = item['msg'];
      if (loc is List && loc.isNotEmpty && msg is String) {
        result[loc.last.toString()] = msg;
      }
    }
  }
  return result;
}

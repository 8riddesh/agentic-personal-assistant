import 'dart:io';

import 'package:daily_assistant/features/app_shell/data/problem_mapper.dart';
import 'package:daily_assistant/features/app_shell/domain/app_error.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

DioException _bad(int status, Object? data, {Map<String, dynamic>? extra}) {
  final options = RequestOptions(path: '/x', extra: extra ?? {});
  return DioException(
    requestOptions: options,
    type: DioExceptionType.badResponse,
    response: Response<Object?>(requestOptions: options, statusCode: status, data: data),
  );
}

void main() {
  test('400 -> ValidationError with detail', () {
    final e = mapDioException(_bad(400, {'detail': 'bad request'}));
    expect(e, isA<ValidationError>());
    expect((e as ValidationError).detail, 'bad request');
  });

  test('401 -> UnauthorizedError', () {
    expect(mapDioException(_bad(401, {'code': 'invalid_token'})), isA<UnauthorizedError>());
  });

  test('404 -> NotFoundError', () {
    expect(mapDioException(_bad(404, {'detail': 'nope'})), isA<NotFoundError>());
  });

  test('409 with code extension', () {
    final e = mapDioException(_bad(409, {'type': '/problems/conflict', 'code': 'task.invalid_transition', 'detail': 'x'}));
    expect(e, isA<ConflictError>());
    expect((e as ConflictError).code, 'task.invalid_transition');
    expect(e.detail, 'x');
  });

  test('409 with only a type uses its last path segment', () {
    final e = mapDioException(_bad(409, {'type': 'https://errors/x/report-email-not-configured'}));
    expect((e as ConflictError).code, 'report-email-not-configured');
  });

  test('422 FastAPI list maps loc.last -> msg', () {
    final e = mapDioException(_bad(422, {
      'detail': [
        {'loc': ['body', 'title'], 'msg': 'field required'},
      ],
    }));
    expect(e, isA<ValidationError>());
    expect((e as ValidationError).fieldErrors, {'title': 'field required'});
  });

  test('422 problem+json errors list maps loc.last -> msg', () {
    final e = mapDioException(_bad(422, {
      'type': '/problems/validation-failed',
      'detail': 'Request body is invalid.',
      'errors': [
        {'loc': ['body', 'timezone'], 'msg': 'unknown IANA timezone', 'type': 'value_error'},
      ],
    }));
    final v = e as ValidationError;
    expect(v.fieldErrors, {'timezone': 'unknown IANA timezone'});
    expect(v.detail, 'Request body is invalid.');
  });

  test('500 with a non-JSON body -> ServerError without detail', () {
    final e = mapDioException(_bad(500, '<html>oops</html>'));
    expect(e, isA<ServerError>());
    expect((e as ServerError).status, 500);
    expect(e.detail, isNull);
  });

  test('a JSON string body is decoded', () {
    final e = mapDioException(_bad(404, '{"detail":"gone"}'));
    expect((e as NotFoundError).detail, 'gone');
  });

  test('exhausted retries on 503 -> ServerWakingTimeout', () {
    final e = mapDioException(_bad(503, null, extra: {retriesExhaustedKey: true}));
    expect(e, isA<ServerWakingTimeout>());
  });

  test('503 without exhausted retries stays a ServerError', () {
    expect(mapDioException(_bad(503, null)), isA<ServerError>());
  });

  test('connection error -> NetworkError', () {
    final e = mapDioException(DioException(
      requestOptions: RequestOptions(path: '/x'),
      type: DioExceptionType.connectionError,
      error: const SocketException('down'),
    ));
    expect(e, isA<NetworkError>());
  });

  test('timeouts -> ServerWakingTimeout', () {
    for (final type in [DioExceptionType.connectionTimeout, DioExceptionType.receiveTimeout]) {
      expect(mapDioException(DioException(requestOptions: RequestOptions(path: '/x'), type: type)),
          isA<ServerWakingTimeout>());
    }
  });

  test('unknown failures -> UnknownError', () {
    final e = mapDioException(DioException(requestOptions: RequestOptions(path: '/x'), type: DioExceptionType.cancel));
    expect(e, isA<UnknownError>());
  });
}

import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';

enum ServerStatus { ok, waking, offline }

abstract interface class ServerStatusSink {
  void report(ServerStatus status);
}

/// Reports in-flight latency to the UI (app_shell spec §8.3): a request that takes longer than [slowAfter], or that
/// failed in a retryable way, flips the status to `waking`; any answer flips it back to `ok`.
class WakingInterceptor extends Interceptor {
  WakingInterceptor(this._sink, {this.slowAfter = const Duration(seconds: 3)});

  final ServerStatusSink _sink;
  final Duration slowAfter;
  final Map<RequestOptions, Timer> _timers = {};

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    _timers[options] = Timer(slowAfter, () => _sink.report(ServerStatus.waking));
    handler.next(options);
  }

  @override
  void onResponse(Response<dynamic> response, ResponseInterceptorHandler handler) {
    _timers.remove(response.requestOptions)?.cancel();
    _sink.report(ServerStatus.ok);
    handler.next(response);
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    _timers.remove(err.requestOptions)?.cancel();
    final status = err.response?.statusCode;
    if (err.type == DioExceptionType.connectionError && (err.error is SocketException || err.response == null)) {
      _sink.report(ServerStatus.offline);
    } else if (err.type == DioExceptionType.connectionTimeout ||
        err.type == DioExceptionType.receiveTimeout ||
        status == 502 ||
        status == 503 ||
        status == 504) {
      _sink.report(ServerStatus.waking);
    } else if (err.response != null) {
      _sink.report(ServerStatus.ok); // the server answered (4xx / 500)
    }
    handler.next(err);
  }
}

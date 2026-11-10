/// Every failure surfaced by the API layer is one of these (app_shell spec §5). `ApiClient` throws nothing else.
sealed class AppError implements Exception {
  const AppError();

  String get userMessage;

  @override
  String toString() => '$runtimeType: $userMessage';
}

/// Offline / DNS / connection refused.
final class NetworkError extends AppError {
  const NetworkError();

  @override
  String get userMessage => "You're offline. Check your connection.";
}

/// Retries exhausted while the free server was waking up.
final class ServerWakingTimeout extends AppError {
  const ServerWakingTimeout();

  @override
  String get userMessage => "Server didn't wake up. Retry.";
}

final class UnauthorizedError extends AppError {
  const UnauthorizedError([this.detail]);

  final String? detail;

  @override
  String get userMessage => 'Session expired — please log in again.';
}

final class NotFoundError extends AppError {
  const NotFoundError([this.detail]);

  final String? detail;

  @override
  String get userMessage => 'Not found.';
}

final class ConflictError extends AppError {
  const ConflictError({this.code, this.detail});

  final String? code;
  final String? detail;

  @override
  String get userMessage => detail ?? 'That conflicts with the current state. Refresh and try again.';
}

final class ValidationError extends AppError {
  const ValidationError({this.fieldErrors = const {}, this.detail});

  final Map<String, String> fieldErrors;
  final String? detail;

  @override
  String get userMessage {
    if (fieldErrors.isNotEmpty) return fieldErrors.values.first;
    return detail ?? 'Some values are invalid.';
  }
}

final class ServerError extends AppError {
  const ServerError({required this.status, this.detail});

  final int status;
  final String? detail;

  @override
  String get userMessage => 'The server had a problem ($status). Try again.';
}

final class UnknownError extends AppError {
  const UnknownError(this.cause);

  final Object cause;

  @override
  String get userMessage => 'Something went wrong.';
}

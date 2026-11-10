sealed class AuthState {
  const AuthState();
}

/// Token not read yet (splash).
final class AuthUnknown extends AuthState {
  const AuthUnknown();
}

final class Unauthenticated extends AuthState {
  const Unauthenticated({this.reason});

  /// e.g. "Session expired — please log in again" shown on the login screen.
  final String? reason;
}

final class Authenticated extends AuthState {
  const Authenticated({required this.expiresAt, this.email});

  final DateTime expiresAt;
  final String? email;
}

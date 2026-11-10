import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../notifications/presentation/battery_guide_screen.dart';
import '../../tasks/domain/entities.dart';
import '../../tasks/presentation/add_task/add_task_screen.dart';
import '../../tasks/presentation/edit_task_screen.dart';
import '../../tasks/presentation/templates_screen.dart';
import '../../tasks/presentation/today_screen.dart';
import '../domain/auth_state.dart';
import 'login_screen.dart';
import 'placeholder_screen.dart';
import 'providers.dart';
import 'settings_screen.dart';
import 'shell_scaffold.dart';
import 'splash_screen.dart';

/// Pure guard (app_shell spec §7.2): unknown -> splash; unauthenticated -> login (remembering where the user was
/// going); authenticated at login/splash -> the remembered location or Today.
String? guardRedirect(AuthState auth, Uri location) {
  final path = location.path;
  switch (auth) {
    case AuthUnknown():
      return path == '/splash' ? null : '/splash';
    case Unauthenticated():
      if (path == '/login') return null;
      if (path == '/splash') return '/login';
      return '/login?from=${Uri.encodeQueryComponent(location.toString())}';
    case Authenticated():
      if (path == '/login' || path == '/splash') return location.queryParameters['from'] ?? '/today';
      return null;
  }
}

class _AuthRefresh extends ChangeNotifier {
  void ping() => notifyListeners();
}

final routerProvider = Provider<GoRouter>((ref) {
  final refresh = _AuthRefresh();
  ref.listen<AsyncValue<AuthState>>(authControllerProvider, (previous, next) => refresh.ping());

  final router = GoRouter(
    initialLocation: '/splash',
    refreshListenable: refresh,
    redirect: (context, state) =>
        guardRedirect(ref.read(authControllerProvider).valueOrNull ?? const AuthUnknown(), state.uri),
    routes: [
      GoRoute(path: '/splash', builder: (context, state) => const SplashScreen()),
      GoRoute(path: '/login', builder: (context, state) => const LoginScreen()),
      StatefulShellRoute.indexedStack(
        builder: (context, state, shell) => ShellScaffold(navigationShell: shell),
        branches: [
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/today',
                builder: (context, state) => const TodayScreen(),
                routes: [
                  GoRoute(
                    path: 'new',
                    builder: (context, state) {
                      final args = state.extra is AddTaskArgs ? state.extra as AddTaskArgs : null;
                      return AddTaskScreen(prefill: args?.prefill, via: args?.via ?? CreatedVia.form);
                    },
                  ),
                  GoRoute(
                    path: 'task/:id/edit',
                    builder: (context, state) => EditTaskScreen(taskId: state.pathParameters['id']!),
                  ),
                  GoRoute(path: 'templates', builder: (context, state) => const TemplatesScreen()),
                ],
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/chat',
                builder: (context, state) =>
                    const PlaceholderScreen(title: 'Chat', message: 'The assistant chat arrives in a later update.'),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/reports',
                builder: (context, state) =>
                    const PlaceholderScreen(title: 'Reports', message: 'Daily and weekly reports arrive in a later update.'),
                routes: [
                  GoRoute(
                    path: ':id',
                    builder: (context, state) =>
                        const PlaceholderScreen(title: 'Report', message: 'The report viewer arrives in a later update.'),
                  ),
                ],
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/settings',
                builder: (context, state) =>
                    SettingsScreen(focusReportEmail: state.uri.queryParameters['focus'] == 'report_email'),
                routes: [
                  GoRoute(path: 'battery', builder: (context, state) => const BatteryGuideScreen()),
                ],
              ),
            ],
          ),
        ],
      ),
    ],
  );
  ref.onDispose(() {
    router.dispose();
    refresh.dispose();
  });
  return router;
});

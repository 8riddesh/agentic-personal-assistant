import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/auth_state.dart';
import 'providers.dart';

/// Order 10: expired token => logout and abort the chain.
class TokenCheckHook implements LifecycleHook {
  const TokenCheckHook();

  @override
  int get order => 10;

  @override
  Future<void> onLaunchOrResume(Ref ref) async {
    final valid = await ref.read(authControllerProvider.notifier).enforceValidToken();
    if (!valid) throw const LifecycleAbort();
  }
}

/// Order 20: send queued offline answers.
class OutboxFlushHook implements LifecycleHook {
  const OutboxFlushHook();

  @override
  int get order => 20;

  @override
  Future<void> onLaunchOrResume(Ref ref) async {
    await ref.read(outboxServiceProvider).flush();
  }
}

/// Runs the hooks in `order` on launch/resume, at most every 30 s unless forced (spec §8.7).
class LifecycleRunner {
  LifecycleRunner(this._ref);

  static const throttle = Duration(seconds: 30);

  final Ref _ref;
  DateTime? _lastRun;
  bool _running = false;

  Future<void> run({bool force = false}) async {
    if (_running) return;
    if (_ref.read(authControllerProvider).valueOrNull is! Authenticated) return;
    final now = _ref.read(clockProvider).nowUtc();
    final last = _lastRun;
    if (!force && last != null && now.difference(last) < throttle) return;

    _running = true;
    _lastRun = now;
    try {
      final hooks = [const TokenCheckHook(), const OutboxFlushHook(), ..._ref.read(lifecycleHooksProvider)]
        ..sort((a, b) => a.order.compareTo(b.order));
      for (final hook in hooks) {
        try {
          await hook.onLaunchOrResume(_ref);
        } on LifecycleAbort {
          break;
        } catch (_) {
          // a hook failure is logged by its owner and never aborts later hooks
        }
      }
    } finally {
      _running = false;
    }
  }
}

final lifecycleRunnerProvider = Provider<LifecycleRunner>((ref) => LifecycleRunner(ref));

/// Wraps the app: triggers the hook chain on first authenticated frame, on login and on every resume.
class LifecycleCoordinator extends ConsumerStatefulWidget {
  const LifecycleCoordinator({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<LifecycleCoordinator> createState() => _LifecycleCoordinatorState();
}

class _LifecycleCoordinatorState extends ConsumerState<LifecycleCoordinator> {
  late final AppLifecycleListener _listener;

  @override
  void initState() {
    super.initState();
    _listener = AppLifecycleListener(onResume: () => ref.read(lifecycleRunnerProvider).run());
  }

  @override
  void dispose() {
    _listener.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<AsyncValue<AuthState>>(authControllerProvider, (previous, next) {
      if (next.valueOrNull is Authenticated && previous?.valueOrNull is! Authenticated) {
        ref.read(lifecycleRunnerProvider).run(force: true);
      }
    });
    return widget.child;
  }
}

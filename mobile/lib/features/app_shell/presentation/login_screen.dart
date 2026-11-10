import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/app_error.dart';
import '../domain/auth_state.dart';
import 'providers.dart';

enum _LoginPhase { idle, submitting, error }

/// Email + password login (P1: no sign-up, no reset). app_shell spec §7.3.
class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  final _formKey = GlobalKey<FormState>();
  final _email = TextEditingController();
  final _password = TextEditingController();
  _LoginPhase _phase = _LoginPhase.idle;
  String? _error;

  @override
  void initState() {
    super.initState();
    ref.read(tokenStoreProvider).lastEmail().then((email) {
      if (mounted && email != null && _email.text.isEmpty) _email.text = email;
    });
  }

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  String _messageFor(AppError e) => switch (e) {
        UnauthorizedError() => 'Wrong email or password',
        NetworkError() => "You're offline. Check your connection and retry.",
        ServerWakingTimeout() => "The server didn't wake up in time. Retry.",
        ValidationError() => 'Enter a valid email and password.',
        _ => 'The server is unavailable. Retry.',
      };

  Future<void> _submit() async {
    if (_phase == _LoginPhase.submitting) return;
    if (!(_formKey.currentState?.validate() ?? false)) return;
    setState(() {
      _phase = _LoginPhase.submitting;
      _error = null;
    });
    try {
      await ref.read(authControllerProvider.notifier).login(_email.text, _password.text);
      // The router guard moves an Authenticated user to /today.
    } on AppError catch (e) {
      if (!mounted) return;
      setState(() {
        _phase = _LoginPhase.error;
        _error = _messageFor(e);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final submitting = _phase == _LoginPhase.submitting;
    final waking = submitting && ref.watch(serverStatusProvider) == ServerStatus.waking;
    final auth = ref.watch(authControllerProvider).valueOrNull;
    final reason = auth is Unauthenticated ? auth.reason : null;

    return Scaffold(
      appBar: AppBar(title: const Text('Daily Assistant')),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Form(
                key: _formKey,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (reason != null)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 16),
                        child: Text(reason, key: const Key('login-reason')),
                      ),
                    TextFormField(
                      key: const Key('login-email'),
                      controller: _email,
                      keyboardType: TextInputType.emailAddress,
                      autofillHints: const [AutofillHints.email],
                      decoration: const InputDecoration(labelText: 'Email'),
                      validator: (v) {
                        final value = (v ?? '').trim();
                        if (value.isEmpty) return 'Email is required';
                        if (!value.contains('@')) return 'Enter a valid email';
                        return null;
                      },
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      key: const Key('login-password'),
                      controller: _password,
                      obscureText: true,
                      autofillHints: const [AutofillHints.password],
                      decoration: const InputDecoration(labelText: 'Password'),
                      validator: (v) => (v ?? '').isEmpty ? 'Password is required' : null,
                      onFieldSubmitted: (_) => _submit(),
                    ),
                    const SizedBox(height: 16),
                    if (_error != null)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: Text(
                          _error!,
                          key: const Key('login-error'),
                          style: TextStyle(color: Theme.of(context).colorScheme.error),
                        ),
                      ),
                    if (waking)
                      const Padding(
                        padding: EdgeInsets.only(bottom: 12),
                        child: Text(
                          'Waking server… this can take up to a minute',
                          key: Key('login-waking'),
                        ),
                      ),
                    FilledButton(
                      key: const Key('login-submit'),
                      onPressed: submitting ? null : _submit,
                      child: Text(submitting ? 'Logging in…' : (_phase == _LoginPhase.error ? 'Retry' : 'Log in')),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/app_error.dart';
import '../domain/app_settings.dart';
import 'providers.dart';
import 'widgets/async_value_view.dart';

final _emailPattern = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$');

/// Empty (= clear) or a plausible address (app_shell spec §7.4).
String? validateReportEmail(String? value) {
  final v = (value ?? '').trim();
  if (v.isEmpty) return null;
  return _emailPattern.hasMatch(v) ? null : 'Enter a valid email address';
}

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key, this.focusReportEmail = false});

  /// `/settings?focus=report_email` autofocuses the report email field.
  final bool focusReportEmail;

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  final _formKey = GlobalKey<FormState>();
  final _reportEmail = TextEditingController();
  String? _loadedEmail;
  bool _seeded = false;

  @override
  void dispose() {
    _reportEmail.dispose();
    super.dispose();
  }

  void _snack(String message) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _saveEmail() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    final text = _reportEmail.text.trim();
    try {
      await ref.read(settingsControllerProvider.notifier).setReportEmail(text.isEmpty ? null : text);
      _snack(text.isEmpty ? 'Report email cleared' : 'Report email saved');
    } on AppError catch (e) {
      _snack(e.userMessage);
    }
  }

  Future<void> _syncTimezone() async {
    try {
      await ref.read(settingsControllerProvider.notifier).syncTimezoneFromDevice();
    } on AppError catch (e) {
      _snack(e.userMessage);
    }
  }

  Future<void> _confirmLogout() async {
    final ok = await showModalBottomSheet<bool>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('Log out of this device?'),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Cancel')),
                  const SizedBox(width: 8),
                  FilledButton(
                    key: const Key('logout-confirm'),
                    onPressed: () => Navigator.of(ctx).pop(true),
                    child: const Text('Log out'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
    if (ok == true) await ref.read(authControllerProvider.notifier).logout();
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsControllerProvider);
    final email = ref.watch(storedEmailProvider).valueOrNull;

    // Seed the text field once per loaded value (never overwrite what the user is typing).
    final loaded = settings.value;
    if (loaded != null && (!_seeded || _loadedEmail != loaded.reportEmail)) {
      if (!_seeded || _reportEmail.text.trim() == (_loadedEmail ?? '')) {
        _reportEmail.text = loaded.reportEmail ?? '';
      }
      _loadedEmail = loaded.reportEmail;
      _seeded = true;
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: AsyncValueView<AppSettings>(
        value: settings,
        onRetry: () => ref.invalidate(settingsControllerProvider),
        data: (s) => ListView(
          children: [
            const _SectionHeader('Account'),
            ListTile(
              title: Text(email ?? 'Logged in', key: const Key('account-email')),
              trailing: TextButton(
                key: const Key('logout-button'),
                onPressed: _confirmLogout,
                child: const Text('Log out'),
              ),
            ),
            const _SectionHeader('Time zone'),
            _TimezoneTile(settings: s, onSync: _syncTimezone),
            const _SectionHeader('Reminders'),
            ListTile(title: Text(s.reminderSummary, key: const Key('reminder-summary'))),
            const _SectionHeader('Report email'),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Form(
                key: _formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    TextFormField(
                      key: const Key('report-email-field'),
                      controller: _reportEmail,
                      autofocus: widget.focusReportEmail,
                      keyboardType: TextInputType.emailAddress,
                      decoration: const InputDecoration(
                        labelText: 'Email address',
                        helperText: "Reports are only emailed when you tap 'Email this report'.",
                        helperMaxLines: 2,
                      ),
                      validator: validateReportEmail,
                    ),
                    const SizedBox(height: 8),
                    FilledButton(
                      key: const Key('report-email-save'),
                      onPressed: _saveEmail,
                      child: const Text('Save'),
                    ),
                  ],
                ),
              ),
            ),
            const _SectionHeader('Schedule'),
            const ListTile(
              title: Text('Weekly fixed schedule'),
              subtitle: Text('Available in a later update'),
              enabled: false,
            ),
            ...ref.watch(settingsExtraSectionsProvider),
            const _SectionHeader('About'),
            ListTile(
              title: Text(ref.watch(appConfigProvider).apiBaseUrl.host, key: const Key('about-host')),
              subtitle: const Text(String.fromEnvironment('APP_VERSION', defaultValue: 'dev build')),
            ),
          ],
        ),
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.title);

  final String title;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
        child: Text(title, style: Theme.of(context).textTheme.titleSmall),
      );
}

class _TimezoneTile extends ConsumerWidget {
  const _TimezoneTile({required this.settings, required this.onSync});

  final AppSettings settings;
  final VoidCallback onSync;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final device = ref.watch(deviceTimezoneProvider);
    final differs = device != settings.timezone;
    return ListTile(
      title: Text('Server: ${settings.timezone}', key: const Key('tz-server')),
      subtitle: Text('Device: $device'),
      trailing: differs
          ? TextButton(
              key: const Key('tz-sync'),
              onPressed: onSync,
              child: Text('Use device time zone ($device)'),
            )
          : null,
    );
  }
}

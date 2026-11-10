import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers.dart';
import 'empty_view.dart';
import 'error_view.dart';

/// loading / waking / error / empty / content convention (app_shell spec §7.5).
class AsyncValueView<T> extends ConsumerWidget {
  const AsyncValueView({
    super.key,
    required this.value,
    required this.data,
    this.isEmpty,
    this.empty,
    this.onRetry,
  });

  final AsyncValue<T> value;
  final Widget Function(T data) data;
  final bool Function(T data)? isEmpty;
  final Widget? empty;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (value.hasValue) {
      final v = value.requireValue;
      if (isEmpty?.call(v) ?? false) return empty ?? const EmptyView(message: 'Nothing here yet.');
      final content = data(v);
      if (value.isLoading) {
        // refresh keeps the old content visible with a progress bar on top
        return Column(
          children: [
            const LinearProgressIndicator(key: Key('refresh-progress')),
            Expanded(child: content),
          ],
        );
      }
      return content;
    }
    if (value.hasError) return ErrorView(error: value.error!, onRetry: onRetry);

    final waking = ref.watch(serverStatusProvider) == ServerStatus.waking;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const CircularProgressIndicator(),
          if (waking) ...[
            const SizedBox(height: 16),
            const Text('Waking server… this can take up to a minute', key: Key('waking-text')),
          ],
        ],
      ),
    );
  }
}

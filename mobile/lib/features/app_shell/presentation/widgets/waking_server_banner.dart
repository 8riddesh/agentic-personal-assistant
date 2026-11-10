import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers.dart';

/// Shown above the content while the server wakes up or the phone is offline.
class WakingServerBanner extends ConsumerWidget {
  const WakingServerBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(serverStatusProvider);
    if (status == ServerStatus.ok) return const SizedBox.shrink();
    final waking = status == ServerStatus.waking;
    return Material(
      color: Theme.of(context).colorScheme.secondaryContainer,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          children: [
            Icon(waking ? Icons.hourglass_top : Icons.cloud_off, size: 18),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                waking
                    ? 'Waking server… this can take up to a minute'
                    : 'Offline — changes to notification answers will sync later',
                key: Key(waking ? 'waking-banner' : 'offline-banner'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

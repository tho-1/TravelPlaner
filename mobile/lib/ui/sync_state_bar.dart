/// The offline / sync-state line (offline-first Phase 5,
/// commit 3).
///
/// One thin strip above the content, and only when it has
/// something true to say: how many writes are owed, what the
/// last drain did, or that the last change could not sync
/// because another device got there first. A bar that is
/// always visible is a bar nobody reads.
library;

import 'package:flutter/material.dart';

class SyncStateBar extends StatelessWidget {
  /// Writes still queued in the journal.
  final int pending;

  /// What the last drain reported (oldest first) -- a
  /// conflict or a dropped op is stated here, never hidden.
  final List<String> notes;

  /// Replays the queue now; null while a drain is running.
  final VoidCallback? onSyncNow;

  const SyncStateBar({
    super.key,
    required this.pending,
    this.notes = const [],
    this.onSyncNow,
  });

  bool get _visible => pending > 0 || notes.isNotEmpty;

  @override
  Widget build(BuildContext context) {
    if (!_visible) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final queued = pending > 0;
    final detail = notes.isEmpty ? null : notes.first;
    return Material(
      color: queued
          ? theme.colorScheme.tertiaryContainer
          : theme.colorScheme.surfaceContainerHighest,
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 6, 4, 6),
          child: Row(
            children: [
              Icon(
                queued ? Icons.cloud_sync_outlined : Icons.sync_problem,
                size: 18,
                color: theme.colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  _message(queued, detail),
                  style: theme.textTheme.bodySmall,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (queued)
                TextButton(
                  onPressed: onSyncNow,
                  child: const Text('Sync now'),
                ),
            ],
          ),
        ),
      ),
    );
  }

  String _message(bool queued, String? detail) {
    if (!queued) return detail ?? '';
    final count = '$pending change${pending == 1 ? '' : 's'} '
        'waiting to sync';
    return detail == null ? count : '$count — $detail';
  }
}

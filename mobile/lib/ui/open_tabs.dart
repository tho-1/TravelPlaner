/// The open-destination tabs UI: a floating button that
/// holds the open items (report i, 2026-10-16).
///
/// The old surfaces -- a 200 px side panel on the desktop
/// and a 44 px chip strip on the phone -- spent permanent
/// screen space on a list that is consulted occasionally.
/// The replacement is one floating button showing the open
/// count (the card-stack motif: the items are a stack you
/// pick up when you need it). Tapping opens the list in a
/// bottom sheet with the same rows as the legacy sidebar:
/// name, favourite star, the per-row close (the own),
/// plus "Close all".
///
/// The shell still owns the list and its persistence; these
/// are view-only widgets. `problems` non-empty means the
/// persisted list could not be read -- shown as a warning,
/// never presented as "no tabs open".
library;

import 'package:flutter/material.dart';

import '../data/catalogue_match.dart';
import '../models/destination.dart';

/// Records a destination as "opened" (the shell persists
/// the tab list). Null when the feature is off, so the
/// push sites skip the recording entirely.
typedef OpenDestinationCallback = void Function(String name);

/// The floating button: the stack icon with the open count.
/// Shown whenever there is something to show -- tabs, or a
/// read problem the user must see.
class OpenTabsFab extends StatelessWidget {
  final int count;
  final bool hasProblems;
  final VoidCallback onPressed;

  const OpenTabsFab({
    super.key,
    required this.count,
    required this.hasProblems,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return FloatingActionButton(
      onPressed: onPressed,
      tooltip: count == 0
          ? 'Open destinations (read problem)'
          : 'Open destinations ($count)',
      child: Badge(
        isLabelVisible: count > 0 || hasProblems,
        label: hasProblems && count == 0
            ? const Icon(Icons.cloud_off, size: 12, color: Colors.white)
            : Text('$count'),
        backgroundColor: hasProblems ? scheme.error : scheme.primaryContainer,
        child: const Icon(Icons.layers_outlined),
      ),
    );
  }
}

class _TabRow extends StatelessWidget {
  final String name;
  final Destination? destination;
  final bool active;
  final VoidCallback onOpen;
  final VoidCallback onClose;

  const _TabRow({
    required this.name,
    required this.destination,
    required this.active,
    required this.onOpen,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: active ? scheme.secondaryContainer : Colors.transparent,
      child: InkWell(
        onTap: onOpen,
        child: Row(
          children: [
            const SizedBox(width: 8),
            (destination?.favourite ?? false)
                ? const Icon(Icons.star, size: 15, color: Color(0xFFF6B100))
                : (destination?.country != null &&
                        CountryNames.flagFor(destination!.country!).isNotEmpty)
                    ? Text(CountryNames.flagFor(destination!.country!),
                        style: const TextStyle(fontSize: 14))
                    : Icon(Icons.location_on_outlined,
                        size: 15, color: scheme.onSurfaceVariant),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(6, 7, 2, 7),
                child: Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ),
            ),
            // The legacy sidebar's per-row ✖: closes the tab
            // (and pops the destination's page when it is the
            // one on top).
            SizedBox(
              width: 30,
              height: 30,
              child: IconButton(
                padding: EdgeInsets.zero,
                iconSize: 15,
                tooltip: 'Close $name',
                icon: const Icon(Icons.close),
                onPressed: onClose,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The phone sheet's replacement and the desktop panel's:
/// the open rows in a bottom sheet, with the close-all
/// action. A failed read is a warning row at the top --
/// invariant: never silently "no tabs".
class OpenTabsSheet extends StatelessWidget {
  final List<String> tabs;
  final Map<String, Destination> destinations;
  final String? active;
  final List<String> problems;
  final void Function(String name) onOpen;
  final void Function(String name) onClose;
  final VoidCallback onCloseAll;

  const OpenTabsSheet({
    super.key,
    required this.tabs,
    required this.destinations,
    required this.active,
    required this.problems,
    required this.onOpen,
    required this.onClose,
    required this.onCloseAll,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SafeArea(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 420),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      'Open destinations',
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                    ),
                  ),
                   IconButton(
                    icon: const Icon(Icons.close, size: 18),
                    tooltip: 'Close',
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),
            if (problems.isNotEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  children: [
                    Icon(Icons.cloud_off, size: 16, color: scheme.error),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        problems.join(' '),
                        style: Theme.of(context)
                            .textTheme
                            .bodySmall
                            ?.copyWith(color: scheme.error),
                      ),
                    ),
                  ],
                ),
              ),
            Flexible(
              child: tabs.isEmpty
                  ? const Padding(
                      padding: EdgeInsets.all(16),
                      child:
                          Text('Destinations you open collect here.'),
                    )
                  : ListView(
                      shrinkWrap: true,
                      padding: const EdgeInsets.only(bottom: 8),
                      children: [
                        for (final name in tabs)
                          _TabRow(
                            name: name,
                            destination: destinations[name],
                            active: name == active,
                            onOpen: () => onOpen(name),
                            onClose: () => onClose(name),
                          ),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

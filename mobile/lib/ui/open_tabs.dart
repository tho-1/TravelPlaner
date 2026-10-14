/// The open-destination tabs UI: a side panel on the
/// desktop (the legacy Streamlit sidebar's list, ported)
/// and a chip strip above the content on the phone.
///
/// Both surfaces are view-only widgets: the shell owns the
/// list and its persistence, exactly the way the pages
/// own none of the data they render. Every row states what
/// it is -- name, favourite star when known -- and every
/// row closes (the ✖), like the legacy sidebar's rows.
library;

import 'package:flutter/material.dart';

import '../models/destination.dart';

/// Records a destination as "opened" (the shell persists
/// the tab list). Null when the feature is off, so the
/// push sites skip the recording entirely.
typedef OpenDestinationCallback = void Function(String name);

/// The desktop side panel: the legacy sidebar's
/// "Open destinations" block. `problems` non-empty means
/// the persisted list could not be read -- shown as a
/// warning on the header (a failed read is never
/// silently presented as "no tabs open").
class OpenTabsPanel extends StatelessWidget {
  final List<String> tabs;
  final Map<String, Destination> destinations;
  final String? active;
  final List<String> problems;
  final void Function(String name) onOpen;
  final void Function(String name) onClose;

  const OpenTabsPanel({
    super.key,
    required this.tabs,
    required this.destinations,
    required this.active,
    required this.problems,
    required this.onOpen,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      width: 200,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 4, 4),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'Open destinations',
                    style: Theme.of(context).textTheme.labelLarge?.copyWith(
                          color: scheme.onSurfaceVariant,
                          fontWeight: FontWeight.w700,
                        ),
                  ),
                ),
                if (problems.isNotEmpty)
                  Tooltip(
                    message: problems.join('\n'),
                    child: Icon(Icons.cloud_off,
                        size: 16, color: scheme.error),
                  ),
              ],
            ),
          ),
          Expanded(
            child: tabs.isEmpty
                ? Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Text(
                      'Destinations you open collect here.',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  )
                : ListView(
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
            Icon(
              destination?.favourite ?? false
                  ? Icons.star
                  : Icons.location_on_outlined,
              size: 15,
              color: destination?.favourite ?? false
                  ? const Color(0xFFF6B100)
                  : scheme.onSurfaceVariant,
            ),
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

/// The phone strip: one closeable chip per open tab,
/// horizontally scrollable, pinned above the tab pages.
class OpenTabsStrip extends StatelessWidget {
  final List<String> tabs;
  final String? active;
  final void Function(String name) onOpen;
  final void Function(String name) onClose;

  const OpenTabsStrip({
    super.key,
    required this.tabs,
    required this.active,
    required this.onOpen,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      height: 44,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
        child: Row(
          children: [
            for (final name in tabs)
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: InputChip(
                  label: Text(name),
                  avatar: Icon(
                    Icons.location_on_outlined,
                    size: 15,
                    color: name == active
                        ? scheme.onSecondaryContainer
                        : scheme.onSurfaceVariant,
                  ),
                  selected: name == active,
                  // The same ✖ the desktop panel's rows use.
                  deleteIcon: const Icon(Icons.close, size: 15),
                  visualDensity: VisualDensity.compact,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  onPressed: () => onOpen(name),
                  onDeleted: () => onClose(name),
                  deleteButtonTooltipMessage: 'Close $name',
                ),
              ),
          ],
        ),
      ),
    );
  }
}

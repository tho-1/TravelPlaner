/// App settings. One page, reachable from the catalogue's
/// app bar; the shell owns the values and persists them,
/// the page only renders and reports changes.
library;

import 'package:flutter/material.dart';

class SettingsPage extends StatefulWidget {
  /// Whether opening a destination records an
  /// open-destination tab.
  final bool openTabsEnabled;

  /// Persist the new value; returns whether it was saved.
  /// The page keeps its own switch position until the write
  /// confirms -- the page is a pushed route and does not
  /// rebuild with the shell, so without local state the
  /// switch stayed in its push-time position (the bug found
  /// on the phone 2026-10-14: tapping looked inert, and a
  /// second tap flipped the setting back).
  final Future<bool> Function(bool value) onToggleTabs;

  const SettingsPage({
    super.key,
    required this.openTabsEnabled,
    required this.onToggleTabs,
  });

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late var _enabled = widget.openTabsEnabled;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        children: [
          SwitchListTile(
            title: const Text('Open-destination tabs'),
            subtitle: const Text(
              'Destinations you open collect into a closeable '
              'list -- a side panel on the desktop, a chip '
              'strip on the phone. The list lives in Turso '
              'and survives a restart; the switch itself is '
              'stored per device.',
            ),
            value: _enabled,
            onChanged: (value) async {
              // Move the switch only once the write confirmed
              // -- a failed save must not look saved.
              final saved = await widget.onToggleTabs(value);
              if (saved && mounted) {
                setState(() => _enabled = value);
              }
            },
          ),
        ],
      ),
    );
  }
}

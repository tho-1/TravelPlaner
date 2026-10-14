/// App settings. One page, reachable from the catalogue's
/// app bar; the shell owns the values and persists them,
/// the page only renders and reports changes.
library;

import 'package:flutter/material.dart';

class SettingsPage extends StatelessWidget {
  /// Whether opening a destination records an
  /// open-destination tab.
  final bool openTabsEnabled;
  final ValueChanged<bool> onToggleTabs;

  const SettingsPage({
    super.key,
    required this.openTabsEnabled,
    required this.onToggleTabs,
  });

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
            value: openTabsEnabled,
            onChanged: onToggleTabs,
          ),
        ],
      ),
    );
  }
}

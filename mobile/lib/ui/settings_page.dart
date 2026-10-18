/// App settings. One page, reachable from the catalogue's
/// app bar; the shell owns the values and persists them,
/// the page only renders and reports changes.
library;

import 'package:flutter/material.dart';

import 'error_log_page.dart';

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

  /// The configured API keys: name -> (label, configured,
  /// masked value). Shown so the user can see which keys are
  /// set and rotate any of them.
  final Map<String, (String label, bool configured, String masked)> apiKeys;

  /// Rotate one key: persist the new value (empty clears it),
  /// returns whether the write succeeded. Rebuilding the
  /// clients is the shell's job.
  final Future<bool> Function(String name, String value) onRotateKey;

  const SettingsPage({
    super.key,
    required this.openTabsEnabled,
    required this.onToggleTabs,
    required this.apiKeys,
    required this.onRotateKey,
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
              'list behind a floating button (the stack icon '
              'with the count). The list lives in Turso '
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
          const Divider(),
          ..._apiKeys(),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.bug_report_outlined),
            title: const Text('Error log'),
            subtitle: const Text(
              'What the app recorded when something failed -- '
              'for analysis afterwards.',
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(MaterialPageRoute(
              settings: const RouteSettings(name: 'error-log'),
              builder: (_) => const ErrorLogPage(),
            )),
          ),
        ],
      ),
    );
  }

  /// One row per API key: label, configured status, masked
  /// value, and an edit affordance. Tapping opens a dialog
  /// where the user can replace or clear the key.
  List<Widget> _apiKeys() {
    final out = <Widget>[];
    out.add(const Padding(
      padding: EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Text('API keys',
          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
    ));
    for (final entry in widget.apiKeys.entries) {
      final (label, configured, masked) = entry.value;
      out.add(ListTile(
        leading: Icon(
          configured ? Icons.lock_outline : Icons.lock_outlined,
          color: configured ? null : Colors.grey,
        ),
        title: Text(label),
        subtitle: Text(
          configured
              ? masked
              : 'Not set — tap to add the ${_article(label)} key.',
        ),
        trailing: const Icon(Icons.edit, size: 20),
        onTap: () => _editKey(entry.key, label),
        dense: true,
      ));
    }
    return out;
  }

  static String _article(String label) {
    final first = label.toLowerCase();
    return 'aeiou'.contains(first[0]) ? 'an' : 'a';
  }

  /// Open a dialog to replace or clear one key. An empty
  /// value clears the override, so the bundled value (if any)
  /// applies again.
  Future<void> _editKey(String name, String label) async {
    final controller = TextEditingController();
    final saved = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text(label),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Paste the new key, or leave empty to fall back '
              'to the bundled value.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              obscureText: true,
              enableSuggestions: false,
              autocorrect: false,
              decoration: InputDecoration(
                labelText: label,
                hintText: 'Paste key here',
                border: const OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialog).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.of(dialog).pop(true),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (saved != true || !mounted) return;
    final ok = await widget.onRotateKey(name, controller.text);
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Could not save the key.'),
      ));
    }
  }
}

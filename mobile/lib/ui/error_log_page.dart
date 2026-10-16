/// The error log viewer (report f, 2026-10-16).
///
/// The app records its failures to `error_log.jsonl` (next
/// to `app_settings.json`) precisely so that a bug seen on
/// the phone can be analysed afterwards. This page shows
/// what was recorded -- newest first, with the area, the
/// message and the details map -- and where the file is.
library;

import 'package:flutter/material.dart';

import '../data/error_log.dart';

class ErrorLogPage extends StatefulWidget {
  const ErrorLogPage({super.key});

  @override
  State<ErrorLogPage> createState() => _ErrorLogPageState();
}

class _ErrorLogPageState extends State<ErrorLogPage> {
  List<ErrorLogEntry> _entries = const [];
  List<String> _problems = const [];

  @override
  void initState() {
    super.initState();
    _reload();
  }

  void _reload() {
    final (entries, problems) = ErrorLog.instance.readAll();
    setState(() {
      _entries = entries;
      _problems = problems;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final path = ErrorLog.instance.filePath;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Error log'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Reload',
            onPressed: _reload,
          ),
          if (_entries.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.delete_outline),
              tooltip: 'Clear the log',
              onPressed: _clear,
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          Text(
            path.isEmpty
                ? 'No per-device state directory in this environment: '
                    'entries are kept in memory only.'
                : 'Recorded in $path',
            style: theme.textTheme.bodySmall,
          ),
          for (final problem in _problems)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(problem,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.error)),
            ),
          const SizedBox(height: 8),
          if (_entries.isEmpty)
            const Card(
              child: Padding(
                padding: EdgeInsets.all(12),
                child: Text('Nothing recorded yet.'),
              ),
            ),
          for (final entry in _entries)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 2),
                          decoration: BoxDecoration(
                            color: theme.colorScheme.primaryContainer,
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Text(entry.area,
                              style: theme.textTheme.labelSmall),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(_stamp(entry.at),
                              style: theme.textTheme.bodySmall),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(entry.message, style: theme.textTheme.bodyMedium),
                    if (entry.details.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(
                          entry.details.entries
                              .map((e) => '${e.key}: ${e.value}')
                              .join('\n'),
                          style: theme.textTheme.bodySmall,
                        ),
                      ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _clear() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Clear the error log?'),
        content: const Text('The recorded entries are deleted.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Clear'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    ErrorLog.instance.clear();
    if (!mounted) return;
    _reload();
  }

  static String _stamp(DateTime at) =>
      '${at.year.toString().padLeft(4, '0')}-'
      '${at.month.toString().padLeft(2, '0')}-'
      '${at.day.toString().padLeft(2, '0')} '
      '${at.hour.toString().padLeft(2, '0')}:'
      '${at.minute.toString().padLeft(2, '0')}';
}

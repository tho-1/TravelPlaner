/// The IQAir annual PM2.5 history table.
///
/// The legacy detail page ends its climate
/// dashboard with a per-year PM2.5 table for
/// the matched city: the years as columns, the
/// values in one row, and the up-to-five-year
/// average at the end. The match itself is the
/// pure [lookup] in `iqair_ranking.dart`; this
/// widget loads the snapshot (the desktop reads
/// the local cache file, Android has none and
/// the table stays hidden) and renders it.
///
/// A destination with no match, or a matched
/// city with no year values, renders nothing —
/// the legacy returns early the same way.
library;

import 'package:flutter/material.dart';

import '../data/iqair_ranking.dart';
import '../data/iqair_repository.dart';
import '../turso/config.dart';

class IqairPm25Table extends StatefulWidget {
  final String destinationName;
  final String? country;

  const IqairPm25Table({
    super.key,
    required this.destinationName,
    this.country,
  });

  @override
  State<IqairPm25Table> createState() => _IqairPm25TableState();
}

class _IqairPm25TableState extends State<IqairPm25Table> {
  IqairResult? _result;
  var _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final config = await TursoConfig.load();
    final path = config.iqairSnapshot;
    if (path.isNotEmpty) {
      final repository = IqairRepository(path);
      final cities = await repository.load();
      if (cities.isNotEmpty) {
        final index = IqairIndex.build(cities);
        final result = lookup(
          widget.destinationName,
          index,
          country: widget.country,
        );
        if (mounted) {
          setState(() {
            _result = result;
            _loading = false;
          });
        }
        return;
      }
    }
    if (mounted) setState(() => _loading = false);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (_loading) {
      return const SizedBox.shrink();
    }
    final result = _result;
    final entry = result?.entry;
    // Only a city/capital match with year values
    // renders — the legacy's early returns.
    if (result == null ||
        !result.matched ||
        entry == null ||
        entry.pm25.isEmpty) {
      return const SizedBox.shrink();
    }

    final years = entry.pm25.keys.toList()
      ..sort((a, b) => b.compareTo(a));
    final matchedCity = entry.city;
    final matchedCountry = entry.country;
    final rank = result.rank;
    final via = result.via;
    final avg = result.pm25Avg;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('IQAir Annual PM2.5 (µg/m³)',
                style: theme.textTheme.titleSmall),
            const SizedBox(height: 2),
            Text(
              '$matchedCity'
                  '${via == null ? '' : ' (via $via)'}'
                  ', $matchedCountry'
                  '${rank == null ? '' : ' · World Rank #${_formatRank(rank)}'}',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Table(
                defaultColumnWidth:
                    const FixedColumnWidth(64),
                children: [
                  TableRow(
                    children: [
                      _cell('PM2.5 (µg/m³)',
                          theme,
                          header: true,
                          align: TextAlign.left),
                      for (final year in years)
                        _cell(year, theme, header: true),
                      _cell('5-Yr Avg', theme,
                          header: true, strong: true),
                    ],
                  ),
                  TableRow(
                    children: [
                      _cell('PM2.5', theme),
                      for (final year in years)
                        _cell(
                          entry.pm25[year] == null
                              ? '—'
                              : entry.pm25[year]!
                                  .toStringAsFixed(1),
                          theme,
                        ),
                      _cell(
                        avg == null
                            ? '—'
                            : avg.toStringAsFixed(1),
                        theme,
                        strong: true,
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _cell(String text, ThemeData theme,
      {bool header = false,
      bool strong = false,
      TextAlign align = TextAlign.center}) {
    return Padding(
      padding: const EdgeInsets.symmetric(
          horizontal: 8, vertical: 6),
      child: Text(
        text,
        textAlign: align,
        style: (header
                ? theme.textTheme.labelMedium
                : theme.textTheme.bodyMedium)
            ?.copyWith(
          fontWeight:
              strong ? FontWeight.bold : null,
        ),
      ),
    );
  }

  static String _formatRank(int rank) {
    final digits = rank.toString();
    final buffer = StringBuffer();
    for (var i = 0; i < digits.length; i++) {
      if (i > 0 && (digits.length - i) % 3 == 0) {
        buffer.write(',');
      }
      buffer.write(digits[i]);
    }
    return buffer.toString();
  }
}

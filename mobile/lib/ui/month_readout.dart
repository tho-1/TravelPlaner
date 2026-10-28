/// The readout under a monthly chart: the month a tap
/// selected, and its values.
///
/// Both charts used to answer a tap with one grey `bodySmall`
/// line, and nothing in the chart itself changed — on a phone
/// that is easy to miss completely, and the reader concluded
/// the feature was not working (the report, 2026-10-28). The
/// answer is now a filled card with the month as its title,
/// and the charts highlight the tapped column as well.
library;

import 'package:flutter/material.dart';

/// What the chart says about a tap it has not had yet.
const monthTapHint = 'Tap a month to see its values.';

/// One value in the readout: a name, the figure, and the
/// series colour the figure belongs to (null when the series
/// has no colour of its own).
class MonthFact {
  final String label;
  final String value;
  final Color? color;

  const MonthFact({required this.label, required this.value, this.color});
}

/// A month and its facts, in a card the reader cannot miss.
class MonthReadout extends StatelessWidget {
  /// The month's name ("June").
  final String month;

  /// The figures, in the chart's own order.
  final List<MonthFact> facts;

  const MonthReadout({super.key, required this.month, required this.facts});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: scheme.secondaryContainer,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: scheme.primary.withValues(alpha: 0.4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.calendar_month,
                  size: 16, color: scheme.onSecondaryContainer),
              const SizedBox(width: 6),
              Text(
                month,
                style: theme.textTheme.titleSmall?.copyWith(
                  color: scheme.onSecondaryContainer,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 16,
            runSpacing: 6,
            children: [
              for (final fact in facts) _Fact(fact: fact),
            ],
          ),
        ],
      ),
    );
  }
}

class _Fact extends StatelessWidget {
  final MonthFact fact;

  const _Fact({required this.fact});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (fact.color != null) ...[
          Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(
              color: fact.color,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 5),
        ],
        Text(
          fact.label,
          style: theme.textTheme.bodySmall?.copyWith(
            color: scheme.onSecondaryContainer.withValues(alpha: 0.75),
          ),
        ),
        const SizedBox(width: 5),
        Text(
          fact.value,
          style: theme.textTheme.labelLarge?.copyWith(
            color: scheme.onSecondaryContainer,
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    );
  }
}

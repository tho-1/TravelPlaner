/// Widget smoke test: the unconfigured app is a normal state (the
/// config file is git-ignored) and must render an explanation, not
/// crash. Configured shells are covered by the repository tests --
/// a configured HomeShell would fire real network calls.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:travel_planner/turso/config.dart';
import 'package:travel_planner/ui/main.dart';

void main() {
  testWidgets('an unconfigured app explains itself instead of crashing',
      (tester) async {
    await tester.pumpWidget(TravelPlannerApp(
      config: const TursoConfig(url: 'https://db.example.turso.io', token: ''),
    ));
    await tester.pump();

    expect(find.text('Not configured'), findsOneWidget);
    expect(
      find.textContaining('assets/turso_config.json'),
      findsOneWidget,
    );
  });
}

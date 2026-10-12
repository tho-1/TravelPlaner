/// Live verification of the parity features
/// against the real Turso data.
///
/// The config (`assets/turso_config.json`) is
/// git-ignored, so the whole group skips on a
/// fresh checkout and on CI. Where it exists,
/// the checks run against the real catalogue
/// and the real trips: the country grouping
/// must preserve every destination and keep
/// the sections sorted, and the backup export
/// must produce the store shape.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'package:travel_planner/data/catalogue_match.dart';
import 'package:travel_planner/data/destination_repository.dart';
import 'package:travel_planner/data/trip_repository.dart';
import 'package:travel_planner/models/trip_ops.dart';
import 'package:travel_planner/turso/config.dart';
import 'package:travel_planner/turso/pipeline_client.dart';

void main() {
  final configFile = File('assets/turso_config.json');
  final exists = configFile.existsSync();
  late TursoConfig config;

  setUpAll(() {
    if (!exists) return;
    final map =
        jsonDecode(configFile.readAsStringSync()) as Map<String, dynamic>;
    config = TursoConfig(
      url: (map['url'] as String?)?.trim() ?? '',
      token: (map['token'] as String?)?.trim() ?? '',
    );
  });

  group('live Turso data', () {
    test('the catalogue grouping preserves every destination',
        () async {
      if (!exists) return;
      final client =
          TursoClient(config, httpClient: http.Client());
      final (destinations, problems) =
          await DestinationRepository(client).loadDestinations();
      expect(problems, isEmpty);
      expect(destinations.length, greaterThan(100));
      final groups = groupByCountry(destinations);
      // Every destination survives the grouping,
      // in its own country's section.
      final grouped = [
        for (final group in groups) ...group.destinations,
      ];
      expect(grouped.length, destinations.length);
      for (final group in groups) {
        for (final dest in group.destinations) {
          expect((dest.country ?? '').trim(), group.country ?? '');
        }
      }
      // The sections are sorted by country
      // (case-insensitive), the blank country
      // first.
      for (var i = 1; i < groups.length; i++) {
        final previous = (groups[i - 1].country ?? '').toLowerCase();
        final current = (groups[i].country ?? '').toLowerCase();
        expect(previous.compareTo(current),
            lessThanOrEqualTo(0));
      }
    });

    test('the backup export is the store shape', () async {
      if (!exists) return;
      final client =
          TursoClient(config, httpClient: http.Client());
      final (trips, problems) =
          await TripRepository(client).loadTrips();
      expect(problems, isEmpty);
      final json = exportTrips(trips);
      final decoded = jsonDecode(json) as Map<String, dynamic>;
      expect(decoded['schema_version'], 1);
      expect((decoded['trips'] as List).length, trips.length);
    });
  });
}

/// The finder end to end with a faked board: five windowed
/// queries in, one explainable report out. No network, no
/// assets (the lookup and the flags are installed).
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:travel_planner/data/weekend_repository.dart';
import 'package:travel_planner/models/airline_benefits.dart';
import 'package:travel_planner/models/timetable.dart';
import 'package:travel_planner/models/weekend_match.dart';

final friday = DateTime(2026, 10, 16);

http.Client _board() => MockClient((request) async {
      final direction = request.url.queryParameters['flighttype']!;
      final page = int.parse(request.url.queryParameters['page']!);
      if (page > 1) {
        // The walk stops when a page comes back empty.
        return http.Response(
          jsonEncode({'data': const []}),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }
      final List<Map<String, Object?>> records;
      switch (direction) {
        case 'departures':
          records = [
            {
              'al': 'LH',
              'fnr': 'LH1000',
              'iata': 'LHR',
              'sched': '2026-10-16T15:10:00+0200',
              'schedArr': '2026-10-16T15:55:00+0100',
            },
            // Out of the window (Friday before 14:00) -- the
            // provider's cursor already excludes it, but the
            // matcher must not see it either.
            {
              'al': 'LH',
              'fnr': 'LH999',
              'iata': 'LHR',
              'sched': '2026-10-16T09:00:00+0200',
            },
          ];
        default: // arrivals
          records = [
            {
              'al': 'LH',
              'fnr': 'LH2000',
              'iata': 'LHR',
              'sched': '2026-10-17T19:30:00+0200',
              'schedDep': '2026-10-17T17:30:00+0100',
            },
          ];
      }
      return http.Response(
        jsonEncode({'data': records}),
        200,
        headers: {'content-type': 'application/json; charset=utf-8'},
      );
    });

const _benefits = (
  flags: {'LH': true, 'lufthansa': true},
  records: <AirlineRecord>[],
  sourceLabel: 'fake',
  problems: <String>[],
);

void main() {
  setUp(() {
    AirportLookup.installForTesting({
      'LHR': ('London', 'GB'),
      'CDG': ('Paris', 'FR'),
    });
  });

  test('a qualifying pair reaches the report as one city', () async {
    final repository =
        WeekendRepository(FraportBoardProvider(httpClient: _board(), throttleSeconds: 0));
    final result = await repository.search(
        Weekend(friday), const Windows(), _benefits);
    expect(result.report.notes, isEmpty);
    expect(result.report.cityCount, 1);
    final city = result.report.cities.single;
    expect(city.city, 'London');
    expect(city.country, 'GB');
    expect(city.count, 1);
    expect(city.options.single.outFlight.flightNo, 'LH1000');
    expect(city.options.single.backFlight.flightNo, 'LH2000');
    expect(city.options.single.nights, 1);
    // The early outbound never entered the window.
    expect(result.report.outboundTotal, 1);
  });

  test('an airline without benefits explains itself in the report', () async {
    final repository = WeekendRepository(
        FraportBoardProvider(httpClient: _board(), throttleSeconds: 0));
    final result = await repository.search(Weekend(friday), const Windows(), (
      flags: const {},
      records: const <AirlineRecord>[],
      sourceLabel: 'nothing qualifies',
      problems: const ['source empty'],
    ));
    expect(result.report.cities, isEmpty);
    expect(result.report.outboundRejectedAirlines, {'LH': 1});
    expect(describeRule(result.report.outboundRejectedAirlines),
        contains('LH (1)'));
  });

  test('a board failure becomes a note, not a crash, and keeps partial legs',
      () async {
    var calls = 0;
    final client = MockClient((request) async {
      calls++;
      switch (calls) {
        case 1: // Friday departures, page 1
          return http.Response(
            jsonEncode({
              'data': [
                {
                  'al': 'LH',
                  'fnr': 'LH1000',
                  'iata': 'LHR',
                  'sched': '2026-10-16T15:10:00+0200',
                },
              ],
            }),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        case 2: // Friday departures, page 2: the walk ends
          return http.Response(
            jsonEncode({'data': const []}),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        default: // Saturday departures: the board is down
          return http.Response('board down', 503);
      }
    });
    final repository =
        WeekendRepository(FraportBoardProvider(httpClient: client, throttleSeconds: 0));
    final result = await repository.search(
        Weekend(friday), const Windows(), _benefits);
    expect(result.report.notes.single, contains('HTTP 503'));
    // The outbound that did arrive is kept; the city shows as
    // a one-way near miss instead of vanishing.
    expect(result.report.oneWayOnly.single.city, 'London');
    expect(result.report.cities, isEmpty);
  });
}

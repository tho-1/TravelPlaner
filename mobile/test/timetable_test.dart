/// The Fraport board provider: the wall-clock convention,
/// the record mapping, the cursor walk, and the loud
/// shape-change failure. HTTP is faked, so no network.
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:travel_planner/models/timetable.dart';

void main() {
  group('wallClock', () {
    test('the numeric offset is read, never applied', () {
      final moment = wallClock('2026-10-09T14:00:00+0200');
      expect(moment, DateTime(2026, 10, 9, 14, 0));
    });

    test('a zero offset does not shift the wall clock either', () {
      // The arrivals board stamps schedArr +0000 regardless
      // of the airport; the time is the destination's local.
      final moment = wallClock('2026-10-09T18:35:00+0000');
      expect(moment, DateTime(2026, 10, 9, 18, 35));
    });

    test('seconds are optional, junk is null', () {
      expect(wallClock('2026-10-09T14:00+02:00'), DateTime(2026, 10, 9, 14));
      expect(wallClock(''), isNull);
      expect(wallClock(null), isNull);
      expect(wallClock('not a stamp'), isNull);
    });
  });

  group('berlinOffsetHours', () {
    test('summer is +02:00 and winter is +01:00', () {
      expect(berlinOffsetHours(DateTime(2026, 7, 15, 12)), 2);
      expect(berlinOffsetHours(DateTime(2026, 1, 15, 12)), 1);
    });

    test('the DST boundaries are the last Sundays', () {
      // 2026: last Sunday of March is the 29th, of October the 25th.
      expect(berlinOffsetHours(DateTime(2026, 3, 29, 1, 59)), 1);
      expect(berlinOffsetHours(DateTime(2026, 3, 29, 2, 0)), 2);
      expect(berlinOffsetHours(DateTime(2026, 10, 25, 2, 59)), 2);
      expect(berlinOffsetHours(DateTime(2026, 10, 25, 3, 0)), 1);
    });
  });

  group('flightFromRecord', () {
    test('a departures record maps FRA -> the code, sched is the departure', () {
      final flight = FraportBoardProvider.flightFromRecord(
        {
          'al': 'LH',
          'fnr': 'LH 1000',
          'iata': 'lhr',
          'terminal': '1',
          'sched': '2026-10-16T15:10:00+0200',
          'schedArr': '2026-10-16T15:55:00+0100',
        },
        'departures',
      );
      expect(flight, isNotNull);
      expect(flight!.origin, 'FRA');
      expect(flight.destination, 'LHR');
      expect(flight.departure, DateTime(2026, 10, 16, 15, 10));
      expect(flight.arrival, DateTime(2026, 10, 16, 15, 55));
      expect(flight.flightNo, 'LH1000');
      expect(flight.terminal, '1');
    });

    test('an arrivals record maps the code -> FRA, sched is the arrival', () {
      final flight = FraportBoardProvider.flightFromRecord(
        {
          'al': 'LH',
          'fnr': 'LH2000',
          'iata': 'LHR',
          'sched': '2026-10-17T19:30:00+0200',
          'schedDep': '2026-10-17T17:30:00+0100',
        },
        'arrivals',
      );
      expect(flight!.origin, 'LHR');
      expect(flight.destination, 'FRA');
      expect(flight.arrival, DateTime(2026, 10, 17, 19, 30));
      expect(flight.departure, DateTime(2026, 10, 17, 17, 30));
    });

    test('a missing stops value is kept (the arrivals board never reports it)', () {
      final flight = FraportBoardProvider.flightFromRecord(
        {
          'al': 'LH',
          'fnr': 'LH2000',
          'iata': 'LHR',
          'sched': '2026-10-17T19:30:00+0200',
        },
        'arrivals',
      );
      expect(flight, isNotNull);
    });

    test('a stops value above zero is skipped', () {
      final flight = FraportBoardProvider.flightFromRecord(
        {
          'al': 'TK',
          'fnr': 'TK1',
          'iata': 'IST',
          'stops': 1,
          'sched': '2026-10-16T15:10:00+0200',
        },
        'departures',
      );
      expect(flight, isNull);
    });

    test('an arrival before the departure is pushed a day, not dropped', () {
      // schedDep is +0100 winter clock, schedArr the +0200 one --
      // the pair as the board sends it has the arrival first.
      final flight = FraportBoardProvider.flightFromRecord(
        {
          'al': 'LH',
          'fnr': 'LH2000',
          'iata': 'LHR',
          'sched': '2026-10-17T19:30:00+0200',
          'schedDep': '2026-10-17T23:30:00+0100',
        },
        'arrivals',
      );
      expect(flight!.arrival, DateTime(2026, 10, 18, 19, 30));
    });

    test('a missing flight number falls back to the airline', () {
      final flight = FraportBoardProvider.flightFromRecord(
        {
          'al': 'LH',
          'iata': 'LHR',
          'sched': '2026-10-17T19:30:00+0200',
        },
        'arrivals',
      );
      expect(flight!.flightNo, 'LH');
    });

    test('a record without airline or airport is dropped', () {
      expect(
        FraportBoardProvider.flightFromRecord(
            {'iata': 'LHR', 'sched': '2026-10-17T19:30:00+0200'}, 'arrivals'),
        isNull,
      );
      expect(
        FraportBoardProvider.flightFromRecord(
            {'al': 'LH', 'sched': '2026-10-17T19:30:00+0200'}, 'arrivals'),
        isNull,
      );
    });
  });

  group('fetch', () {
    /// A board handler: `pages` is keyed by the `page` query
    /// parameter, each entry the records of that page.
    http.Client boardHandler(Map<int, List<Map<String, Object?>>> pages) {
      return MockClient((request) async {
        final page = int.parse(request.url.queryParameters['page']!);
        final records = pages[page] ?? const [];
        return http.Response(
          jsonEncode({'data': records}),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      });
    }

    Map<String, Object?> record(String iata, String stamp) => {
          'al': 'LH',
          'fnr': 'LH${iata}1',
          'iata': iata,
          'sched': stamp,
        };

    FraportBoardProvider provider(http.Client client) =>
        FraportBoardProvider(httpClient: client, throttleSeconds: 0);

    test('the walk stops once a record passes the window end', () async {
      final result = await provider(boardHandler({
        1: [
          record('LHR', '2026-10-16T14:30:00+0200'),
          record('CDG', '2026-10-16T16:00:00+0200'),
        ],
        2: [
          record('MAD', '2026-10-16T23:00:00+0200'),
          record('IST', '2026-10-17T02:00:00+0200'), // past the end
        ],
        3: [record('DUB', '2026-10-17T05:00:00+0200')],
      })).fetch(
        DateTime(2026, 10, 16),
        'departures',
        since: DateTime(2026, 10, 16, 14),
        until: DateTime(2026, 10, 17),
      );
      expect(result.length, 3);
      expect(result.warning, isEmpty);
    });

    test('a record before the cursor is skipped', () async {
      final result = await provider(boardHandler({
        1: [
          record('LHR', '2026-10-16T13:00:00+0200'), // before the cursor
          record('CDG', '2026-10-16T14:30:00+0200'),
          record('IST', '2026-10-17T02:00:00+0200'), // past the end
        ],
      })).fetch(
        DateTime(2026, 10, 16),
        'departures',
        since: DateTime(2026, 10, 16, 14),
        until: DateTime(2026, 10, 17),
      );
      expect(result.length, 1);
    });

    test('an exhausted walk ends without a warning', () async {
      final result = await provider(boardHandler({
        1: [record('LHR', '2026-10-16T15:00:00+0200')],
        2: const [],
      })).fetch(
        DateTime(2026, 10, 16),
        'departures',
        since: DateTime(2026, 10, 16, 14),
        until: DateTime(2026, 10, 17),
      );
      expect(result.length, 1);
      expect(result.warning, isEmpty);
    });

    test('a response without a data array fails loudly', () async {
      final client = MockClient((request) async => http.Response(
            jsonEncode({'unexpected': true}),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          ));
      await expectLater(
        provider(client).fetch(
          DateTime(2026, 10, 16),
          'departures',
          since: DateTime(2026, 10, 16, 14),
          until: DateTime(2026, 10, 17),
        ),
        throwsA(isA<ProviderUnavailable>()
            .having((e) => e.message, 'message', contains('endpoint changed'))),
      );
    });

    test('an HTTP error fails loudly', () async {
      final client = MockClient((request) async => http.Response('nope', 503));
      await expectLater(
        provider(client).fetch(DateTime(2026, 10, 16), 'departures'),
        throwsA(isA<ProviderUnavailable>()
            .having((e) => e.message, 'message', contains('HTTP 503'))),
      );
    });

    test('the request mirrors the legacy provider\'s parameters', () async {
      Uri? seen;
      final client = MockClient((request) async {
        seen ??= request.url;
        return http.Response(
          jsonEncode({'data': const []}),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      });
      await provider(client).fetch(
        DateTime(2026, 10, 16),
        'departures',
        since: DateTime(2026, 10, 16, 14),
        until: DateTime(2026, 10, 17),
      );
      expect(seen!.host, 'www.frankfurt-airport.com');
      // The cursor is a Berlin-stamped wall clock: October
      // 16 is still summer time, so +02:00.
      expect(seen!.queryParameters['time'], '2026-10-16T14:00:00+02:00');
      expect(seen!.queryParameters['flighttype'], 'departures');
      expect(seen!.queryParameters['perpage'], '50');
      expect(seen!.queryParameters['page'], '1');
      expect(seen!.queryParameters['lang'], 'en');
    });
  });

  group('AeroApiBoardProvider (the fallback, report j)', () {
    AeroApiBoardProvider provider(http.Client client) => AeroApiBoardProvider(
        apiKey: 'key', httpClient: client, throttleSeconds: 0);

    final aeroRecord = <String, Object?>{
      'ident': 'DLH400',
      'operator': 'DLH',
      'flight_number': '400',
      'cancelled': false,
      'diverted': false,
      'origin': {
        'code_iata': 'FRA',
        'name': 'Frankfurt Airport',
        'terminal': '1',
      },
      'destination': {
        'code_iata': 'JFK',
        'name': 'John F Kennedy Intl',
        'terminal': '1',
      },
      'scheduled_out': '2026-10-16T12:00:00Z',
      'scheduled_on': '2026-10-16T23:30:00Z',
    };

    test('a record maps to a wall-clock Flight with the IATA operator', () {
      final flight = AeroApiBoardProvider.flightFromAeroApi(
        aeroRecord,
        'departures',
        DateTime(2026, 10, 16, 14),
        DateTime(2026, 10, 17),
      );
      expect(flight, isNotNull);
      expect(flight!.flightNo, 'DLH400');
      // The ICAO operator maps to the IATA code the rest of
      // the app is keyed by.
      expect(flight.airline, 'LH');
      expect(flight.origin, 'FRA');
      expect(flight.destination, 'JFK');
      // 12:00Z is 14:00 in Berlin (summer time).
      expect(flight.departure, DateTime(2026, 10, 16, 14));
      expect(flight.airportName, 'John F Kennedy Intl');
      expect(flight.terminal, '1');
    });

    test('a record outside the window is dropped, as is a cancelled one', () {
      expect(
        AeroApiBoardProvider.flightFromAeroApi(
          aeroRecord,
          'departures',
          DateTime(2026, 10, 17, 14),
          DateTime(2026, 10, 18),
        ),
        isNull,
      );
      expect(
        AeroApiBoardProvider.flightFromAeroApi(
          {...aeroRecord, 'cancelled': true},
          'departures',
          DateTime(2026, 10, 16, 14),
          DateTime(2026, 10, 17),
        ),
        isNull,
      );
    });

    test('the request carries the key and the UTC window', () async {
      Uri? seen;
      String? key;
      final client = MockClient((request) async {
        seen ??= request.url;
        key = request.headers['x-apikey'];
        return http.Response(
          jsonEncode({'flights': [aeroRecord]}),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      });
      final result = await provider(client).fetch(
        DateTime(2026, 10, 16),
        'departures',
        since: DateTime(2026, 10, 16, 14),
        until: DateTime(2026, 10, 17),
      );
      expect(key, 'key');
      expect(seen!.host, 'aeroapi.flightaware.com');
      expect(seen!.path, '/aeroapi/airports/EDDF/flights');
      expect(seen!.queryParameters['flight_type'], 'departures');
      // The window goes out as UTC: 14:00 Berlin is 12:00Z,
      // and midnight Berlin (Oct 17) is 22:00Z the day before.
      expect(seen!.queryParameters['start'], '2026-10-16T12:00:00Z');
      expect(seen!.queryParameters['end'], '2026-10-16T22:00:00Z');
      expect(result.flights, hasLength(1));
      expect(result.source, 'flightaware');
    });

    test('a shape change and a rejected key fail loudly', () async {
      final changed = MockClient((request) async => http.Response(
            jsonEncode({'oops': const []}),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          ));
      await expectLater(
        provider(changed).fetch(DateTime(2026, 10, 16), 'departures'),
        throwsA(isA<ProviderUnavailable>()
            .having((e) => e.message, 'message', contains('flight list'))),
      );
      final denied = MockClient((request) async => http.Response('no', 401));
      await expectLater(
        provider(denied).fetch(DateTime(2026, 10, 16), 'departures'),
        throwsA(isA<ProviderUnavailable>()
            .having((e) => e.message, 'message', contains('key'))),
      );
    });

    test('the ICAO table covers the Lufthansa Group and the '
        'benefit carriers', () {
      expect(icaoToIata['DLH'], 'LH');
      expect(icaoToIata['SWR'], 'LX');
      expect(icaoToIata['CPA'], 'CX');
      // Unknown operators are kept unmapped -- and then
      // simply never count as a benefit.
      expect(icaoToIata.containsKey('XYZ'), isFalse);
    });
  });
}

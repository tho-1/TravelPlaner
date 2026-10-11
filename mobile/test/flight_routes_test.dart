/// The transport routes: the cache key, the
/// duration parser, the China determination,
/// the models, the table logic (sort, filter,
/// search), the airline colors, the cache
/// round-trip and the DeepSeek request. The
/// API is faked, so no network and no key.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:travel_planner/data/ai_config.dart';
import 'package:travel_planner/data/deepseek_client.dart';
import 'package:travel_planner/data/flight_routes.dart';
import 'package:travel_planner/data/flight_routes_repository.dart';
import 'package:travel_planner/models/destination.dart';

Destination _dest(String name, {Object? prio}) {
  final core = <String, Object?>{'destination': name};
  final columns = <(String, Object?)>[('Destination', name)];
  if (prio != null) {
    core['prio'] = prio;
    columns.add(('Prio Thorsten', prio));
  }
  return Destination(core: core, columns: columns);
}

void main() {
  group('normalizeKey', () {
    test('folds diacritics and strips punctuation', () {
      expect(normalizeKey('Cancún'), 'cancun');
      expect(normalizeKey('Đà Nẵng'), 'danang');
      expect(normalizeKey('Air China'), 'airchina');
      expect(normalizeKey(null), '');
    });

    test('keeps the province qualifier', () {
      // "Suzhou (Jiangsu)" and "Suzhou (Anhui)"
      // stay two keys, so they never share a cache
      // file or a planner lookup.
      expect(normalizeKey('Suzhou (Jiangsu)'), 'suzhoujiangsu');
      expect(normalizeKey('Suzhou (Anhui)'), 'suzhouanhui');
      expect(normalizeKey('Suzhou (Jiangsu)'),
          isNot(normalizeKey('Suzhou (Anhui)')));
    });
  });

  group('parseDurationMinutes', () {
    test('hours and minutes', () {
      expect(parseDurationMinutes('1h 45m'), 105);
      expect(parseDurationMinutes('2h'), 120);
      expect(parseDurationMinutes('45m'), 45);
      expect(parseDurationMinutes('2h15m'), 135);
    });

    test('a range takes the first lower bound', () {
      expect(parseDurationMinutes('1h 20m - 1h 40m'), 80);
      expect(parseDurationMinutes('1h 15m - 1h 35m'), 75);
    });

    test('a bare number is minutes when large, hours when small', () {
      expect(parseDurationMinutes('90'), 90);
      expect(parseDurationMinutes('2'), 120);
    });

    test('a missing or blank duration sorts last', () {
      expect(parseDurationMinutes(null), double.infinity);
      expect(parseDurationMinutes('—'), double.infinity);
      expect(parseDurationMinutes('n/a'), double.infinity);
      expect(parseDurationMinutes(''), double.infinity);
    });
  });

  group('isChinaDestination', () {
    test('a Chinese country or city', () {
      expect(isChinaDestination('Nanchang', 'China'), isTrue);
      expect(isChinaDestination('Suzhou', 'China'), isTrue);
      expect(isChinaDestination("Xi'an", 'China'), isTrue);
      expect(isChinaDestination('Berlin', 'People Republic of China'),
          isTrue);
    });

    test('anything else', () {
      expect(isChinaDestination('Tokyo', 'Japan'), isFalse);
      expect(isChinaDestination('Cancún', 'Mexico'), isFalse);
    });
  });

  group('FlightRoutes.fromJson', () {
    test('parses the cached shape', () {
      final routes = FlightRoutes.fromJson({
        'airport_name': 'Nanchang Changbei International Airport',
        'iata_code': 'KHN',
        'city': 'Nanchang',
        'country': 'China',
        'last_updated': '11 Oct 2026',
        'routes': [
          {
            'destination_city': 'Shanghai',
            'destination_country': 'China',
            'destination_iata': 'SHA / PVG',
            'airlines': ['Air China', 'China Eastern'],
            'flight_time': '1h 45m',
            'route_type': 'Domestic',
            'frequency_notes': 'Multiple flights daily',
          },
        ],
        'hsr_routes': [
          {
            'destination_city': 'Changsha',
            'destination_station': 'Changsha South',
            'origin_station': 'Nanchang West',
            'duration': '1h 15m - 1h 35m',
            'train_types': 'G-Train',
            'frequency_notes': '30+ daily trains',
          },
        ],
        'train_stations': ['Nanchang West Railway Station'],
      });
      expect(routes.airportName, 'Nanchang Changbei International Airport');
      expect(routes.iataCode, 'KHN');
      expect(routes.lastUpdated, '11 Oct 2026');
      expect(routes.routes.length, 1);
      expect(routes.routes.first.destinationCity, 'Shanghai');
      expect(routes.routes.first.airlines,
          ['Air China', 'China Eastern']);
      expect(routes.routes.first.flightTime, '1h 45m');
      expect(routes.hsrRoutes.first.destinationCity, 'Changsha');
      expect(routes.hsrRoutes.first.destinationStation, 'Changsha South');
      expect(routes.trainStations, ['Nanchang West Railway Station']);
    });

    test('a missing block is empty, never a crash', () {
      final routes = FlightRoutes.fromJson({'routes': 'not a list'});
      expect(routes.routes, isEmpty);
      expect(routes.hsrRoutes, isEmpty);
      expect(routes.trainStations, isEmpty);
    });
  });

  group('FlightRoute.fromJson', () {
    test('the airlines arrive as a list or a string', () {
      final asList = FlightRoute.fromJson({
        'destination_city': 'Shanghai',
        'airlines': ['Air China', 'China Eastern'],
      });
      expect(asList.airlines, ['Air China', 'China Eastern']);
      final asString = FlightRoute.fromJson({
        'destination_city': 'Shanghai',
        'airlines': 'Air China, China Eastern',
      });
      expect(asString.airlines, ['Air China', 'China Eastern']);
      final none = FlightRoute.fromJson({
        'destination_city': 'Shanghai',
      });
      expect(none.airlines, isEmpty);
    });
  });

  group('buildPlannerLookup', () {
    test('keys the catalogue by cache key', () {
      final lookup = buildPlannerLookup([
        _dest('Shanghai'),
        _dest('Suzhou (Jiangsu)'),
      ]);
      expect(lookup.containsKey('shanghai'), isTrue);
      expect(lookup.containsKey('suzhoujiangsu'), isTrue);
    });

    test('two rows sharing a key keep the first', () {
      final lookup = buildPlannerLookup([
        _dest('Cancún'),
        _dest('Cancun'),
      ]);
      expect(lookup['cancun']!.name, 'Cancún');
    });
  });

  group('queryFlightRows', () {
    final plannerLookup = {
      'shanghai': _dest('Shanghai', prio: 8),
    };
    final routes = [
      const FlightRoute(
        destinationCity: 'Beijing',
        destinationCountry: 'China',
        destinationIata: 'PEK',
        airlines: ['Air China'],
        flightTime: '2h 15m',
      ),
      const FlightRoute(
        destinationCity: 'Shanghai',
        destinationCountry: 'China',
        destinationIata: 'SHA',
        airlines: ['China Eastern'],
        flightTime: '1h 45m',
      ),
      const FlightRoute(
        destinationCity: 'Guangzhou',
        destinationCountry: 'China',
        destinationIata: 'CAN',
        airlines: ['China Southern'],
        flightTime: '2h 45m',
      ),
    ];

    test('sorts by duration ascending', () {
      final rows =
          queryFlightRows(routes: routes, plannerLookup: plannerLookup);
      expect(rows.map((row) => row.city).toList(),
          ['Shanghai', 'Beijing', 'Guangzhou']);
      expect(rows.first.durationMinutes, 105);
    });

    test('a route in the planner carries its Prio', () {
      final rows =
          queryFlightRows(routes: routes, plannerLookup: plannerLookup);
      expect(rows.first.inPlanner, isTrue);
      expect(rows.first.planner!.prioInt, 8);
      expect(rows[1].inPlanner, isFalse);
      expect(rows[1].planner, isNull);
    });

    test('the in-planner filter keeps only matches', () {
      final rows = queryFlightRows(
        routes: routes,
        plannerLookup: plannerLookup,
        inPlannerOnly: true,
      );
      expect(rows.map((row) => row.city).toList(), ['Shanghai']);
    });

    test('the search matches city, airport and airline', () {
      expect(
        queryFlightRows(
          routes: routes,
          plannerLookup: plannerLookup,
          query: 'air china',
        ).map((row) => row.city).toList(),
        ['Beijing'],
      );
      expect(
        queryFlightRows(
          routes: routes,
          plannerLookup: plannerLookup,
          query: 'PEK',
        ).map((row) => row.city).toList(),
        ['Beijing'],
      );
      expect(
        queryFlightRows(
          routes: routes,
          plannerLookup: plannerLookup,
          query: 'guang',
        ).map((row) => row.city).toList(),
        ['Guangzhou'],
      );
    });
  });

  group('queryTrainRows', () {
    final plannerLookup = {
      'changsha': _dest('Changsha'),
    };
    final hsrRoutes = const [
      HsrRoute(
        destinationCity: 'Changsha',
        destinationStation: 'Changsha South',
        duration: '1h 15m - 1h 35m',
        trainTypes: 'G-Train',
      ),
      HsrRoute(
        destinationCity: 'Hangzhou',
        destinationStation: 'Hangzhou East',
        duration: '2h 10m',
        trainTypes: 'G-Train',
      ),
    ];

    test('sorts by travel time ascending', () {
      final rows =
          queryTrainRows(routes: hsrRoutes, plannerLookup: plannerLookup);
      expect(rows.map((row) => row.city).toList(), ['Changsha', 'Hangzhou']);
      expect(rows.first.arrivalStation, 'Changsha South');
      expect(rows.first.trainType, 'G-Train');
      expect(rows.first.inPlanner, isTrue);
    });

    test('the search matches city and station', () {
      expect(
        queryTrainRows(
          routes: hsrRoutes,
          plannerLookup: plannerLookup,
          query: 'hangzhou',
        ).map((row) => row.city).toList(),
        ['Hangzhou'],
      );
      expect(
        queryTrainRows(
          routes: hsrRoutes,
          plannerLookup: plannerLookup,
          query: 'east',
        ).map((row) => row.city).toList(),
        ['Hangzhou'],
      );
    });
  });

  group('AirlineColors', () {
    final colors = AirlineColors({
      'airchina': 'green',
      'lufthansa': 'blue',
      'airfrance': 'red',
      'emirates': '#ff00ff',
    });

    test('the named colors map to the palette', () {
      expect(colors.colorFor('Air China'), '#16a34a');
      expect(colors.colorFor('Lufthansa'), '#2563eb');
      expect(colors.colorFor('Air France'), '#dc2626');
    });

    test('green and blue are bold', () {
      expect(colors.isBold('Air China'), isTrue);
      expect(colors.isBold('Lufthansa'), isTrue);
      expect(colors.isBold('Air France'), isFalse);
    });

    test('an unknown color is used as-is, a missing one is null', () {
      expect(colors.colorFor('Emirates'), '#ff00ff');
      expect(colors.colorFor('Unknown Airline'), isNull);
    });
  });

  group('FlightRoutesRepository', () {
    test('a round-trip through the cache', () {
      final dir = Directory.systemTemp.createTempSync();
      addTearDown(() => dir.deleteSync(recursive: true));
      final repo = FlightRoutesRepository(dir.path);
      expect(repo.load('Nanchang'), isNull);
      expect(
        repo.save('Nanchang', {'airport_name': 'Nanchang Changbei'}),
        isTrue,
      );
      expect(repo.load('Nanchang')!['airport_name'], 'Nanchang Changbei');
      // The cache key folds diacritics: "Cancún" and "Cancun"
      // share one file.
      expect(repo.save('Cancún', {'city': 'Cancún'}), isTrue);
      expect(repo.load('Cancun')!['city'], 'Cancún');
    });

    test('an unconfigured repository never reads or writes', () {
      const repo = FlightRoutesRepository('');
      expect(repo.load('Nanchang'), isNull);
      expect(repo.save('Nanchang', {}), isFalse);
    });
  });

  group('DeepSeekClient', () {
    Map<String, dynamic> routesResponse() => {
          'choices': [
            {
              'message': {
                'content': jsonEncode({
                  'airport_name': 'Nanchang Changbei',
                  'iata_code': 'KHN',
                  'routes': [
                    {'destination_city': 'Shanghai', 'flight_time': '1h 45m'},
                  ],
                }),
              },
            },
          ],
        };

    test('the request mirrors the legacy payload', () async {
      Map<String, dynamic>? sent;
      final client = DeepSeekClient(
        const AiConfig(apiKey: 'sk-test'),
        httpClient: MockClient((request) async {
          sent = jsonDecode(request.body) as Map<String, dynamic>;
          return http.Response(
            jsonEncode(routesResponse()),
            200,
            headers: {'content-type': 'application/json'},
          );
        }),
      );
      final result = await client.generateFlightRoutes(
        destination: 'Nanchang',
        country: 'China',
      );
      expect(sent!['model'], 'deepseek-chat');
      expect((sent!['response_format'] as Map)['type'], 'json_object');
      expect(sent!['temperature'], 0.1);
      final messages = sent!['messages'] as List;
      expect((messages.first as Map)['content'],
          contains('aviation network'));
      final user = (messages.last as Map)['content'] as String;
      expect(user, contains('Nanchang'));
      expect(user, contains('China'));
      // A Chinese destination researches the high-speed rail too.
      expect(user, contains('High-Speed Railway'));
      expect(user, contains('hsr_routes'));
      expect(result['last_updated'], isNotEmpty);
      expect((result['routes'] as List).length, 1);
    });

    test('a non-Chinese destination omits the rail parts', () async {
      Map<String, dynamic>? sent;
      final client = DeepSeekClient(
        const AiConfig(apiKey: 'sk-test'),
        httpClient: MockClient((request) async {
          sent = jsonDecode(request.body) as Map<String, dynamic>;
          return http.Response(
            jsonEncode(routesResponse()),
            200,
            headers: {'content-type': 'application/json'},
          );
        }),
      );
      await client.generateFlightRoutes(
          destination: 'Tokyo', country: 'Japan');
      final user = ((sent!['messages'] as List).last as Map)['content']
          as String;
      expect(user, isNot(contains('hsr_routes')));
      expect(user, isNot(contains('High-Speed Railway')));
    });

    test('a response without a route list is rejected', () async {
      final client = DeepSeekClient(
        const AiConfig(apiKey: 'sk-test'),
        httpClient: MockClient((request) async => http.Response(
              jsonEncode({
                'choices': [
                  {
                    'message': {
                      'content': jsonEncode({'airport_name': 'X'}),
                    },
                  },
                ],
              }),
              200,
              headers: {'content-type': 'application/json'},
            )),
      );
      await expectLater(
        client.generateFlightRoutes(destination: 'X', country: 'Y'),
        throwsA(isA<DeepSeekError>()
            .having((e) => e.message, 'message', contains('route list'))),
      );
    });

    test('without a key the error says how to configure', () async {
      final client = DeepSeekClient(const AiConfig());
      await expectLater(
        client.generateFlightRoutes(destination: 'X', country: 'Y'),
        throwsA(isA<DeepSeekError>()
            .having((e) => e.message, 'message', contains('deepseek_api_key'))),
      );
    });

    test('an HTTP error carries the status', () async {
      final client = DeepSeekClient(
        const AiConfig(apiKey: 'sk-test'),
        httpClient:
            MockClient((request) async => http.Response('rate limited', 429)),
      );
      await expectLater(
        client.generateFlightRoutes(destination: 'X', country: 'Y'),
        throwsA(isA<DeepSeekError>()
            .having((e) => e.message, 'message', contains('HTTP 429'))),
      );
    });
  });
}

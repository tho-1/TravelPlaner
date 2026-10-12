/// The geocode client: the Open-Meteo query,
/// the disk cache and — most of all — the two
/// permanent failure modes the Python file
/// fixed and this port must keep fixed.
///
/// A cache entry is only ever written for a
/// **successful** result. An empty answer, a
/// rejected query (`HTTP 200` with
/// `{"error": true}`) and a network error are
/// never cached, so one bad answer can never
/// block a city until the cache file is
/// deleted by hand.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:travel_planner/data/geocode_repository.dart';

Map<String, dynamic> _payload(List<Map<String, dynamic>> results) =>
    {'results': results};

http.Response _ok(List<Map<String, dynamic>> results) => http.Response(
      jsonEncode(_payload(results)),
      200,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );

final _chengdu = [
  {
    'name': 'Chengdu',
    'country': 'China',
    'admin1': 'Sichuan',
    'latitude': 30.66,
    'longitude': 104.07,
  },
];

void main() {
  late Directory dir;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('geocode_test_');
  });

  tearDown(() {
    if (dir.existsSync()) {
      dir.deleteSync(recursive: true);
    }
  });

  test('search queries Open-Meteo and caches the result', () async {
    var calls = 0;
    final repository = GeocodeRepository(
      dir.path,
      httpClient: MockClient((request) async {
        calls++;
        expect(request.url.queryParameters['name'], 'Chengdu');
        expect(request.url.queryParameters['count'], '5');
        expect(request.url.queryParameters['language'], 'en');
        expect(request.url.queryParameters['format'], 'json');
        return _ok(_chengdu);
      }),
    );

    final results = await repository.search('Chengdu');
    expect(calls, 1);
    expect(results.length, 1);
    expect(results.first.name, 'Chengdu');
    expect(results.first.country, 'China');
    expect(results.first.admin1, 'Sichuan');
    expect(results.first.lat, 30.66);
    expect(results.first.lon, 104.07);

    // The cache file was written, in the schema
    // the reader validates.
    final cache = File('${dir.path}/geocode.json');
    expect(cache.existsSync(), isTrue);
    final decoded =
        jsonDecode(cache.readAsStringSync()) as Map<String, dynamic>;
    expect(decoded['schema'], 2);
    expect((decoded['entries'] as Map).containsKey('chengdu|5'),
        isTrue);
  });

  test('a cached answer makes no second HTTP call', () async {
    var calls = 0;
    final repository = GeocodeRepository(
      dir.path,
      httpClient: MockClient((request) async {
        calls++;
        return _ok(_chengdu);
      }),
    );
    await repository.search('Chengdu');

    // A fresh repository over the same directory
    // (a restart, not a second tab) reads the
    // cache instead of querying.
    final reloaded = GeocodeRepository(
      dir.path,
      httpClient: MockClient((request) async {
        calls++;
        return _ok(_chengdu);
      }),
    );
    final results = await reloaded.search('  Chengdu ');
    expect(calls, 1);
    expect(results.length, 1);
    expect(results.first.name, 'Chengdu');
  });

  test('an empty result is never cached', () async {
    var calls = 0;
    final repository = GeocodeRepository(
      dir.path,
      httpClient: MockClient((request) async {
        calls++;
        return _ok([]);
      }),
    );
    expect(await repository.search('Nowhereville'), isEmpty);
    expect(calls, 1);
    // The whole point of the fix: no cache file,
    // so the next search tries again.
    expect(File('${dir.path}/geocode.json').existsSync(), isFalse);
    await repository.search('Nowhereville');
    expect(calls, 2);
  });

  test('a rejected query (error in a 200) is not cached', () async {
    var calls = 0;
    final repository = GeocodeRepository(
      dir.path,
      httpClient: MockClient((request) async {
        calls++;
        // Open-Meteo answers HTTP 200 with this
        // exact shape for a rejected query.
        return http.Response(
          jsonEncode({'error': true, 'reason': 'invalid query'}),
          200,
        );
      }),
    );
    expect(await repository.search('!!'), isEmpty);
    expect(File('${dir.path}/geocode.json').existsSync(), isFalse);
    await repository.search('!!');
    expect(calls, 2);
  });

  test('a network error returns empty and does not cache', () async {
    final repository = GeocodeRepository(
      dir.path,
      httpClient: MockClient((request) async => http.Response('boom', 500)),
    );
    expect(await repository.search('Chengdu'), isEmpty);
    expect(File('${dir.path}/geocode.json').existsSync(), isFalse);
  });

  test('a thrown connection error is swallowed', () async {
    final repository = GeocodeRepository(
      dir.path,
      httpClient: MockClient((request) async =>
          throw http.ClientException('offline')),
    );
    expect(await repository.search('Chengdu'), isEmpty);
  });

  test('an expired entry is refetched', () async {
    File('${dir.path}/geocode.json').writeAsStringSync(jsonEncode({
      'schema': 2,
      'entries': {
        'chengdu|5': {
          // Older than the 30-day TTL.
          'ts': '2020-01-01T00:00:00Z',
          'results': _chengdu,
        },
      },
    }));
    var calls = 0;
    final repository = GeocodeRepository(
      dir.path,
      httpClient: MockClient((request) async {
        calls++;
        return _ok(_chengdu);
      }),
    );
    final results = await repository.search('Chengdu');
    expect(calls, 1);
    expect(results.length, 1);
  });

  test('a fresh entry is honoured through its timestamp', () async {
    File('${dir.path}/geocode.json').writeAsStringSync(jsonEncode({
      'schema': 2,
      'entries': {
        'chengdu|5': {
          'ts': DateTime.now().toUtc().toIso8601String(),
          'results': _chengdu,
        },
      },
    }));
    var calls = 0;
    final repository = GeocodeRepository(
      dir.path,
      httpClient: MockClient((request) async {
        calls++;
        return _ok(_chengdu);
      }),
    );
    final results = await repository.search('Chengdu');
    expect(calls, 0);
    expect(results.length, 1);
  });

  test('a schema mismatch invalidates the whole cache', () async {
    File('${dir.path}/geocode.json')
        .writeAsStringSync(jsonEncode({'schema': 1, 'entries': {}}));
    final repository = GeocodeRepository(
      dir.path,
      httpClient: MockClient((request) async => _ok(_chengdu)),
    );
    expect(await repository.search('Chengdu'), isNotEmpty);
  });

  test('a corrupt cache degrades to no cache, not a crash', () async {
    File('${dir.path}/geocode.json').writeAsStringSync('{not json');
    final repository = GeocodeRepository(
      dir.path,
      httpClient: MockClient((request) async => _ok(_chengdu)),
    );
    final results = await repository.search('Chengdu');
    expect(results.length, 1);
  });

  test('an unconfigured cache still searches, just without '
      'persistence', () async {
    var calls = 0;
    final repository = GeocodeRepository(
      '',
      httpClient: MockClient((request) async {
        calls++;
        return _ok(_chengdu);
      }),
    );
    expect(await repository.search('Chengdu'), isNotEmpty);
    // No directory is ever created when the cache
    // path is empty.
    expect(File('geocode.json').existsSync(), isFalse);
    await repository.search('Chengdu');
    expect(calls, 2);
  });

  test('a blank query is not even attempted', () async {
    final repository = GeocodeRepository(
      dir.path,
      httpClient: MockClient((request) async => _ok(_chengdu)),
    );
    expect(await repository.search('   '), isEmpty);
    expect(File('${dir.path}/geocode.json').existsSync(), isFalse);
  });
}

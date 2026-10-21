/// The benefits rules: which carrier qualifies, how the
/// flag map is keyed and looked up, and what an empty or
/// broken read does. The fixtures mirror the live benefits
/// table (yes / no / unknown spellings).
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:travel_planner/data/benefits_repository.dart';
import 'package:travel_planner/data/offline_cache.dart';
import 'package:travel_planner/models/airline_benefits.dart';
import 'package:travel_planner/turso/config.dart';

import 'fake_turso.dart';

/// A configured benefits database; the app database is
/// irrelevant here.
TursoConfig _configured() => const TursoConfig(
      url: 'https://travel-tz123.aws-eu-north-1.turso.io',
      token: 'app-token',
      benefitsUrl: 'https://flightconnections-tz123.aws-eu-north-1.turso.io',
      benefitsToken: 'benefits-token',
    );

/// Turso with no benefits credentials at all.
TursoConfig _unconfigured() => const TursoConfig(
      url: 'https://travel-tz123.aws-eu-north-1.turso.io',
      token: 'app-token',
      benefitsUrl: '',
      benefitsToken: '',
    );

void main() {
  group('isYes', () {
    test('only an explicit yes counts', () {
      expect(isYes('yes'), isTrue);
      expect(isYes('Yes'), isTrue);
      expect(isYes(1), isTrue);
      expect(isYes(true), isTrue);
      expect(isYes('unknown'), isFalse);
      expect(isYes('no'), isFalse);
      expect(isYes(null), isFalse);
      expect(isYes(''), isFalse);
    });
  });

  group('normalisation', () {
    test('legal forms and repeated words fold away', () {
      expect(normalizeAirline('Deutsche Lufthansa AG'), 'deutschelufthansa');
      // "Airways" is on the legal-form list in the Python
      // source too -- both sides reach the same key, which is
      // what the lookup needs.
      expect(normalizeAirline('British Airways plc'), 'british');
      expect(normalizeAirline('SWISS Swiss'), 'swiss');
      expect(normalizeAirline('TAP Air Portugal'), 'tapairportugal');
    });

    test('the equivalence table folds known spellings', () {
      expect(canonicalAirlineKey('Deutsche Lufthansa AG'), 'lufthansa');
      expect(canonicalAirlineKey('SWISS International Air Lines'), 'swiss');
      expect(canonicalAirlineKey('KLM Royal Dutch Airlines'), 'klm');
    });

    test('iata codes come out of codes and flight numbers', () {
      expect(iataCode('LH'), 'LH');
      expect(iataCode('LH1000'), 'LH');
      expect(iataCode('lh 1000'), 'LH');
      expect(iataCode('Lufthansa'), '');
    });
  });

  group('rowsToRecords', () {
    const columns = ['iata', 'name', 'discount_eligible', 'business_class'];

    test('any yes column qualifies, and unknown is not a yes', () {
      final (records, problems) = rowsToRecords(
        [
          ['LH', 'Lufthansa', 'yes', 'unknown'],
          ['BA', 'British Airways', 'no', 'no'],
          ['CX', 'Cathay Pacific', 'unknown', 'yes'],
        ],
        columns,
      );
      expect(problems, isEmpty);
      expect(records.length, 3);
      expect(records[0].benefits, isTrue);
      expect(records[1].benefits, isFalse);
      expect(records[2].benefits, isTrue);
      expect(records[2].which, ['business_class']);
    });

    test('an unrecognisable column set is a problem, not an empty map', () {
      final (records, problems) = rowsToRecords(
        [
          ['x', 'y'],
        ],
        ['foo', 'bar'],
      );
      expect(records, isEmpty);
      expect(problems.single, contains('expected a code column'));
    });

    test('flags are keyed by code and by canonical name', () {
      final (records, _) = rowsToRecords(
        [
          ['LH', 'Lufthansa', 'yes', 'no'],
        ],
        columns,
      );
      final flags = recordsToFlags(records);
      expect(flags['LH'], isTrue);
      expect(flags['lufthansa'], isTrue);
    });
  });

  group('hasBenefits', () {
    const flags = {
      'LH': true,
      'lufthansa': true,
      'BA': false,
      'britishairways': false,
    };

    test('the IATA code resolves first', () {
      expect(hasBenefits('LH', flags), isTrue);
      expect(hasBenefits('BA', flags), isFalse);
    });

    test('a known name resolves, an unknown one does not qualify', () {
      expect(hasBenefits('Lufthansa', flags), isTrue);
      expect(hasBenefits('Some Unknown Air', flags), isFalse);
    });

    test('an unambiguous substring match resolves', () {
      expect(hasBenefits('Lufthansa CityLine', flags), isTrue);
    });

    test('without any source, the seed list decides', () {
      expect(hasBenefits('Lufthansa', null), isTrue);
      expect(hasBenefits('Some Unknown Air', null), isFalse);
    });
  });

  test('unmatchedAirlines lists carriers no source mentions', () {
    const flags = {
      'LH': true,
      'lufthansa': true,
    };
    final result = unmatchedAirlines(['LH', 'Condor', 'BA'], flags);
    expect(result, ['BA', 'Condor']);
  });

  group('AirlineScope (report d)', () {
    const flags = {'LH': true, 'BA': false};

    test('lufthansaGroup is the explicit membership table', () {
      expect(
        airlineInScope('LH', 'Lufthansa', AirlineScope.lufthansaGroup, flags),
        isTrue,
      );
      expect(
        airlineInScope('LX', 'SWISS', AirlineScope.lufthansaGroup, flags),
        isTrue,
      );
      expect(
        airlineInScope('AZ', 'ITA Airways', AirlineScope.lufthansaGroup, flags),
        isTrue,
      );
      expect(
        airlineInScope('BA', 'British Airways', AirlineScope.lufthansaGroup,
            flags),
        isFalse,
      );
    });

    test('lufthansaGroup includes the newly added carriers', () {
      expect(
        airlineInScope('VL', 'Lufthansa City Airlines',
            AirlineScope.lufthansaGroup, flags),
        isTrue,
      );
      expect(
        airlineInScope('4Y', 'Discover Airlines',
            AirlineScope.lufthansaGroup, flags),
        isTrue,
      );
    });

    test('the caption names exactly the carriers the code filters on',
        () {
      // The caption and the membership test are one table
      // (the user's report, 2026-10-21: the caption lagged
      // behind the code and named fewer carriers than the
      // filter accepted). This pins the two together.
      final caption = lufthansaGroupCaption();
      for (final carrier in lufthansaGroupCarriers) {
        expect(caption, contains(carrier.$2),
            reason: '${carrier.$2} is in the group and in the caption');
        expect(lufthansaGroupCodes, contains(carrier.$1),
            reason: '${carrier.$1} is in the group');
        expect(
          airlineInScope(carrier.$1, carrier.$2, AirlineScope.lufthansaGroup,
              flags),
          isTrue,
          reason: '${carrier.$2} passes the filter',
        );
      }
      // And the caption does not name a carrier the filter
      // would reject.
      final names = lufthansaGroupCarriers.map((carrier) => carrier.$2);
      expect(caption.split(', ').length, names.length);
    });

    test('lufthansa is name membership ("all with Lufthansa in the name")',
        () {
      expect(
        airlineInScope('LH', 'Lufthansa', AirlineScope.lufthansa, flags),
        isTrue,
      );
      expect(
        airlineInScope(
            'CL', 'Lufthansa City', AirlineScope.lufthansa, flags),
        isTrue,
      );
      // SWISS is in the group but has no Lufthansa name.
      expect(
        airlineInScope('LX', 'SWISS', AirlineScope.lufthansa, flags),
        isFalse,
      );
      // A board row that carries only the code still counts
      // for the Lufthansa-branded codes.
      expect(airlineInScope('LH', '', AirlineScope.lufthansa, flags), isTrue);
    });

    test('allWithBenefits is the benefits database (unknown is not a yes)',
        () {
      expect(
        airlineInScope(
            'LH', 'Lufthansa', AirlineScope.allWithBenefits, flags),
        isTrue,
      );
      expect(
        airlineInScope('BA', 'British Airways', AirlineScope.allWithBenefits,
            flags),
        isFalse,
      );
      expect(
        airlineInScope('XX', 'Mystery', AirlineScope.allWithBenefits, flags),
        isFalse,
      );
    });

    test('all keeps every airline', () {
      expect(airlineInScope('XX', '', AirlineScope.all, flags), isTrue);
      expect(airlineInScope('BA', 'B A', AirlineScope.all, flags), isTrue);
    });
  });

  group('BenefitsRepository', () {
    test('the flags come from the benefits database', () async {
      final fake = FakeTurso((statements) {
        expect(statements.single, 'SELECT * FROM airlines');
        return okRows(
          ['iata', 'name', 'discount_eligible', 'business_class'],
          [
            ['LH', 'Lufthansa', 'yes', 'unknown'],
            ['BA', 'British Airways', 'no', 'no'],
          ],
        );
      });
      final repository = BenefitsRepository(_configured(),
          httpClient: fake.client());
      final source = await repository.loadFlags();
      expect(source.problems, isEmpty);
      expect(source.sourceLabel, 'Turso database');
      expect(source.records.length, 2);
      expect(source.flags['LH'], isTrue);
      expect(source.flags['british'], isFalse);
    });

    test('an empty read falls back to the seed list and says why', () async {
      final fake = FakeTurso((statements) => okRows(
            ['iata', 'name', 'discount_eligible'],
            const [],
          ));
      final repository = BenefitsRepository(_configured(),
          httpClient: fake.client());
      final source = await repository.loadFlags();
      expect(source.problems.single, contains('treated as a failure'));
      expect(source.sourceLabel, 'built-in defaults');
      // The seed list still qualifies the usual suspects, so
      // the finder keeps working visibly instead of silently.
      expect(hasBenefits('Lufthansa', source.flags), isTrue);
    });

    test('a failed read falls back to the seed list and says why', () async {
      final fake =
          FakeTurso((statements) => pipelineError('Turso rejected the token (401)'));
      final repository = BenefitsRepository(_configured(),
          httpClient: fake.client());
      final source = await repository.loadFlags();
      expect(source.problems.single, contains('401'));
      expect(source.flags, isNotEmpty);
    });

    test('an unconfigured benefits database uses the seed list', () async {
      final repository = BenefitsRepository(_unconfigured(),
          httpClient: FakeTurso((statements) => okRows(
                ['iata', 'name', 'discount_eligible'],
                const [],
              )).client());
      final source = await repository.loadFlags();
      expect(source.problems.single, contains('not configured'));
      expect(source.sourceLabel, 'built-in defaults');
      expect(hasBenefits('Lufthansa', source.flags), isTrue);
    });

    group('the offline snapshot', () {
      late Directory temp;

      setUp(() => temp = Directory.systemTemp.createTempSync('benefits'));
      tearDown(() => temp.deleteSync(recursive: true));

      OfflineCache newCache() => OfflineCache(p.join(temp.path, 'offline'));

      test('a full read fills the snapshot', () async {
        final fake = FakeTurso((_) => okRows(
              ['iata', 'name', 'discount_eligible'],
              [
                ['LH', 'Lufthansa', 'yes'],
                ['BA', 'British Airways', 'no'],
              ],
            ));
        final repository = BenefitsRepository(_configured(),
            httpClient: fake.client(), offline: newCache());
        await repository.loadFlags();
        expect(newCache().load('benefits'), isNotNull);
      });

      test('a failed read answers from the snapshot, labelled', () async {
        // The point of the snapshot: offline the finder must
        // use the *real* table, not the 24-airline default list
        // -- the default would qualify carriers the database
        // says are 'unknown'.
        final cache = newCache();
        final online = FakeTurso((_) => okRows(
              ['iata', 'name', 'discount_eligible'],
              [
                ['LH', 'Lufthansa', 'yes'],
                ['BA', 'British Airways', 'no'],
              ],
            ));
        await BenefitsRepository(_configured(),
                httpClient: online.client(), offline: cache)
            .loadFlags();

        final offline = FakeTurso((_) => httpStatus(503));
        final source = await BenefitsRepository(_configured(),
                httpClient: offline.client(), offline: cache)
            .loadFlags();

        expect(source.records.length, 2);
        expect(source.flags['LH'], isTrue);
        expect(source.flags['british'], isFalse);
        expect(source.sourceLabel, contains('offline snapshot'));
        expect(source.problems.single, contains('offline:'));
      });

      test('a failed read without a snapshot uses the seed list', () async {
        final offline = FakeTurso((_) => httpStatus(503));
        final source = await BenefitsRepository(_configured(),
                httpClient: offline.client(), offline: newCache())
            .loadFlags();
        expect(source.sourceLabel, 'built-in defaults');
        expect(source.records, isEmpty);
        expect(source.problems.single, contains('503'));
      });

      test('an empty table is a failure, and does not read the snapshot',
          () async {
        // The table being emptied is a signal, not a network
        // problem: answering from the snapshot would hide it.
        final cache = newCache();
        final online = FakeTurso((_) => okRows(
              ['iata', 'name', 'discount_eligible'],
              [
                ['LH', 'Lufthansa', 'yes'],
              ],
            ));
        await BenefitsRepository(_configured(),
                httpClient: online.client(), offline: cache)
            .loadFlags();

        final emptied = FakeTurso((_) => okRows(
              ['iata', 'name', 'discount_eligible'],
              const [],
            ));
        final source = await BenefitsRepository(_configured(),
                httpClient: emptied.client(), offline: cache)
            .loadFlags();

        expect(source.sourceLabel, 'built-in defaults');
        expect(source.problems.single, contains('treated as a failure'));
      });
    });
  });
}

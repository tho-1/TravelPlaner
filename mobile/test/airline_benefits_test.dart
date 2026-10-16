/// The benefits rules: which carrier qualifies, how the
/// flag map is keyed and looked up, and what an empty or
/// broken read does. The fixtures mirror the live benefits
/// table (yes / no / unknown spellings).
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:travel_planner/data/benefits_repository.dart';
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
  });
}

/// The schedule-board payload builder: the format contract
/// with the FlightRoutes sibling project (its
/// `save_schedules` shape), checked key by key and stamp by
/// stamp -- a board written slightly off-format would be
/// ignored (best case) or misread (worst case) there.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:travel_planner/models/schedule_board_payload.dart';
import 'package:travel_planner/models/weekend_match.dart';

/// record keys = the sibling's template keys
const Set<String> _templateKeys = {
  'dep_time',
  'arr_time',
  'carrier_iata',
  'carrier_name',
  'flight_no',
  'dest_iata',
  'price',
  'dep_at_local',
  'arr_at_local',
  'dep_at_utc',
  'arr_at_utc',
};

Flight _flight({
  String flightNo = 'LH1040',
  String airline = 'LH',
  String airlineName = 'Lufthansa',
  String destination = 'BER',
  DateTime? departure,
  DateTime? arrival,
}) {
  departure ??= DateTime(2026, 10, 24, 14, 35);
  return Flight(
    flightNo: flightNo,
    airline: airline,
    airlineName: airlineName,
    origin: 'FRA',
    destination: destination,
    departure: departure,
    arrival: arrival ?? DateTime(2026, 10, 24, 15, 20),
  );
}

void main() {
  group('scheduleFlightRecord', () {
    test('carries exactly the sibling template keys', () {
      final record = scheduleFlightRecord(_flight());
      expect(record.keys.toSet(), _templateKeys);
    });

    test('summer (CEST): the Berlin offset is +02:00', () {
      final record = scheduleFlightRecord(_flight());
      expect(record['dep_at_local'], '2026-10-24T14:35:00+02:00');
    });

    test('winter (CET): the Berlin offset is +01:00', () {
      final record = scheduleFlightRecord(_flight(
        departure: DateTime(2026, 1, 17, 9, 5),
        arrival: DateTime(2026, 1, 17, 10, 10),
      ));
      expect(record['dep_at_local'], '2026-01-17T09:05:00+01:00');
      expect(record['dep_time'], '09:05');
      expect(record['arr_time'], '10:10');
    });

    test('the departure UTC is the wall-clock minus the real offset',
        () {
      final record = scheduleFlightRecord(_flight());
      // 14:35 +02:00 == 12:35 UTC.
      expect(record['dep_at_utc'], '2026-10-24T12:35:00Z');
    });

    test('the arrival wall-clock is kept, its UTC stays unknown', () {
      final record = scheduleFlightRecord(_flight());
      // Destination local, no offset (the far end's zone is
      // unknown; their AirLabs records share the blank UTC).
      expect(record['arr_at_local'], '2026-10-24T15:20:00');
      expect(record['arr_at_utc'], '');
    });

    test('overnight legs carry the next-day arrival date', () {
      final record = scheduleFlightRecord(_flight(
        departure: DateTime(2026, 10, 24, 23, 10),
        arrival: DateTime(2026, 10, 25, 6, 25),
      ));
      expect(record['arr_at_local'], '2026-10-25T06:25:00');
      expect(record['arr_time'], '06:25');
    });

    test('display fields ride along', () {
      final record = scheduleFlightRecord(_flight());
      expect(record['dep_time'], '14:35');
      expect(record['carrier_iata'], 'LH');
      expect(record['carrier_name'], 'Lufthansa');
      expect(record['flight_no'], 'LH1040');
      expect(record['dest_iata'], 'BER');
      expect(record['price'], null);
      expect(record.keys, containsAll(['dep_time', 'dest_iata']));
    });
  });

  group('scheduleBoardPayload', () {
    test('the meta carries exactly the sibling keys', () {
      final payload = scheduleBoardPayload(
        airport: 'FRA',
        day: '2026-10-24',
        source: 'fraport',
        obtainedAt: '2026-10-18T21:09:40',
        flights: [_flight()],
      );
      final meta = payload['meta'] as Map<String, Object?>;
      expect(meta.keys.toSet(), {
        'schema_version',
        'airport',
        'date',
        'source',
        'obtained_at',
        'n_flights',
      });
      expect(meta['schema_version'], 2);
      expect(meta['airport'], 'FRA');
      expect(meta['date'], '2026-10-24');
      expect(meta['source'], 'fraport');
      expect(meta['obtained_at'], '2026-10-18T21:09:40');
      expect(meta['n_flights'], 1);
    });

    test('the airport is uppercased like save_schedules', () {
      final payload = scheduleBoardPayload(
        airport: 'fra',
        day: '2026-10-24',
        source: 'fraport',
        obtainedAt: '',
        flights: [_flight()],
      );
      expect((payload['meta'] as Map)['airport'], 'FRA');
    });

    test('no coverage key on a full day', () {
      final payload = scheduleBoardPayload(
        airport: 'FRA',
        day: '2026-10-24',
        source: 'fraport',
        obtainedAt: '',
        flights: [_flight()],
      );
      expect((payload['meta'] as Map).containsKey('coverage'), false);
    });

    test('coverage appears only when a window is declared', () {
      final payload = scheduleBoardPayload(
        airport: 'FRA',
        day: '2026-10-24',
        source: 'fraport',
        obtainedAt: '',
        flights: [_flight()],
        coverage: (from: '14:00', to: '23:59'),
      );
      final meta = payload['meta'] as Map<String, Object?>;
      expect(meta['coverage'], {'from': '14:00', 'to': '23:59'});
    });

    test('n_flights counts the records, flights list them in order', () {
      final flights = [
        _flight(flightNo: 'LH1', destination: 'BER'),
        _flight(flightNo: 'LH2', destination: 'VIE'),
        _flight(flightNo: 'LH3', destination: 'MUC'),
      ];
      final payload = scheduleBoardPayload(
        airport: 'FRA',
        day: '2026-10-24',
        source: 'fraport',
        obtainedAt: '',
        flights: flights,
      );
      final meta = payload['meta'] as Map;
      expect(meta['n_flights'], 3);
      final records = payload['flights'] as List;
      expect(records.length, 3);
      expect((records[0] as Map)['flight_no'], 'LH1');
      expect((records[1] as Map)['dest_iata'], 'VIE');
      expect((records[2] as Map)['flight_no'], 'LH3');
    });
  });
}

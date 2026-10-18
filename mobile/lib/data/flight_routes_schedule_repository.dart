/// Read-only adapter for FlightRoutes' shared `schedule_boards` rows.
///
/// This reader intentionally accepts only exact-day, full-day v2 boards. A
/// missing, partial, corrupt, or legacy board is a cache miss, never evidence
/// that no flight exists; callers can fall back to the live board provider.
library;

import 'dart:convert';

import 'package:http/http.dart' as http;

import '../turso/config.dart';
import '../turso/pipeline_client.dart';

class FlightRoutesScheduleFlight {
  final String depTime;
  final String arrTime;
  final String carrierIata;
  final String carrierName;
  final String flightNo;
  final String destIata;
  final String depAtLocal;
  final String arrAtLocal;
  final String depAtUtc;
  final String arrAtUtc;

  const FlightRoutesScheduleFlight({
    required this.depTime,
    required this.arrTime,
    required this.carrierIata,
    required this.carrierName,
    required this.flightNo,
    required this.destIata,
    required this.depAtLocal,
    required this.arrAtLocal,
    required this.depAtUtc,
    required this.arrAtUtc,
  });

  factory FlightRoutesScheduleFlight.fromJson(Map<String, dynamic> json) {
    String text(String key) => (json[key] ?? '').toString().trim();
    return FlightRoutesScheduleFlight(
      depTime: text('dep_time'),
      arrTime: text('arr_time'),
      carrierIata: text('carrier_iata').toUpperCase(),
      carrierName: text('carrier_name'),
      flightNo: text('flight_no'),
      destIata: text('dest_iata').toUpperCase(),
      depAtLocal: text('dep_at_local'),
      arrAtLocal: text('arr_at_local'),
      depAtUtc: text('dep_at_utc'),
      arrAtUtc: text('arr_at_utc'),
    );
  }

  /// The strict class: a record only "has timestamps" when
  /// both ends carry a wall-clock and, crucially, a zoned
  /// UTC stamp for both departure and arrival.
  bool get hasTimestamps =>
      depAtLocal.isNotEmpty &&
      arrAtLocal.isNotEmpty &&
      _hasZone(depAtUtc) &&
      _hasZone(arrAtUtc);

  /// The departure half alone: the wall-clock plus a zoned
  /// UTC departure. Fraport-sourced full-day boards written
  /// by Travel Planner carry this pair (FRA's zone follows
  /// the Berlin rule) but leave the arrival UTC blank -- the
  /// sibling's AirLabs records share the same gap. Outbound
  /// matching needs exactly this; the arrival pair stays
  /// optional and its absence only means "no leg duration".
  bool get hasDepartureTimeline =>
      depAtLocal.isNotEmpty && _hasZone(depAtUtc);

  /// Whether the arrival UTC stamp exists and carries a
  /// zone: the precondition for deriving a leg duration.
  bool get hasArrivalTimeline => _hasZone(arrAtUtc);

  static bool _hasZone(String value) =>
      RegExp(r'(?:Z|[+-]\d{2}:?\d{2})$').hasMatch(value);
}

class FlightRoutesScheduleBoard {
  final String airport;
  final String day;
  final String source;
  final String obtainedAt;
  final String updatedAt;
  final int schemaVersion;
  final int nFlights;
  final Map<String, String>? coverage;
  final List<FlightRoutesScheduleFlight> flights;

  const FlightRoutesScheduleBoard({
    required this.airport,
    required this.day,
    required this.source,
    required this.obtainedAt,
    required this.updatedAt,
    required this.schemaVersion,
    required this.nFlights,
    required this.coverage,
    required this.flights,
  });

  bool get isCompleteV2 =>
      schemaVersion == 2 &&
      coverage == null &&
      nFlights == flights.length &&
      source.trim().isNotEmpty &&
      DateTime.tryParse(obtainedAt) != null &&
      DateTime.tryParse(updatedAt) != null;

  factory FlightRoutesScheduleBoard.fromRow(Map<String, dynamic> row) {
    final iata = (row['iata'] ?? '').toString().trim().toUpperCase();
    final day = (row['day'] ?? '').toString().trim();
    final rawPayload = row['payload'];
    final payload = rawPayload is String
        ? jsonDecode(rawPayload)
        : rawPayload;
    if (payload is! Map<String, dynamic>) {
      throw const FormatException('schedule payload is not an object');
    }
    final meta = payload['meta'];
    if (meta is! Map<String, dynamic>) {
      throw const FormatException('schedule metadata is missing');
    }
    final metaAirport = (meta['airport'] ?? '').toString().trim().toUpperCase();
    final metaDay = (meta['date'] ?? '').toString().trim();
    final parsedDay = DateTime.tryParse(day);
    if (iata.isEmpty ||
        iata != metaAirport ||
        day != metaDay ||
        parsedDay == null ||
        parsedDay.toIso8601String().substring(0, 10) != day) {
      throw const FormatException('schedule key does not match its payload');
    }
    final rawCoverage = meta['coverage'];
    final coverage = rawCoverage is Map
        ? <String, String>{
            for (final entry in rawCoverage.entries)
              entry.key.toString(): entry.value.toString(),
          }
        : null;
    final version = meta['schema_version'];
    final schemaVersion = version is num
        ? version.toInt()
        : int.tryParse((version ?? '').toString()) ?? 1;
    final count = meta['n_flights'];
    final nFlights = count is num
        ? count.toInt()
        : int.tryParse((count ?? '').toString()) ?? -1;
    final rawFlights = payload['flights'];
    if (rawFlights is! List) {
      throw const FormatException('schedule flights are missing');
    }
    return FlightRoutesScheduleBoard(
      airport: iata,
      day: day,
      source: (meta['source'] ?? '').toString(),
      obtainedAt: (meta['obtained_at'] ?? '').toString(),
      updatedAt: (row['updated_at'] ?? '').toString(),
      schemaVersion: schemaVersion,
      nFlights: nFlights,
      coverage: coverage == null || coverage.isEmpty ? null : coverage,
      flights: [
        for (final flight in rawFlights)
          if (flight is Map<String, dynamic>)
            FlightRoutesScheduleFlight.fromJson(flight),
      ],
    );
  }
}

class FlightRoutesScheduleRead {
  final List<FlightRoutesScheduleBoard> boards;
  final List<String> problems;

  const FlightRoutesScheduleRead({
    required this.boards,
    required this.problems,
  });

  bool get ok => problems.isEmpty;
}

class FlightRoutesScheduleRepository {
  final TursoClient client;

  const FlightRoutesScheduleRepository(this.client);

  static Future<FlightRoutesScheduleRepository?> fromAssets({
    http.Client? httpClient,
  }) async {
    final config = await TursoConfig.load();
    if (!config.flightRoutesConfigured) return null;
    return FlightRoutesScheduleRepository(
      TursoClient(
        TursoConfig(
          url: config.flightRoutesUrl,
          token: config.flightRoutesToken,
        ),
        httpClient: httpClient,
      ),
    );
  }

  Future<FlightRoutesScheduleRead> loadBoards({
    required String day,
    required Iterable<String> airports,
  }) async {
    final parsedDay = DateTime.tryParse(day);
    if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(day) ||
        parsedDay == null ||
        parsedDay.toIso8601String().substring(0, 10) != day) {
      return const FlightRoutesScheduleRead(
        boards: [],
        problems: ['invalid schedule date'],
      );
    }
    final codes = <String>{};
    for (final airport in airports) {
      final code = airport.trim().toUpperCase();
      if (!RegExp(r'^[A-Z0-9]{3,4}$').hasMatch(code)) {
        return const FlightRoutesScheduleRead(
          boards: [],
          problems: ['invalid airport code in schedule query'],
        );
      }
      codes.add(code);
    }
    if (codes.isEmpty) {
      return const FlightRoutesScheduleRead(boards: [], problems: []);
    }

    final sortedCodes = codes.toList()..sort();
    final boards = <FlightRoutesScheduleBoard>[];
    for (var start = 0; start < sortedCodes.length; start += 40) {
      final chunk = sortedCodes.skip(start).take(40).toList();
      final list = chunk.map((code) => "'$code'").join(',');
      final sql = 'SELECT iata, day, payload, updated_at FROM schedule_boards '
          "WHERE day = '$day' AND iata IN ($list)";
      final (rows, problems) = await client.query(sql);
      if (problems.isNotEmpty) {
        return FlightRoutesScheduleRead(
          boards: const [],
          problems: problems,
        );
      }
      try {
        boards.addAll(rows.map(FlightRoutesScheduleBoard.fromRow));
      } on FormatException {
        return const FlightRoutesScheduleRead(
          boards: [],
          problems: ['a shared schedule board could not be decoded'],
        );
      }
    }
    return FlightRoutesScheduleRead(boards: boards, problems: const []);
  }
}

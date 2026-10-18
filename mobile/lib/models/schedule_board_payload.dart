/// The shared FlightRoutes schedule-board payload: the value
/// of one `schedule_boards.payload` JSON, byte-compatible
/// with the sibling project ("FlightRoutes") that owns the
/// database.
///
/// The format contract lives in the sibling's
/// `utils/schema.sql` and `utils/schedule_provider.py`
/// (`save_schedules`, the format source of truth):
///
/// ```json
/// {"meta": {"schema_version": 2, "airport": "FRA",
///           "date": "2026-10-24", "source": "fraport",
///           "obtained_at": "2026-10-18T21:09:40",
///           "n_flights": 91},
///  "flights": [{"dep_time": "14:35", "arr_time": "15:20",
///               "carrier_iata": "LH", "carrier_name": ...,
///               "flight_no": "LH1040", "dest_iata": "BER",
///               "price": null,
///               "dep_at_local": "2026-10-24T14:35:00+02:00",
///               "arr_at_local": "2026-10-24T15:20:00",
///               "dep_at_utc": "2026-10-24T12:35:00Z",
///               "arr_at_utc": ""}]}
/// ```
///
/// What Travel Planner can honestly stamp:
///
/// * **Departures are fully stamped.** FRA is Europe/Berlin,
///   so the wall-clock plus the EU DST rule (see
///   `berlinOffsetHours`) yields both the local stamp with
///   its real offset and the true UTC.
/// * **Arrivals are not.** The Fraport board's arrival
///   offsets are unreliable (stamped +0000/+0100 regardless
///   of the airport), and Travel Planner carries no
///   per-airport zone table -- so the arrival wall-clock
///   (destination local) is kept, its `arr_at_utc` left
///   blank. The sibling's AirLabs records share exactly this
///   gap, so consumers already tolerate it. A departure-board
///   consumer needs the departure stamps; the arrival pair
///   is simply absent, like on their own AirLabs boards.
///
/// "No timezone" fields that exist get `''`, never a fake
/// value; `coverage` is only present for partial days (a
/// partial set is never dressed up as a full day -- the
/// downstream "is this a full board?" check is precisely the
/// absence of that key).
library;

import 'timetable.dart';
import 'weekend_match.dart';

/// One departure-board flight in the sibling's record shape
/// (the ten keys their AeroDataBox normalizer emits; AirLabs
/// shares the set).
///
/// `arrival` is the wall-clock at the destination (the
/// matcher's convention), so `arr_time`/`arr_at_local` are
/// the far end's local time; this is the shape the sibling's
/// AeroDataBox records use as well.
Map<String, Object?> scheduleFlightRecord(Flight flight) {
  final offset = berlinOffsetHours(flight.departure);
  return {
    'dep_time': _hhmm(flight.departure),
    'arr_time': _hhmm(flight.arrival),
    'carrier_iata': flight.airline,
    'carrier_name': flight.airlineName,
    'flight_no': flight.flightNo,
    'dest_iata': flight.destination,
    // The sibling's AeroDataBox records carry the key with
    // null (only Tequila fills it); mirror the shape.
    'price': null,
    'dep_at_local': '${_iso(flight.departure)}+0$offset:00',
    // The far end's zone is unknown (no per-airport table
    // here): wall-clock like the sibling's AirLabs records.
    'arr_at_local': _iso(flight.arrival),
    'dep_at_utc': _utcStamp(flight.departure, offset),
    'arr_at_utc': '',
  };
}

/// The whole payload for one airport-day board.
///
/// `airport` is uppercased like `save_schedules` does.
/// `obtainedAt` is passed in (not derived) so the caller owns
/// the clock; the sibling format is a naive local timestamp
/// to seconds precision. `coverage` marks a partial day;
/// Travel Planner only writes full days, so callers leave it
/// null -- it exists here because the *shape* is the
/// contract, and a test should be able to name it.
Map<String, Object?> scheduleBoardPayload({
  required String airport,
  required String day,
  required String source,
  required String obtainedAt,
  required List<Flight> flights,
  ({String from, String to})? coverage,
}) {
  final meta = <String, Object?>{
    'schema_version': 2,
    'airport': airport.trim().toUpperCase(),
    'date': day,
    'source': source,
    'obtained_at': obtainedAt,
    'n_flights': flights.length,
    if (coverage != null)
      'coverage': {'from': coverage.from, 'to': coverage.to},
  };
  return {
    'meta': meta,
    'flights': [for (final flight in flights) scheduleFlightRecord(flight)],
  };
}

/// 'HH:MM' from a wall-clock, zero-padded -- `_hhmm` in the
/// sibling's provider.
String _hhmm(DateTime at) =>
    '${at.hour.toString().padLeft(2, '0')}:'
    '${at.minute.toString().padLeft(2, '0')}';

/// 'YYYY-MM-DDTHH:MM:SS' with no timezone marker: the
/// matcher's naive wall-clocks already are the airport's
/// local time, and adding a zone here would invent one.
String _iso(DateTime at) =>
    '${at.year.toString().padLeft(4, '0')}-'
    '${at.month.toString().padLeft(2, '0')}-'
    '${at.day.toString().padLeft(2, '0')}T'
    '${at.hour.toString().padLeft(2, '0')}:'
    '${at.minute.toString().padLeft(2, '0')}:'
    '${at.second.toString().padLeft(2, '0')}';

/// 'YYYY-MM-DDTHH:MM:SSZ' -- the wall-clock shifted back by
/// its real offset (the DST rule, not the board's unreliable
/// one), the form the sibling's UTC stamps take.
String _utcStamp(DateTime at, int offsetHours) {
  final utc = at.subtract(Duration(hours: offsetHours));
  return '${_iso(utc)}Z';
}

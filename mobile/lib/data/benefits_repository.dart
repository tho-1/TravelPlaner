/// Reading the airline-benefits flags out of the benefits
/// Turso database.
///
/// The Dart port of `benefits_turso.fetch_benefit_records`
/// plus the *first* rung of the Python fallback ladder. The
/// ladder on the Python side is Turso -> workbook sheet ->
/// legacy Excel file -> seed list; the app has no workbook
/// and no Excel file, so its ladder is **Turso -> snapshot ->
/// seed list** (the snapshot is the offline-first layer's
/// copy of the table, the equivalent of the Python side's
/// local `flightroutes.db`).
///
/// The rule that matters most: an **empty read is a
/// failure**, not "nobody qualifies" -- an empty flag map
/// would remove every destination from the weekend finder
/// with no visible cause. A failure returns the seed list
/// and says so.
library;

import 'package:http/http.dart' as http;

import '../models/airline_benefits.dart';
import '../turso/config.dart';
import '../turso/pipeline_client.dart';
import 'offline_cache.dart';

/// The flags plus what the finder's header must say about
/// them.
typedef BenefitSource = ({
  Map<String, bool> flags,
  List<AirlineRecord> records,
  String sourceLabel,
  List<String> problems,
});

class BenefitsRepository {
  final TursoConfig config;
  final http.Client httpClient;

  /// The offline-first snapshot store. Null when the device
  /// has no writable home (tests), and then the ladder is
  /// Turso -> seed list.
  final OfflineCache? offline;

  /// Per the contract in `TURSO_PLAN.md`: the table name is
  /// configuration, not user input.
  static const table = 'airlines';

  /// The snapshot dataset name.
  static const dataset = 'benefits';

  BenefitsRepository(
    this.config, {
    http.Client? httpClient,
    this.offline,
  }) : httpClient = httpClient ?? http.Client();

  /// Load the flags. Never throws: every failure mode comes
  /// back as a problem string, exactly like the Python
  /// side, and the flags then hold the seed list.
  Future<BenefitSource> loadFlags() async {
    if (!config.benefitsConfigured) {
      return (
        flags: seedFlags(),
        records: const <AirlineRecord>[],
        sourceLabel: 'built-in defaults',
        problems: const ['benefits database is not configured'],
      );
    }
    final client = TursoClient(
      TursoConfig(url: config.benefitsUrl, token: config.benefitsToken),
      httpClient: httpClient,
    );
    final (rows, problems) = await client.query('SELECT * FROM $table');
    if (problems.isNotEmpty || rows.isEmpty) {
      // The live read did not deliver. A *transport* failure
      // (no network, 5xx) is what the snapshot is for; an
      // empty table is a different thing entirely -- it says
      // the table was emptied, and answering from a snapshot
      // would hide that. So the empty table keeps the seed
      // list, as before.
      if (problems.isNotEmpty) {
        final snapshot = _fromSnapshot(problems);
        if (snapshot != null) return snapshot;
      }
      return (
        flags: seedFlags(),
        records: const <AirlineRecord>[],
        sourceLabel: 'built-in defaults',
        problems: problems.isEmpty
            ? [
                "the table '$table' is empty — treated as a failure so the "
                    'airline list cannot silently become empty',
              ]
            : problems,
      );
    }
    // `StatementResult.asMaps` keeps the columns in SELECT
    // order, so the first row's key order *is* the column
    // order -- the shape `rows_to_records` wants.
    final columns = rows.first.keys.toList();
    final (records, recordProblems) = rowsToRecords(
      [for (final row in rows) [for (final column in columns) row[column]]],
      columns,
    );
    if (recordProblems.isNotEmpty || records.isEmpty) {
      return (
        flags: seedFlags(),
        records: const <AirlineRecord>[],
        sourceLabel: 'built-in defaults',
        problems: recordProblems.isEmpty
            ? ['no airline rows could be read from the table']
            : recordProblems,
      );
    }
    // A full read: keep the copy that answers the next
    // offline search. Only a *full* read may write a snapshot
    // (the offline layer's rule), and this query is the whole
    // table.
    offline?.save(dataset, [rows]);
    return (
      flags: recordsToFlags(records),
      records: records,
      sourceLabel: 'Turso database',
      problems: const <String>[],
    );
  }

  /// The snapshot's answer, when the device has one.
  ///
  /// The copy is the table *as read* -- the same rows, the
  /// same column order -- so it goes through the same
  /// `rowsToRecords` path and cannot drift from the live
  /// reading. The note says the answer is a stored copy, so
  /// an offline result is never mistaken for a current one.
  BenefitSource? _fromSnapshot(List<String> failed) {
    final cache = offline;
    if (cache == null) return null;
    final snapshot = cache.load(dataset);
    if (snapshot == null || snapshot.tables.isEmpty) return null;
    final rows = snapshot.tables.first;
    if (rows.isEmpty) return null;
    final columns = rows.first.keys.toList();
    final (records, problems) = rowsToRecords(
      [for (final row in rows) [for (final column in columns) row[column]]],
      columns,
    );
    if (problems.isNotEmpty || records.isEmpty) return null;
    return (
      flags: recordsToFlags(records),
      records: records,
      sourceLabel: 'offline snapshot from ${snapshot.savedAt}',
      problems: offlineNote('airline benefits', failed.join('; '),
          snapshot.savedAt),
    );
  }
}

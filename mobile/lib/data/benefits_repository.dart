/// Reading the airline-benefits flags out of the benefits
/// Turso database.
///
/// The Dart port of `benefits_turso.fetch_benefit_records`
/// plus the *first* rung of the Python fallback ladder. The
/// ladder on the Python side is Turso -> workbook sheet ->
/// legacy Excel file -> seed list; the app has no workbook,
/// so its ladder is **Turso -> seed list**.
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

  /// Per the contract in `TURSO_PLAN.md`: the table name is
  /// configuration, not user input.
  static const table = 'airlines';

  BenefitsRepository(this.config, {http.Client? httpClient})
      : httpClient = httpClient ?? http.Client();

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
    return (
      flags: recordsToFlags(records),
      records: records,
      sourceLabel: 'Turso database',
      problems: const <String>[],
    );
  }
}

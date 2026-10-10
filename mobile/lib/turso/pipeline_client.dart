/// Turso SQL-over-HTTP pipeline client.
///
/// The same API `turso_db.py` uses: `POST <host>/v2/pipeline`
/// with `{"requests": [{"type": "execute", "stmt": {"sql": ...}},
/// {"type": "close"}]}`. Semantics that must not drift:
///
/// * An error arrives as `{"type": "error"}` *inside* a 200
///   response, so the HTTP status alone does not say whether
///   the query worked.
/// * Always send `close` last, or the server holds the
///   connection until it times out.
/// * The token is never logged, printed, or stored in the
///   repository.
///
/// Why HTTP and not the `turso.sync` native client: the
/// native SDK needs the database to have embedded-replica
/// sync enabled, which is unverified for this database.
/// The pipeline API works today (verified against the live
/// database); offline-first sync is the open item in
/// `NATIVE_HTML_PLAN.md` Phase 5.
library;

import 'dart:convert';
import 'dart:math';

import 'package:http/http.dart' as http;

import 'config.dart';

/// One statement's result: column names and rows.
class StatementResult {
  final List<String> columns;
  final List<List<dynamic>> rows;

  const StatementResult(this.columns, this.rows);

  /// The rows as maps, the shape the repositories consume.
  List<Map<String, dynamic>> get asMaps => [
        for (final row in rows)
          {
            for (var i = 0; i < columns.length; i++)
              columns[i]: row[i],
          },
      ];
}

class TursoClient {
  final TursoConfig config;
  final http.Client httpClient;

  static const timeout = Duration(seconds: 15);

  TursoClient(this.config, {http.Client? httpClient})
      : httpClient = httpClient ?? http.Client();

  String get endpoint {
    var host = config.url.trim();
    host = host.replaceFirst(RegExp(r'^libsql://'), 'https://');
    host = host.replaceFirst(RegExp(r'^http://'), 'https://');
    host = host.replaceAll(RegExp(r'/+$'), '');
    return host.endsWith('/v2/pipeline') ? host : '$host/v2/pipeline';
  }

  /// Run the statements in one pipeline request. A failed
  /// statement is reported in `problems`, never thrown --
  /// the caller falls through or reports, exactly like
  /// the Python side.
  Future<(List<StatementResult>, List<String>)> runPipeline(
    List<String> statements,
  ) async {
    if (!config.isConfigured) {
      return (const [], ['Turso URL or token is not set']);
    }
    final requests = [
      for (final sql in statements)
        {'type': 'execute', 'stmt': {'sql': sql}},
      {'type': 'close'},
    ];
    final http.Response response;
    try {
      response = await httpClient
          .post(
            Uri.parse(endpoint),
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer ${config.token}',
            },
            body: jsonEncode({'requests': requests}),
          )
          .timeout(timeout);
    } catch (_) {
      return (const [], ['could not reach Turso']);
    }
    if (response.statusCode == 401) {
      return (const [], ['Turso rejected the token (401)']);
    }
    if (response.statusCode == 403) {
      return (const [],
          ['Turso denied access (403) -- the token may be read-only for this database']);
    }
    if (response.statusCode >= 500) {
      return (const [], ['Turso is unavailable (${response.statusCode})']);
    }
    if (response.statusCode != 200) {
      return (const [],
          ['Turso returned ${response.statusCode}: ${response.body.substring(0, min(response.body.length, 120))}']);
    }
    final body = jsonDecode(response.body) as Map<String, dynamic>?;
    return _parseResponse(body);
  }

  /// A read statement. Returns the rows as maps; an empty
  /// list with a non-empty `problems` means the read
  /// failed -- never "no rows".
  Future<(List<Map<String, dynamic>>, List<String>)> query(
    String sql,
  ) async {
    final (results, problems) = await runPipeline([sql]);
    if (problems.isNotEmpty || results.isEmpty) {
      return (const [], problems.isEmpty ? ['no result'] : problems);
    }
    return (results.first.asMaps, const []);
  }

  /// A write/DDL statement. An empty list means it worked.
  Future<List<String>> execute(String sql) async {
    final (_, problems) = await runPipeline([sql]);
    return problems;
  }

  (List<StatementResult>, List<String>) _parseResponse(
    Map<String, dynamic>? body,
  ) {
    final results = <StatementResult>[];
    final problems = <String>[];
    for (final item in (body?['results'] as List?) ?? const []) {
      if (item is! Map<String, dynamic>) continue;
      if (item['type'] == 'error') {
        final error = item['error'];
        final message = error is Map<String, dynamic>
            ? (error['message'] as String? ?? 'unknown error')
            : 'unknown error';
        problems.add(message.substring(0, min(message.length, 200)));
        continue;
      }
      final result =
          (item['response'] as Map<String, dynamic>?)?['result']
              as Map<String, dynamic>?;
      final columns = [
        for (final column in (result?['cols'] as List?) ?? const [])
          if (column is Map<String, dynamic>)
            (column['name'] as String? ?? ''),
      ];
      final rows = <List<dynamic>>[];
      for (final row in (result?['rows'] as List?) ?? const []) {
        if (row is List) {
          rows.add([for (final cell in row) _cellValue(cell)]);
        }
      }
      results.add(StatementResult(columns, rows));
    }
    return (results, problems);
  }

  /// Normalise one pipeline-API cell to a plain Dart value.
  /// Without this every read would hand the app
  /// `{type, value}` maps instead of strings and numbers.
  dynamic _cellValue(dynamic cell) {
    if (cell == null) return null;
    if (cell is Map<String, dynamic>) {
      final kind = cell['type'] as String?;
      final value = cell['value'];
      if (kind == 'null' || value == null) return null;
      if (kind == 'integer') {
        return int.tryParse(value.toString()) ?? value;
      }
      if (kind == 'real') {
        return double.tryParse(value.toString()) ?? value;
      }
      // blob: base64 -- this app reads no blobs.
      return value;
    }
    return cell;
  }
}

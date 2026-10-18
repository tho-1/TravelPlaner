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

  /// The rows a DML statement affected, when the
  /// pipeline API reports it (writes do, reads
  /// don't). The trip save's concurrency guard
  /// reads it: a conditional update that matched
  /// nothing affected zero rows.
  final int? rowsAffected;

  const StatementResult(this.columns, this.rows,
      {this.rowsAffected});

  /// The rows as maps, the shape the repositories consume.
  List<Map<String, dynamic>> get asMaps => [
        for (final row in rows)
          {
            for (var i = 0; i < columns.length; i++)
              columns[i]: row[i],
          },
      ];
}

/// True when a problem string is a *transport* failure: the
/// request never got an answer the database could act on, so
/// sending it again later may well work.
///
/// Only these are queued for replay (offline-first Phase 5,
/// commit 2). A rejected token (401/403), a statement error or
/// a malformed answer from a captive portal would fail again
/// forever, and queueing them would hide a real problem
/// behind a "waiting to sync" badge.
bool offlineProblem(String problem) =>
    problem.startsWith('could not reach Turso') ||
    problem.startsWith('Turso is unavailable') ||
    problem.startsWith('Turso returned a non-JSON response');

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
  ///
  /// `args` holds the positional `?` values for each
  /// statement, in the same order (one entry per statement,
  /// `null` or empty when the statement has none). Values
  /// must be encoded the way the protocol dictates -- see
  /// `_typedArg` -- so JSON blobs (the schedule-board
  /// payloads, full of quotes) never travel through string
  /// interpolation.
  Future<(List<StatementResult>, List<String>)> runPipeline(
    List<String> statements, {
    List<List<Object?>>? args,
  }) async {
    if (!config.isConfigured) {
      return (<StatementResult>[], ['Turso URL or token is not set']);
    }
    final argLists = args ?? const <List<Object?>>[];
    final requests = [
      for (final (i, sql) in statements.indexed)
        {
          'type': 'execute',
          'stmt': {
            'sql': sql,
            if (i < argLists.length && argLists[i].isNotEmpty)
              'args': [for (final value in argLists[i]) _typedArg(value)],
          },
        },
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
    } catch (error) {
      // Same wording as turso_db.py: the exception type, never
      // the full text (a URL could leak into it).
      return (<StatementResult>[], ['could not reach Turso: ${error.runtimeType}']);
    }
    if (response.statusCode == 401) {
      return (<StatementResult>[], ['Turso rejected the token (401)']);
    }
    if (response.statusCode == 403) {
      return (<StatementResult>[], [
        'Turso denied access (403) -- the token may be read-only for this database',
      ]);
    }
    if (response.statusCode >= 500) {
      return (
        <StatementResult>[],
        ['Turso is unavailable (${response.statusCode})'],
      );
    }
    if (response.statusCode != 200) {
      return (<StatementResult>[], [
        'Turso returned ${response.statusCode}: '
            '${utf8.decode(response.bodyBytes, allowMalformed: true).substring(0, min(response.bodyBytes.length, 120))}',
      ]);
    }
    // JSON is UTF-8 by definition (RFC 8259); decoding the
    // bytes explicitly avoids the http package's latin1
    // default, which would mangle non-ASCII city names.
    // A 200 with a non-JSON body -- a captive portal, a
    // proxy error page -- is the same failure as an
    // unreachable host: the legacy returns a problem,
    // never a throw (turso_db.py).
    try {
      final body = jsonDecode(utf8.decode(response.bodyBytes))
          as Map<String, dynamic>?;
      return _parseResponse(body);
    } catch (_) {
      return (<StatementResult>[],
          ['Turso returned a non-JSON response']);
    }
  }

  /// A read statement. Returns the rows as maps; an empty
  /// list with a non-empty `problems` means the read
  /// failed -- never "no rows".
  Future<(List<Map<String, dynamic>>, List<String>)> query(
    String sql,
  ) async {
    final (results, problems) = await runPipeline([sql]);
    if (problems.isNotEmpty || results.isEmpty) {
      return (
        <Map<String, dynamic>>[],
        problems.isEmpty ? ['no result'] : problems,
      );
    }
    return (results.first.asMaps, const <String>[]);
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
      results.add(StatementResult(columns, rows,
          rowsAffected: _affected(result?['rows_affected'] ??
              result?['affected_row_count'])));
    }
    return (results, problems);
  }

  /// The pipeline API reports `rows_affected` for a
  /// DML statement, as a number or as a string.
  static int? _affected(Object? value) => value is int
      ? value
      : value is String
          ? int.tryParse(value)
          : null;

  /// One positional `?` value as a typed Hrana Value.
  ///
  /// Integers are string-encoded: Turso Cloud's HTTP endpoint
  /// rejects a bare JSON number in the integer variant
  /// ("expected a borrowed string") -- Hrana transmits i64
  /// values as strings to keep them exact. This mirrors the
  /// sibling project's `utils/sync.py:_arg` byte for byte;
  /// its form is proven against the live database every day.
  static Map<String, dynamic> _typedArg(Object? value) {
    if (value == null) return {'type': 'null'};
    if (value is bool) {
      return {'type': 'integer', 'value': value ? '1' : '0'};
    }
    if (value is int) return {'type': 'integer', 'value': '$value'};
    if (value is double) return {'type': 'real', 'value': '$value'};
    return {'type': 'text', 'value': value.toString()};
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

/// A fake Turso pipeline endpoint for repository and
/// client tests: captures every request's SQL statements
/// and answers with a scripted response.
///
/// Responses here use plain values inside `rows` for
/// brevity; the typed-cell decoding
/// (`{"type": "integer", ...}`) is covered separately in
/// `pipeline_client_test.dart`.
library;

import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

class FakeTurso {
  /// The SQL statements of every request, in order.
  final List<List<String>> requests = [];

  /// The request types of every request ('execute' /
  /// 'close'), in order -- for asserting that `close`
  /// is always sent last.
  final List<List<String>> requestTypes = [];

  final http.Response Function(List<String> statements) handler;

  FakeTurso(this.handler);

  http.Client client() => MockClient.streaming((request, bodyStream) async {
        // The request arrives finalized; read the body from
        // the stream instead of calling finalize again.
        final body = await utf8.decoder.bind(bodyStream).join();
        final map = jsonDecode(body) as Map<String, dynamic>;
        final statements = <String>[];
        final types = <String>[];
        for (final entry in map['requests'] as List) {
          final item = entry as Map<String, dynamic>;
          types.add(item['type'] as String);
          if (item['type'] == 'execute') {
            statements.add(
                ((item['stmt'] as Map<String, dynamic>)['sql']) as String);
          }
        }
        requests.add(statements);
        requestTypes.add(types);
        final response = handler(statements);
        return http.StreamedResponse(
          Stream.value(utf8.encode(response.body)),
          response.statusCode,
        );
      });
}

/// A 200 pipeline response carrying one SELECT result.
http.Response okRows(List<String> columns, List<List<Object?>> rows) =>
    okMulti([(columns, rows)]);

/// A 200 pipeline response with several results -- the
/// shape `loadTrips` gets for its four SELECTs.
///
/// Bodies are UTF-8 bytes: the non-ASCII column values
/// ("In näherer Auswahl 2025?") must survive the round
/// trip, and `Response(String, ...)` validates latin1.
http.Response okMulti(
  List<(List<String>, List<List<Object?>>)> results,
) =>
    http.Response.bytes(
      utf8.encode(
        jsonEncode({
          'results': [
            for (final (columns, rows) in results)
              {
                'type': 'ok',
                'response': {
                  'result': {
                    'cols': [
                      for (final column in columns) {'name': column},
                    ],
                    'rows': rows,
                  },
                },
              },
          ],
        }),
      ),
      200,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );

/// A 200 pipeline response with `count` empty ok results
/// -- the shape write statements produce.
http.Response okEmpty([int count = 1]) => http.Response.bytes(
      utf8.encode(
        jsonEncode({
          'results': [
            for (var i = 0; i < count; i++)
              {'type': 'ok', 'response': {'result': <String, dynamic>{}}},
          ],
        }),
      ),
      200,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );

/// How the pipeline API reports a failed statement: an
/// error *inside* a 200 response.
http.Response pipelineError(String message) => http.Response.bytes(
      utf8.encode(
        jsonEncode({
          'results': [
            {'type': 'error', 'error': {'message': message}},
          ],
        }),
      ),
      200,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );

http.Response httpStatus(int status) =>
    http.Response('{"error": "unexpected status"}', status);

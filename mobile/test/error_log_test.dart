/// The error log (report f): one JSONL line per incident,
/// readable afterwards, and never able to take the app
/// down.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:travel_planner/data/error_log.dart';

void main() {
  late Directory dir;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('error_log_test');
    ErrorLog.instance
      ..clear()
      ..bind(dir.path);
  });

  tearDown(() {
    ErrorLog.instance
      ..clear()
      ..bind('');
    dir.deleteSync(recursive: true);
  });

  test('an entry lands in memory and on disk', () {
    final written = ErrorLog.instance.record(
      'weekend-finder',
      'the board returned no flights at all',
      details: {'window': '2026-10-25 arrivals'},
    );
    expect(written, isTrue);

    final (entries, problems) = ErrorLog.instance.readAll();
    expect(problems, isEmpty);
    expect(entries, hasLength(1));
    expect(entries.single.area, 'weekend-finder');
    expect(entries.single.message, contains('no flights'));
    expect(entries.single.details['window'], '2026-10-25 arrivals');

    final lines = File(ErrorLog.instance.filePath)
        .readAsStringSync()
        .trim()
        .split('\n');
    expect(lines, hasLength(1));
    expect(jsonDecode(lines.single), isA<Map<String, Object?>>());
  });

  test('entries come back newest first and survive a restart', () {
    ErrorLog.instance.record('app', 'first');
    ErrorLog.instance.record('app', 'second');
    // A fresh reader (empty memory) must still see the file.
    final fresh = ErrorLog.forTesting()..bind(dir.path);
    final (entries, problems) = fresh.readAll();
    expect(problems, isEmpty);
    expect([for (final entry in entries) entry.message], ['second', 'first']);
  });

  test('a missing file is an empty list, not a failure', () {
    ErrorLog.instance.clear();
    final (entries, problems) = ErrorLog.instance.readAll();
    expect(entries, isEmpty);
    expect(problems, isEmpty);
  });

  test('clear empties both', () {
    ErrorLog.instance.record('app', 'gone soon');
    expect(ErrorLog.instance.clear(), isTrue);
    final (entries, _) = ErrorLog.instance.readAll();
    expect(entries, isEmpty);
    expect(File(ErrorLog.instance.filePath).existsSync(), isFalse);
  });
}

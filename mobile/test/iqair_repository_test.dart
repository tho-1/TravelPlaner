import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:travel_planner/data/iqair_repository.dart';

void main() {
  test('unconfigured returns empty', () async {
    final repo = IqairRepository('');
    expect(await repo.load(), isEmpty);
  });

  test('missing file returns empty and caches', () async {
    final dir = Directory.systemTemp.createTempSync('iqair');
    final repo = IqairRepository(p.join(dir.path, 'missing.json'));
    expect(await repo.load(), isEmpty);
    // second call stays empty (cached)
    expect(await repo.load(), isEmpty);
    dir.deleteSync(recursive: true);
  });

  test('malformed file returns empty and caches', () async {
    final dir = Directory.systemTemp.createTempSync('iqair');
    final file = File(p.join(dir.path, 'bad.json'));
    file.writeAsStringSync('{not json');
    final repo = IqairRepository(file.path);
    expect(await repo.load(), isEmpty);
    expect(await repo.load(), isEmpty);
    dir.deleteSync(recursive: true);
  });

  test('valid file parses and caches', () async {
    final dir = Directory.systemTemp.createTempSync('iqair');
    final file = File(p.join(dir.path, 'ok.json'));
    file.writeAsStringSync(jsonEncode({
      'cities': [
        {'rank': 1, 'city': 'Tokyo', 'country': 'Japan', 'pm25': {'2025': 12.3}},
      ],
    }));
    final repo = IqairRepository(file.path);
    final first = await repo.load();
    expect(first, hasLength(1));
    // mutate file; cached result stays
    file.writeAsStringSync(jsonEncode({'cities': []}));
    final second = await repo.load();
    expect(second, hasLength(1));
    dir.deleteSync(recursive: true);
  });
}

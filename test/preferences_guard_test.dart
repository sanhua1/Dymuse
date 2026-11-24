import 'dart:io';
import 'dart:typed_data';

import 'package:dymuse/platform/preferences_guard.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory dir;
  late File file;
  setUp(() {
    dir = Directory.systemTemp.createTempSync('dymuse_prefs_guard_');
    file = File('${dir.path}${Platform.pathSeparator}shared_preferences.json');
  });

  test('全 0 的设置文件改名留存，原位置空出来', () async {
    file.writeAsBytesSync(Uint8List(4096));
    final backup = await quarantineCorruptPreferences(
      file,
      now: DateTime(2026, 11, 20, 17, 5, 9),
    );
    expect(backup, isNotNull);
    expect(backup!.path, endsWith('shared_preferences.json.corrupt-20261120170509'));
    expect(backup.lengthSync(), 4096);
    expect(file.existsSync(), isFalse);
  });

  test('写了一半的 JSON、非法 UTF-8 也算损坏', () async {
    file.writeAsStringSync('{"flutter.lastMode":"bili');
    expect(await quarantineCorruptPreferences(file), isNotNull);
    file.writeAsBytesSync([0xff, 0xfe, 0x7b]);
    expect(
      await quarantineCorruptPreferences(file, now: DateTime(2027)),
      isNotNull,
    );
  });

  test('正常、空文件、不存在时不动', () async {
    expect(await quarantineCorruptPreferences(file), isNull);
    file.writeAsStringSync('');
    expect(await quarantineCorruptPreferences(file), isNull);
    file.writeAsStringSync('{"flutter.lastMode":"bilibili"}');
    expect(await quarantineCorruptPreferences(file), isNull);
    expect(file.readAsStringSync(), '{"flutter.lastMode":"bilibili"}');
  });
}

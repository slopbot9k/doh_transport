import 'dart:io';

import 'package:test/test.dart';

void main() {
  test('the example compiles', () async {
    final out = await Directory.systemTemp.createTemp('doh_transport_example');
    addTearDown(() => out.delete(recursive: true));
    final result = await Process.run(Platform.resolvedExecutable, [
      'compile',
      'kernel',
      '-o',
      '${out.path}/example.dill',
      'example/doh_transport_example.dart',
    ]);
    expect(result.stderr, isEmpty);
    expect(result.exitCode, 0);
  }, timeout: const Timeout(Duration(minutes: 2)));
}

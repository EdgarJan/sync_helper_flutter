import 'dart:io';

import 'package:test/test.dart';

void main() {
  test('sync_generator.dart exits with code 1 when no arguments are provided',
      () async {
    // Use the same Dart executable that is running the tests to execute the
    // script. This is more reliable than assuming `dart` is on PATH.
    final dartExecutable = 'dart';

    // Run the script located in the `bin` directory without any CLI arguments.
    final result = await Process.run(
      dartExecutable,
      ['bin/sync_generator.dart'],
      workingDirectory: Directory.current.path,
    );

    // Script should exit with non-zero status.
    expect(result.exitCode, equals(1));

    // Verify that it lists all missing argument names in its output.
    final combinedOutput = (result.stdout ?? '') + (result.stderr ?? '');
    expect(
      combinedOutput,
      allOf(
        contains('Missing argument'),
        contains('server_url'),
        contains('app_id'),
        contains('auth_token'),
      ),
    );
  });
}

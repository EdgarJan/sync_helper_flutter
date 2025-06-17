import 'dart:async';
import 'dart:io';

import 'package:test/test.dart';

Future<void> main() async {
  const correctToken = 'correct_token';
  const incorrectToken = 'wrong_token';
  const port = 8888; // fixed port for the mock server in tests

  late Process serverProcess;

  // Helper to start the mock server before the tests and stop it afterwards.
  setUpAll(() async {
    final dartExecutable = Platform.resolvedExecutable;
    serverProcess = await Process.start(
      dartExecutable,
      ['bin/mock_sync_server.dart', port.toString(), correctToken],
      workingDirectory: Directory.current.path,
    );

    // Wait until the server prints its listening message.
    await serverProcess.stdout
        .transform(SystemEncoding().decoder)
        .firstWhere((line) => line.contains('Mock sync server listening'));
  });

  tearDownAll(() async {
    serverProcess.kill(ProcessSignal.sigterm);
    await serverProcess.exitCode;
  });

  test(
      'sync_generator exits with code 1 when server returns 401 due to invalid token',
      () async {
    final dartExecutable = Platform.resolvedExecutable;

    final generatorResult = await Process.run(
      dartExecutable,
      [
        'bin/sync_generator.dart',
        'http://localhost:$port',
        'TEST_APP',
        incorrectToken,
      ],
      workingDirectory: Directory.current.path,
    );

    // Should exit with 1 because the mock server returns 401 (generator treats
    // any non-200 as error and exits 1).
    expect(generatorResult.exitCode, equals(1));

    final output = (generatorResult.stdout ?? '') + (generatorResult.stderr ?? '');
    // The generator should print the HTTP error code 401 in its feedback.
    expect(output, contains('401'));
  });
}

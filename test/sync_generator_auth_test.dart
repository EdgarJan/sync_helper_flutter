import 'dart:async';
import 'dart:io';

import 'package:test/test.dart';

Future<void> main() async {
  const correctToken = 'correct_token';
  const incorrectToken = 'wrong_token';
  // Bind to port 0 so the operating system chooses a free port at runtime –
  // this avoids random build failures when the hard-coded port is already in
  // use on the CI runner.
  int? port;

  late Process serverProcess;

  // Helper to start the mock server before the tests and stop it afterwards.
  setUpAll(() async {
    final dartExecutable = Platform.resolvedExecutable;
    serverProcess = await Process.start(
      dartExecutable,
      ['bin/mock_sync_server.dart', '0', correctToken],
      workingDirectory: Directory.current.path,
    );

    // Wait until the server prints its listening message.
    // Wait until the mock server prints its listening banner so we know it is
    // ready.  Guard the wait with a timeout so that the test suite fails fast
    // (instead of hanging forever) when the server cannot start – e.g. when
    // the requested port is already occupied on the CI runner.
    final listeningLine = await serverProcess.stdout
        .transform(SystemEncoding().decoder)
        .firstWhere((line) => line.contains('Mock sync server listening'))
        .timeout(const Duration(seconds: 10));

    // Extract the effective port the server is listening on from the banner.
    final match = RegExp(r'http://localhost:(\d+)').firstMatch(listeningLine);
    if (match == null) {
      throw StateError('Could not determine port from server output: ' +
          listeningLine);
    }
    port = int.parse(match.group(1)!);
  });

  tearDownAll(() async {
    serverProcess.kill(ProcessSignal.sigterm);
    await serverProcess.exitCode;
  });

  test(
      'sync_generator exits with code 1 when server returns 401 due to invalid token',
      () async {
    final dartExecutable = Platform.resolvedExecutable;

    if (port == null) {
      throw StateError('Mock server did not start');
    }

    final generatorResult = await Process.run(
      dartExecutable,
      [
        'bin/sync_generator.dart',
        'http://localhost:${port!}',
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

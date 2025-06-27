import 'dart:io';

import 'package:test/test.dart';

/// End-to-end test that runs `bin/sync_generator.dart` against the mock server
/// with valid credentials and verifies that a meaningful `pregenerated.dart`
/// file is produced for the `lt.helper.hard_app` application.
void main() {
  const token = '75D2BCBC-2490-4525-A499-4FFFFDE81D67';
  // The port is selected dynamically at runtime to avoid collisions.
  int? port;
  late String serverUrl;
  const appId = 'lt.helper.hard_app';

  late Process serverProcess;

  setUpAll(() async {
    // Delete any stale pregenerated.dart file from previous runs.
    final pregeneratedFile = File('pregenerated.dart');
    if (await pregeneratedFile.exists()) {
      await pregeneratedFile.delete();
    }

    final dartExecutable = Platform.resolvedExecutable;

    // Start the mock server on a random free port (pass 0).
    serverProcess = await Process.start(
      dartExecutable,
      ['bin/mock_sync_server.dart', '0', token],
      workingDirectory: Directory.current.path,
    );

    // Wait until the server prints the banner, then parse the actual port.
    final listeningLine = await serverProcess.stdout
        .transform(SystemEncoding().decoder)
        .firstWhere((line) => line.contains('Mock sync server listening'))
        .timeout(const Duration(seconds: 10));

    final match = RegExp(r'http://localhost:(\d+)').firstMatch(listeningLine);
    if (match == null) {
      throw StateError('Could not determine port from server output: ' +
          listeningLine);
    }

    port = int.parse(match.group(1)!);
    serverUrl = 'http://localhost:$port';
  });

  tearDownAll(() async {
    serverProcess.kill(ProcessSignal.sigterm);
    await serverProcess.exitCode;

    // Clean up the generated file to keep repository tidy.
    final pregeneratedFile = File('pregenerated.dart');
    if (await pregeneratedFile.exists()) {
      await pregeneratedFile.delete();
    }
  });

  test('sync_generator produces pregenerated.dart for hard_app', () async {
    final dartExecutable = Platform.resolvedExecutable;

    final result = await Process.run(
      dartExecutable,
      ['bin/sync_generator.dart', serverUrl, appId, token],
      workingDirectory: Directory.current.path,
    );

    // Expect success exit code.
    expect(result.exitCode, equals(0),
        reason: 'sync_generator should exit with code 0 on success');

    // Ensure the file now exists.
    final pregeneratedFile = File('pregenerated.dart');
    expect(await pregeneratedFile.exists(), isTrue,
        reason: 'pregenerated.dart should be created');

    final contents = await pregeneratedFile.readAsString();

    // Minimal sanity checks to ensure correct content is generated.
    expect(contents, contains("class SyncConstants"));
    expect(contents, contains("final String appId = '$appId'"));
    expect(contents, contains('CREATE TABLE IF NOT EXISTS "applications"'));
    expect(contents, contains('class Applications'));
    expect(contents, contains('class Schedules'));
  });
}

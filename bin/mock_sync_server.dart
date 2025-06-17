// A minimal mock server for `sync_generator.dart` testing and development.
//
// Usage:
//   dart bin/mock_sync_server.dart [port]
//
// The server listens on localhost (0.0.0.0) at the given port (default 8080)
// and responds to the following endpoint:
//   GET /models → 200 OK with an empty JSON array `[]`.
//
// All other paths return 404.

import 'dart:convert';
import 'dart:io';

Future<void> main(List<String> args) async {
  // First CLI argument: port (default 8080) – pass 0 to bind to a random port.
  final portArg = args.isNotEmpty ? args[0] : '8080';
  final int port = int.tryParse(portArg) ?? 8080;

  // Second CLI argument: expected token (default 'mock_token').
  final expectedAuthToken = args.length >= 2 ? args[1] : 'mock_token';

  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
  final effectivePort = server.port;
  print('Mock sync server listening on http://localhost:$effectivePort');
  print('Expected Bearer token: $expectedAuthToken');

  await for (final HttpRequest request in server) {
    final path = request.uri.path;

    if (request.method == 'GET' && (path == '/models' || path.endsWith('/models'))) {
      final authHeader = request.headers.value(HttpHeaders.authorizationHeader);
      final expectedHeaderValue = 'Bearer $expectedAuthToken';

      if (authHeader != expectedHeaderValue) {
        request.response.statusCode = HttpStatus.unauthorized;
        request.response.write('Unauthorized');
      } else {
        // Authorized: return empty models list.
        final responseBody = jsonEncode(<dynamic>[]);
        request.response.statusCode = HttpStatus.ok;
        request.response.headers
            .set(HttpHeaders.contentTypeHeader, ContentType.json.mimeType);
        request.response.write(responseBody);
      }
    } else {
      request.response.statusCode = HttpStatus.notFound;
      request.response.write('Not Found');
    }

    await request.response.close();
  }
}

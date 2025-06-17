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

  // Pre-build a list of example models that will be returned when the client
  // supplies the expected bearer token.  The structure tries to mimic the
  // real sync-server payload but intentionally keeps only the fields that are
  // required by `sync_generator.dart`.

  Map<String, dynamic> _buildBasicTable(String tableName) => {
        'name': tableName,
        'is_syncable': true,
        'columns': [
          {
            'name': 'id',
            'type': 'text',
            'constraints': ['primary_key']
          },
          {
            'name': 'lts',
            'type': 'integer'
          },
          {
            'name': 'is_deleted',
            'type': 'integer'
          },
          {
            'name': 'is_unsynced',
            'type': 'integer'
          },
          {
            'name': 'name',
            'type': 'text'
          },
        ],
      };

  Map<String, dynamic> _buildModel(String appId, int version) {
    const tableName = 'items';

    return {
      'app_id': appId,
      'version': version,
      'client_create': [
        {
          'sql':
              'CREATE TABLE IF NOT EXISTS "$tableName" ("id" TEXT PRIMARY KEY, "name" TEXT);',
          'type': 'execute'
        }
      ],
      'client_migration': <dynamic>[],
      'model': {
        'app_id': appId,
        'version': version,
        'tables': <dynamic>[]
      },
      'model_with_client_defaults': {
        'app_id': appId,
        'version': version,
        'tables': [
          _buildBasicTable(tableName),
          {
            'name': 'syncing_table',
            'is_syncable': true,
            'columns': [
              {
                'name': 'entity_name',
                'type': 'text'
              },
              {
                'name': 'last_received_lts',
                'type': 'integer'
              },
            ]
          }
        ]
      },
    };
  }

  final List<Map<String, dynamic>> _models = [
    _buildModel('TEST_APP', 1),
    // Provide a richer model for lt.helper.hard_app to be used in integration tests.
    {
      'app_id': 'lt.helper.hard_app',
      'version': 1,
      'client_create': [
        {
          'sql': 'CREATE TABLE IF NOT EXISTS "applications" (\n  "id" TEXT PRIMARY KEY,\n  "lts" INTEGER,\n  "is_deleted" INTEGER,\n  "is_unsynced" INTEGER,\n  "version" TEXT\n);',
          'type': 'execute'
        },
        {
          'sql': 'CREATE TABLE IF NOT EXISTS "schedules" (\n  "id" TEXT PRIMARY KEY,\n  "lts" INTEGER,\n  "is_deleted" INTEGER,\n  "is_unsynced" INTEGER,\n  "id_name" TEXT,\n  "name" TEXT,\n  "comment" TEXT,\n  "tags" TEXT,\n  "delay" TEXT,\n  "delayDate" TEXT,\n  "priority" INTEGER,\n  "cts" TEXT\n);',
          'type': 'execute'
        },
        {
          'sql': 'CREATE TABLE IF NOT EXISTS "syncing_table" (\n  "entity_name" TEXT,\n  "last_received_lts" INTEGER\n);',
          'type': 'execute'
        },
        {
          'sql': 'INSERT INTO "syncing_table" (entity_name) VALUES(?);',
          'type': 'batch',
          'params': [
            ['applications'],
            ['schedules']
          ]
        }
      ],
      'client_migration': [
        {
          'sql': 'CREATE TABLE IF NOT EXISTS "applications" (\n  "id" TEXT PRIMARY KEY,\n  "lts" INTEGER,\n  "is_deleted" INTEGER,\n  "is_unsynced" INTEGER,\n  "version" TEXT\n);',
          'type': 'execute'
        },
        {
          'sql': 'CREATE TABLE IF NOT EXISTS "schedules" (\n  "id" TEXT PRIMARY KEY,\n  "lts" INTEGER,\n  "is_deleted" INTEGER,\n  "is_unsynced" INTEGER,\n  "id_name" TEXT,\n  "name" TEXT,\n  "comment" TEXT,\n  "tags" TEXT,\n  "delay" TEXT,\n  "delayDate" TEXT,\n  "priority" INTEGER,\n  "cts" TEXT\n);',
          'type': 'execute'
        },
        {
          'sql': 'CREATE TABLE IF NOT EXISTS "syncing_table" (\n  "entity_name" TEXT,\n  "last_received_lts" INTEGER\n);',
          'type': 'execute'
        },
        {
          'sql': 'INSERT INTO "syncing_table" (entity_name) VALUES(?);',
          'type': 'batch',
          'params': [
            ['applications'],
            ['schedules']
          ]
        }
      ],
      'model_with_client_defaults': {
        'app_id': 'lt.helper.hard_app',
        'version': 1,
        'tables': [
          _buildBasicTable('applications')
            ..['columns'].add({'name': 'version', 'type': 'text'}),
          {
            'name': 'schedules',
            'is_syncable': true,
            'columns': [
              {
                'name': 'id',
                'type': 'text',
                'constraints': ['primary_key']
              },
              {
                'name': 'lts',
                'type': 'integer'
              },
              {
                'name': 'is_deleted',
                'type': 'integer'
              },
              {
                'name': 'is_unsynced',
                'type': 'integer'
              },
              {'name': 'id_name', 'type': 'text'},
              {'name': 'name', 'type': 'text'},
              {'name': 'comment', 'type': 'text'},
              {'name': 'tags', 'type': 'text'},
              {'name': 'delay', 'type': 'text'},
              {'name': 'delayDate', 'type': 'text'},
              {'name': 'priority', 'type': 'integer'},
              {'name': 'cts', 'type': 'text'},
            ]
          },
          {
            'name': 'syncing_table',
            'is_syncable': true,
            'columns': [
              {'name': 'entity_name', 'type': 'text'},
              {'name': 'last_received_lts', 'type': 'integer'},
            ]
          }
        ]
      },
    },
    _buildModel('lt.helper.events_app', 1),
    _buildModel('lt.helper.places_app', 1),
    // Two versions for elo_duel_app to allow generator to pick the latest.
    _buildModel('lt.helper.elo_duel_app', 1),
    _buildModel('lt.helper.elo_duel_app', 2),
  ];

  final encodedModels = jsonEncode(_models);

  await for (final HttpRequest request in server) {
    final path = request.uri.path;

    if (request.method == 'GET' && (path == '/models' || path.endsWith('/models'))) {
      final authHeader = request.headers.value(HttpHeaders.authorizationHeader);
      final expectedHeaderValue = 'Bearer $expectedAuthToken';

      if (authHeader != expectedHeaderValue) {
        request.response.statusCode = HttpStatus.unauthorized;
        request.response.write('Unauthorized');
      } else {
        // Authorized: return the predefined models list.
        request.response.statusCode = HttpStatus.ok;
        request.response.headers
            .set(HttpHeaders.contentTypeHeader, ContentType.json.mimeType);
        request.response.write(encodedModels);
      }
    } else {
      request.response.statusCode = HttpStatus.notFound;
      request.response.write('Not Found');
    }

    await request.response.close();
  }
}

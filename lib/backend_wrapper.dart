import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:collection/collection.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart' show kDebugMode, kIsWeb;
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sentry_flutter/sentry_flutter.dart';
import 'package:sqlite_async/sqlite3.dart';
import 'package:sqlite_async/sqlite3_common.dart';
import 'package:sqlite_async/sqlite_async.dart';
import 'package:sync_helper_flutter/sync_abstract.dart';
import 'package:uuid/uuid.dart';

class BackendNotifier extends ChangeNotifier {
  final AbstractPregeneratedMigrations abstractPregeneratedMigrations;
  final AbstractSyncConstants abstractSyncConstants;
  final AbstractMetaEntity abstractMetaEntity;

  SqliteDatabase? _db;
  bool _sseConnected = false;
  StreamSubscription? _eventSubscription;
  String? userId;

  BackendNotifier({
    required this.abstractPregeneratedMigrations,
    required this.abstractSyncConstants,
    required this.abstractMetaEntity,
  }) : _httpClient = SentryHttpClient(client: http.Client());

  // HTTP client wrapped with Sentry for automatic breadcrumbs / tracing
  final http.Client _httpClient;

  // Get Firebase auth token (required)
  Future<String> _getAuthToken() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      throw Exception('User not authenticated with Firebase');
    }

    final firebaseToken = await user.getIdToken();
    if (firebaseToken == null || firebaseToken.isEmpty) {
      throw Exception('Firebase auth token is required but not available');
    }
    return firebaseToken;
  }

  SqliteDatabase? get db => _db;
  bool get sseConnected => _sseConnected;
  bool get isSyncing => fullSyncStarted;

  // ---------------------------------------------------------------------------
  // Logging helpers that respect the host application's Sentry setup. Calls are
  // no-ops when Sentry isn't initialized.
  // ---------------------------------------------------------------------------

  void _logDebug(String message) {
    // Using the new Sentry logger API (v9) so that logs show up in the Logs UI
    // once the application has enabled it.
    Sentry.logger.debug(message);
    if (kDebugMode) {
      // Retain local console output during development for convenience.
      // ignore: avoid_print
      print(message);
    }
  }

  void _logWarning(String message) {
    Sentry.logger.warn(message);
    if (kDebugMode) {
      // ignore: avoid_print
      print(message);
    }
  }

  void _logError(String message, {Object? error, StackTrace? stackTrace}) {
    Sentry.logger.error(message);
    // Forward the throwable so that it appears as an error event as well.
    if (error != null) {
      Sentry.captureException(error, stackTrace: stackTrace);
    }
    if (kDebugMode) {
      // ignore: avoid_print
      print(message);
      if (error != null) {
        // ignore: avoid_print
        print(error);
      }
      if (stackTrace != null) {
        // ignore: avoid_print
        print(stackTrace);
      }
    }
  }

  Future<void> _initAndApplyDeviceInfo() async {
    try {
      final packageInfo = await PackageInfo.fromPlatform();
      final deviceInfo = DeviceInfoPlugin();
      Map<String, dynamic> deviceData = {};
      String? osName;

      if (kIsWeb) {
        final webInfo = await deviceInfo.webBrowserInfo;
        osName = 'Web';
        deviceData = {
          'browser': webInfo.browserName.name,
          'appVersion': webInfo.appVersion,
          'platform': webInfo.platform,
          'vendor': webInfo.vendor,
        };
      } else {
        if (Platform.isAndroid) {
          final androidInfo = await deviceInfo.androidInfo;
          osName = 'Android';
          deviceData = {
            'version.release': androidInfo.version.release,
            'version.sdkInt': androidInfo.version.sdkInt,
            'manufacturer': androidInfo.manufacturer,
            'model': androidInfo.model,
            'isPhysicalDevice': androidInfo.isPhysicalDevice,
          };
        } else if (Platform.isIOS) {
          final iosInfo = await deviceInfo.iosInfo;
          osName = 'iOS';
          deviceData = {
            'systemVersion': iosInfo.systemVersion,
            'utsname.machine': iosInfo.utsname.machine,
            'isPhysicalDevice': iosInfo.isPhysicalDevice,
          };
        } else if (Platform.isLinux) {
          final linuxInfo = await deviceInfo.linuxInfo;
          osName = 'Linux';
          deviceData = {
            'name': linuxInfo.name,
            'version': linuxInfo.version,
            'versionId': linuxInfo.versionId,
            'prettyName': linuxInfo.prettyName,
          };
        } else if (Platform.isMacOS) {
          final macOsInfo = await deviceInfo.macOsInfo;
          osName = 'macOS';
          deviceData = {
            'osRelease': macOsInfo.osRelease,
            'model': macOsInfo.model,
            'arch': macOsInfo.arch,
            'hostName': macOsInfo.hostName,
          };
        } else if (Platform.isWindows) {
          final windowsInfo = await deviceInfo.windowsInfo;
          osName = 'Windows';
          deviceData = {
            'productName': windowsInfo.productName,
            'buildNumber': windowsInfo.buildNumber,
            'displayVersion': windowsInfo.displayVersion,
          };
        }
      }

      await Sentry.configureScope((scope) async {
        scope.setContexts('app', {
          'name': packageInfo.appName,
          'version': packageInfo.version,
          'buildNumber': packageInfo.buildNumber,
          'packageName': packageInfo.packageName,
        });
        scope.setContexts('device', deviceData);
        if (osName != null) {
          scope.setTag('os', osName);
        }
      });
    } catch (e, stackTrace) {
      _logError('Failed to set Sentry device info',
          error: e, stackTrace: stackTrace);
    }
  }

  Future<void> initDb({required String userId}) async {
    this.userId = userId;
    await _initAndApplyDeviceInfo();
    final tempDb = await _openDatabase();
    await abstractPregeneratedMigrations.migrations.migrate(tempDb);
    _db = tempDb;
    
    // Register archive table with latest LTS from server to avoid syncing old archives
    await _registerTable('archive');
    
    _startSyncer();
    notifyListeners();
  }
  
  Future<void> _registerTable(String tableName) async {
    // Check if table is already registered
    final existing = await _db!.getOptional(
      'SELECT last_received_lts FROM syncing_table WHERE entity_name = ?',
      [tableName],
    );
    
    if (existing != null) {
      _logDebug('Table $tableName already registered with LTS ${existing['last_received_lts']}');
      return;
    }
    
    // Try to get latest LTS from server with retries
    int? latestLts;
    int retries = 3;
    
    while (retries > 0 && latestLts == null) {
      try {
        final token = await _getAuthToken();
        final response = await _httpClient.get(
          Uri.parse('${abstractSyncConstants.serverUrl}/latest-lts?name=$tableName'),
          headers: {
            'Authorization': 'Bearer $token',
          },
        );
        
        if (response.statusCode == 200) {
          final data = jsonDecode(response.body);
          latestLts = data['lts'] as int?;
          _logDebug('Got latest LTS for $tableName: $latestLts');
        } else if (response.statusCode == 403 || response.statusCode == 404) {
          // Table doesn't exist on server yet, use 0
          latestLts = 0;
          _logDebug('Table $tableName not found on server, using LTS 0');
        } else {
          throw Exception('Failed to get latest LTS: ${response.statusCode}');
        }
      } catch (e) {
        retries--;
        _logWarning('Failed to get latest LTS for $tableName, retries left: $retries');
        if (retries > 0) {
          await Future.delayed(Duration(seconds: 2));
        }
      }
    }
    
    // Register table with the LTS we got (or 0 if all retries failed)
    final ltsToUse = latestLts ?? 0;
    await _db!.execute(
      'INSERT INTO syncing_table (entity_name, last_received_lts) VALUES (?, ?)',
      [tableName, ltsToUse],
    );
    _logDebug('Registered table $tableName with initial LTS $ltsToUse');
  }

  Future<void> deinitDb() async {
    await _eventSubscription?.cancel();
    _eventSubscription = null;
    _sseConnected = false;
    if (_db != null) await _db!.close();
    _db = null;
    // Note: we intentionally keep the HTTP client alive for the lifetime of
    // this notifier instance. Users typically dispose the BackendNotifier once
    // during app shutdown, in which case the process exits and sockets are
    // cleaned up automatically.
    notifyListeners();
  }

  Stream<List> watch(String sql, {List<String>? triggerOnTables}) {
    return _db!.watch(sql, triggerOnTables: triggerOnTables);
  }

  Future<ResultSet> getAll({
    required String sql,
    String where = '',
    String order = '',
  }) {
    final _where = where.isNotEmpty ? ' WHERE $where' : '';
    final _order = order.isNotEmpty ? ' ORDER BY $order' : '';
    return _db!.getAll(sql + _where + _order);
  }

  Future<void> write({required String tableName, required Map data}) async {
    if (data['id'] == null) {
      data['id'] = Uuid().v4();
    }
    final columns = data.keys.toList();
    final values = data.values.toList();
    final placeholders = List.filled(columns.length, '?').join(', ');
    final updatePlaceholders = columns.map((c) => '$c = ?').join(', ');
    final sql =
        '''
      INSERT INTO $tableName (${columns.join(', ')}, is_unsynced)
      VALUES ($placeholders, 1)
      ON CONFLICT(id) DO UPDATE SET $updatePlaceholders, is_unsynced = 1
    ''';
    await _db!.execute(sql, [...values, ...values]);
    await fullSync();
  }

  Future<void> delete({required String tableName, required String id}) async {
    try {
      await _db!.writeTransaction((tx) async {
        // Read the row to archive before deletion
        final row = await tx.getOptional(
          'SELECT * FROM $tableName WHERE id = ?',
          [id],
        );

        if (row != null) {
          // Create an archive record with the full original row payload
          final archiveId = const Uuid().v4();
          final archiveData = jsonEncode(row);
          await tx.execute(
            'INSERT INTO archive (id, table_name, data, data_id, is_unsynced) VALUES (?, ?, ?, ?, 1)',
            [archiveId, tableName, archiveData, id],
          );
          _logDebug('Archived row before delete: $tableName/$id as archive/$archiveId');
        } else {
          _logWarning('Delete requested but row not found: $tableName/$id');
        }

        // Perform the actual delete locally
        await tx.execute(
          'DELETE FROM $tableName WHERE id = ?',
          [id],
        );
      });
    } catch (e, st) {
      _logError('Failed to archive+delete $tableName/$id', error: e, stackTrace: st);
      rethrow;
    }
    await fullSync();
  }

  Future<SqliteDatabase> _openDatabase() async {
    final path = await _getDatabasePath('$userId/helper_sync.db');
    return SqliteDatabase(
      path: path,
      options: SqliteOptions(
        webSqliteOptions: WebSqliteOptions(
          wasmUri: 'sqlite3.wasm',
          workerUri: 'db_worker.js',
        ),
      ),
    );
  }

  Future<String> _getDatabasePath(String name) async {
    String base = '';
    if (!kIsWeb) {
      final dir = await getApplicationDocumentsDirectory();
      base = dir.path;
    }

    // Determine application identifier (bundle id / package name) so that
    // database files are namespaced per-application first and then per-user.
    String appId = 'unknown_app';
    try {
      final info = await PackageInfo.fromPlatform();
      if (info.packageName.isNotEmpty) appId = info.packageName;
    } catch (_) {
      // If PackageInfo isn't available on the current platform we silently
      // fall back to a default folder to avoid crashing.
    }

    final full = p.join(base, appId, name);
    final dir = Directory(p.dirname(full));
    if (!await dir.exists()) await dir.create(recursive: true);
    return full;
  }

  Future<void> _fetchData({
    required String name,
    int? lastReceivedLts,
    required int pageSize,
    required Future<void> Function(Map<String, dynamic>) onData,
  }) async {
    final q = {
      'name': name, 
      'pageSize': pageSize.toString(),
      'app_id': abstractSyncConstants.appId,  // Include app_id
    };
    if (lastReceivedLts != null) q['lts'] = lastReceivedLts.toString();
    final uri = Uri.parse('${abstractSyncConstants.serverUrl}/data')
        .replace(queryParameters: q);
    
    // Get auth token (Firebase or fallback)
    final authToken = await _getAuthToken();
    
    final response = await _httpClient.get(
      uri,
      headers: {'Authorization': 'Bearer $authToken'},
    );
    if (response.statusCode == 200) {
      final data = jsonDecode(response.body);
      await onData(data);
    } else {
      throw Exception('Failed to fetch data');
    }
  }

  var fullSyncStarted = false;
  bool repeat = false;

  //todo: sometimes we need to sync only one table, not all
  Future<void> fullSync() async {
    _logDebug('Starting full sync');
    if (fullSyncStarted) {
      _logDebug('Full sync already started, skipping');
      repeat = true;
      return;
    }
    fullSyncStarted = true;
    notifyListeners();
    try {
      final tables = await _db!.getAll('select * from syncing_table');
      await _sendUnsynced(syncingTables: tables);
      for (var table in tables) {
        int page = 1000;
        bool more = true;
        int? lts = table['last_received_lts'] as int?;
        while (more && _db != null) {
          await _fetchData(
            name: table['entity_name'],
            lastReceivedLts: lts,
            pageSize: page,
            onData: (resp) async {
              await _db!.writeTransaction((tx) async {
                final unsynced = await tx.getAll(
                  'select * from ${table['entity_name']} where is_unsynced = 1',
                );
                if (unsynced.isNotEmpty) {
                  more = false;
                  repeat = true;
                  return;
                }
                _logDebug('Syncing ${table['entity_name']}');
                _logDebug('Last received LTS: $lts');
                _logDebug('Received ${resp['data']?.length ?? 0} rows');
                if ((resp['data']?.length ?? 0) == 0) {
                  more = false;
                  return;
                }
                final name = table['entity_name'];
                final data = List<Map<String, dynamic>>.from(resp['data']);
                _logDebug('Last LTS in response: ${data.last['lts']}');

                if (name == 'archive') {
                  // Handle archive messages: delete referenced local rows and clear archive entries locally
                  for (final row in data) {
                    final targetTable = row['table_name'] as String?;
                    final targetId = row['data_id'] as String?;
                    final archiveRowId = row['id'] as String?;
                    if (targetTable == null || targetId == null) {
                      continue;
                    }
                    // Delete referenced data row locally (idempotent)
                    await tx.execute('DELETE FROM ' + targetTable + ' WHERE id = ?', [targetId]);
                    // Also remove handled archive row locally if present
                    if (archiveRowId != null) {
                      await tx.execute('DELETE FROM archive WHERE id = ?', [archiveRowId]);
                    }
                  }
                  // Advance LTS for archive table
                  await tx.execute(
                    'UPDATE syncing_table SET last_received_lts = ? WHERE entity_name = ?',
                    [data.last['lts'], name],
                  );
                } else {
                  // Default upsert flow for regular tables
                  final pk = 'id';
                  final cols = abstractMetaEntity
                      .syncableColumnsList[table['entity_name']]!;
                  final placeholders = List.filled(cols.length, '?').join(', ');
                  final updates = cols
                      .where((c) => c != pk)
                      .map((c) => '$c = excluded.$c')
                      .join(', ');
                  final sql =
                      '''
INSERT INTO $name (${cols.join(', ')}) VALUES ($placeholders)
ON CONFLICT($pk) DO UPDATE SET $updates;
''';
                  final batch = data
                      .map<List<Object?>>(
                        (e) => cols.map<Object?>((c) => e[c]).toList(),
                      )
                      .toList();
                  await tx.executeBatch(sql, batch);
                  await tx.execute(
                    'UPDATE syncing_table SET last_received_lts = ? WHERE entity_name = ?',
                    [data.last['lts'], name],
                  );
                }
                if (data.length < page) {
                  more = false;
                } else {
                  lts = data.last['lts'] as int?;
                }
              });
            },
          );
        }
      }
    } catch (e, stackTrace) {
      _logError('Error during full sync', error: e, stackTrace: stackTrace);
    }

    fullSyncStarted = false;
    notifyListeners();

    if (repeat) {
      repeat = false;
      _logDebug('Need to repeat full sync');
      await fullSync();
    }
    _logDebug('Full sync completed');
  }

  Future<void> _sendUnsynced({required ResultSet syncingTables}) async {
    final db = _db!;
    bool retry;
    const int batchSize = 100; // Internal implementation detail
    
    do {
      retry = false;
      for (var table in syncingTables) {
        // Process in batches using LIMIT and OFFSET
        int offset = 0;
        bool hasMoreData = true;
        
        while (hasMoreData && !retry) {
          // Fetch a batch of unsynced rows
          final rows = await db.getAll(
            'select ${abstractMetaEntity.syncableColumnsString[table['entity_name']]} from ${table['entity_name']} where is_unsynced = 1 LIMIT $batchSize OFFSET $offset',
          );
          
          if (rows.isEmpty) {
            hasMoreData = false;
            continue;
          }
          
          final uri = Uri.parse('${abstractSyncConstants.serverUrl}/data')
              .replace(queryParameters: {'app_id': abstractSyncConstants.appId});  // Include app_id
          _logDebug('Sending unsynced data batch for ${table['entity_name']}: ${rows.length} rows (offset: $offset)');
          
          // Get auth token (Firebase or fallback)
          final authToken = await _getAuthToken();
          
          final res = await _httpClient.post(
            uri,
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $authToken',
            },
            body: jsonEncode({
              'name': table['entity_name'],
              'data': jsonEncode(rows),
            }),
          );
          
          if (res.statusCode != 200) {
            _logWarning(
                'Failed to send unsynced data batch for ${table['entity_name']}, status: ${res.statusCode}');
            retry = true;
            break;
          }
          
          // Mark only the successfully sent rows as synced
          await db.writeTransaction((tx) async {
            // Verify the same rows still exist and haven't changed
            final rows2 = await tx.getAll(
              'select ${abstractMetaEntity.syncableColumnsString[table['entity_name']]} from ${table['entity_name']} where is_unsynced = 1 LIMIT $batchSize OFFSET $offset',
            );
            
            if (DeepCollectionEquality().equals(rows, rows2)) {
              // Extract IDs from the sent rows
              final ids = rows.map((row) => row['id']).toList();
              final idPlaceholders = List.filled(ids.length, '?').join(', ');
              
              // No special handling needed for soft deletes
              
              // Mark remaining rows as synced
              await tx.execute(
                'update ${table['entity_name']} set is_unsynced = 0 where id IN ($idPlaceholders) and is_unsynced = 1',
                ids,
              );
              
              _logDebug(
                'Batch of ${rows.length} unsynced rows for ${table['entity_name']} sent and marked as synced',
              );
            } else {
              _logWarning(
                'Unsynced data batch for ${table['entity_name']} changed during sending, retrying sync',
              );
              retry = true;
            }
          });
          
          if (retry) {
            break;
          }
          
          // If we got fewer rows than the batch size, we've reached the end
          if (rows.length < batchSize) {
            hasMoreData = false;
          } else {
            // Move to the next batch
            offset += batchSize;
          }
        }
        
        if (retry) {
          break;
        }
      }
    } while (retry);
  }

  Future<void> _startSyncer() async {
    _logDebug('Starting SSE syncer');
    if (_sseConnected) {
      _logDebug('SSE syncer already connected, skipping start');
      return;
    }
    final uri = Uri.parse('${abstractSyncConstants.serverUrl}/events')
        .replace(queryParameters: {'app_id': abstractSyncConstants.appId});  // Include app_id
    _logDebug('Connecting to SSE at $uri');
    // Use Sentry-enabled HTTP client
    void handleError() {
      _logWarning('SSE connection error, retrying in 5 seconds');
      _sseConnected = false;
      notifyListeners();
      _eventSubscription?.cancel();
      Future.delayed(const Duration(seconds: 5), _startSyncer);
    }

    try {
      // Get auth token (Firebase or fallback)
      final authToken = await _getAuthToken();
      
      final request = http.Request('GET', uri)
        ..headers['Accept'] = 'text/event-stream'
        ..headers['Authorization'] = 'Bearer $authToken';
      final res = await _httpClient.send(request);
      if (res.statusCode == 200) {
        _sseConnected = true;
        notifyListeners();
        _logDebug('SSE connection established');
        _logDebug('Starting full sync after SSE connection');
        await fullSync();
        _eventSubscription = res.stream
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .listen(
              (e) {
                //todo: performance improvement, maybe we do not need full here
                _logDebug('SSE event received: $e');
                if (e.startsWith('data:')) {
                  _logDebug(
                    'Performing full sync after SSE event starting with "data:"',
                  );
                  fullSync();
                }
              },
              onError: (e) {
                _logWarning('SSE error: $e');
                handleError();
              },
            );
      } else {
        handleError();
      }
    } catch (e, st) {
      _logError('Error starting SSE', error: e, stackTrace: st);
      handleError();
    }
  }
}

class BackendWrapper extends InheritedNotifier<BackendNotifier> {
  const BackendWrapper({
    Key? key,
    required BackendNotifier notifier,
    required Widget child,
  }) : super(key: key, notifier: notifier, child: child);

  static BackendNotifier? of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<BackendWrapper>()?.notifier;
}

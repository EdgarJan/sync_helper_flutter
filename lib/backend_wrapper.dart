import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart' show kIsWeb, kDebugMode;
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
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
  String? _serverUrl;
  String? userId;

  BackendNotifier({
    required this.abstractPregeneratedMigrations,
    required this.abstractSyncConstants,
    required this.abstractMetaEntity,
  });

  SqliteDatabase? get db => _db;

  Future<void> initDb({String? serverUrl, required String userId}) async {
    _serverUrl = serverUrl ?? abstractSyncConstants.serverUrl;
    this.userId = userId;
    final tempDb = await _openDatabase();
    await abstractPregeneratedMigrations.migrations.migrate(tempDb);
    _db = tempDb;
    _startSyncer();
    notifyListeners();
  }

  Future<void> deinitDb() async {
    await _eventSubscription?.cancel();
    _eventSubscription = null;
    _sseConnected = false;
    if (_db != null) await _db!.close();
    _db = null;
    notifyListeners();
  }

  Stream<List> watch({
    required String sql,
    required List<String> tables,
    String where = '',
    String order = '',
  }) {
    final defaultWhere = ' where (is_deleted != 1 OR is_deleted IS NULL) ';
    final _where = where.isNotEmpty ? ' AND ($where)' : '';
    final _order = order.isNotEmpty ? ' ORDER BY $order' : '';
    return _db!.watch(
      sql + defaultWhere + _where + _order,
      triggerOnTables: tables,
    );
  }

  Future<ResultSet> getAll({
    required String sql,
    String where = '',
    String order = '',
  }) {
    final defaultWhere = ' where (is_deleted != 1 OR is_deleted IS NULL) ';
    final _where = where.isNotEmpty ? ' AND ($where)' : '';
    final _order = order.isNotEmpty ? ' ORDER BY $order' : '';
    return _db!.getAll(sql + defaultWhere + _where + _order);
  }

  Future<void> write({required String tableName, required Map data}) async {
    if (data['id'] == null) {
      data['id'] = Uuid().v4();
    }
    final columns = data.keys.toList();
    final values = data.values.toList();
    final placeholders = List.filled(columns.length, '?').join(', ');
    final updatePlaceholders = columns.map((c) => '$c = ?').join(', ');
    final sql = '''
      INSERT INTO $tableName (${columns.join(', ')}, is_unsynced)
      VALUES ($placeholders, 1)
      ON CONFLICT(id) DO UPDATE SET $updatePlaceholders, is_unsynced = 1
    ''';
    await _db!.execute(sql, [...values, ...values]);
    await fullSync();
  }

  Future<void> delete({required String tableName, required String id}) async {
    await _db!.execute(
      'UPDATE $tableName SET is_unsynced = 1, is_deleted = 1 WHERE id = ?',
      [id],
    );
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
    final full = p.join(base, name);
    final dir = Directory(p.dirname(full));
    if (!await dir.exists()) await dir.create(recursive: true);
    return full;
  }

  Future<void> _fetchData({
    required String name,
    String? lastReceivedLts,
    required int pageSize,
    required Future<void> Function(Map<String, dynamic>) onData,
  }) async {
    final q = {'name': name, 'pageSize': pageSize.toString()};
    if (lastReceivedLts != null) q['lts'] = lastReceivedLts;
    final uri = Uri.parse('$_serverUrl/data').replace(queryParameters: q);
    final response = await http.get(
      uri,
      headers: {'Authorization': 'Bearer ${abstractSyncConstants.authToken}'},
    );
    if (response.statusCode == 200) {
      final data = jsonDecode(response.body);
      await onData(data);
    } else {
      throw Exception('Failed to fetch data');
    }
  }

  //todo: sometimes we need to sync only one table, not all
  Future<void> fullSync() async {
    bool repeat = false;
    final tables = await _db!.getAll('select * from syncing_table');
    await _sendUnsynced(syncingTables: tables);
    for (var table in tables) {
      int page = 1000;
      bool more = true;
      String? lts = table['last_received_lts']?.toString() ?? '';
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
                //todo: might there be infinite loop, perhaps we need to log something to sentry for debug purposes
                repeat = true;
                return;
              }
              if (kDebugMode) {
                print('Syncing ${table['entity_name']}');
                print('Last received LTS: $lts');
                print('Received ${resp['data']?.length ?? 0} rows');
              }
              if ((resp['data']?.length ?? 0) == 0) {
                more = false;
                return;
              }
              final name = table['entity_name'];
              final pk = 'id';
              final cols = resp['data'][0].keys.toList();
              final placeholders = List.filled(cols.length, '?').join(', ');
              final updates = cols
                  .where((c) => c != pk)
                  .map((c) => '$c = excluded.$c')
                  .join(', ');
              final sql = '''
INSERT INTO $name (${cols.join(', ')}) VALUES ($placeholders)
ON CONFLICT($pk) DO UPDATE SET $updates;
''';
              final data = List<Map<String, dynamic>>.from(resp['data']);
              if (kDebugMode) {
                print('Last lts in response: ${data.last['lts']}');
              }
              final batch =
                  data
                      .map<List<Object?>>(
                        (e) => cols.map<Object?>((c) => e[c]).toList(),
                      )
                      .toList();
              await tx.executeBatch(sql, batch);
              await tx.execute(
                'UPDATE syncing_table SET last_received_lts = ? WHERE entity_name = ?',
                [data.last['lts'], name],
              );
              if (data.length < page) {
                more = false;
              } else {
                lts = data.last['lts'];
              }
            });
          },
        );
      }
    }
    if (repeat) await fullSync();
  }

  Future<void> _sendUnsynced({required ResultSet syncingTables}) async {
    final db = _db!;
    bool retry = false;
    for (var table in syncingTables) {
      final rows = await db.getAll(
        'select ${abstractMetaEntity.syncableColumns[table['id']]} from ${table['id']} where is_unsynced = 1',
      );
      if (rows.isEmpty) continue;
      final uri = Uri.parse('$_serverUrl/data');
      final res = await http.post(
        uri,
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer ${abstractSyncConstants.authToken}',
        },
        body: jsonEncode({'name': table['id'], 'data': jsonEncode(rows)}),
      );
      if (res.statusCode != 200) {
        //todo: not sure, may be infinite loop
        retry = true;
        break;
      }
      await db.writeTransaction((tx) async {
        //todo: not sure if this most efficient way
        final rows2 = await tx.getAll(
          'select ${abstractMetaEntity.syncableColumns[table['id']]} from ${table['id']} where is_unsynced = 1',
        );
        if (DeepCollectionEquality().equals(rows, rows2)) {
          await tx.execute(
            'delete from ${table['id']} where is_unsynced = 1 and is_deleted = 1',
          );
          await tx.execute(
            'update ${table['id']} set is_unsynced = 0 where is_unsynced = 1',
          );
        } else {
          retry = true;
        }
      });
      if (retry) {
        await _sendUnsynced(syncingTables: syncingTables);
        break;
      }
    }
  }

  Future<void> _startSyncer() async {
    if (_sseConnected) return;
    final uri = Uri.parse('$_serverUrl/events');
    final client = http.Client();
    void handleError() {
      _sseConnected = false;
      _eventSubscription?.cancel();
      Future.delayed(const Duration(seconds: 5), _startSyncer);
    }

    try {
      final request =
          http.Request('GET', uri)
            ..headers['Accept'] = 'text/event-stream'
            ..headers['Authorization'] =
                'Bearer ${abstractSyncConstants.authToken}';
      final res = await client.send(request);
      if (res.statusCode == 200) {
        _sseConnected = true;
        await fullSync();
        _eventSubscription = res.stream
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .listen(
              (e) {
                //todo: performance improvement, maybe we do not need full here
                if (e.startsWith('data:')) fullSync();
              },
              onError: (e) {
                if (kDebugMode) {
                  print('SSE error: $e');
                  handleError();
                }
              },
            );
      } else {
        handleError();
      }
    } catch (e) {
      if (kDebugMode) {
        print('Error starting SSE: $e');
      }
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

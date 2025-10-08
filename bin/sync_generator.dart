import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;

void main(List<String> args) async {
  const requiredArgNames = ['server_url', 'app_id'];

  if (args.length != requiredArgNames.length) {
    if (args.length < requiredArgNames.length) {
      final missing = requiredArgNames.sublist(args.length);
      final missingArgs = missing.map((n) => '<$n>').join(', ');
      final plural = missing.length > 1 ? 's' : '';
      print('Error: Missing argument$plural: $missingArgs');
    } else {
      // Extra arguments supplied.
      final extra = args.sublist(requiredArgNames.length).join(', ');
      print('Error: Unexpected extra argument${args.length - requiredArgNames.length > 1 ? 's' : ''}: $extra');
    }

    print('Usage: dart sync_generator.dart <server_url> <app_id>');
    exit(1);
  }

  String serverUrl = args[0];
  final targetAppId = args[1];

  // Prompt for email and password
  stdout.write('Enter email: ');
  final email = stdin.readLineSync()?.trim();

  if (email == null || email.isEmpty) {
    print('Error: Email is required');
    exit(1);
  }

  stdout.write('Enter password: ');
  final password = stdin.readLineSync()?.trim();

  if (password == null || password.isEmpty) {
    print('Error: Password is required');
    exit(1);
  }

  final outputFilePath = 'pregenerated.dart';

  if (serverUrl.endsWith('/')) {
    serverUrl = serverUrl.substring(0, serverUrl.length - 1);
  }

  final modelsUrl = Uri.parse('${serverUrl}/models?app_id=$targetAppId');
  final constantsServerUrl = args[0];

  try {
    print('Fetching data from: $modelsUrl');
    final response = await http.post(
      modelsUrl,
      headers: {
        'Content-Type': 'application/json',
        'Accept': 'application/json',
      },
      body: jsonEncode({
        'email': email,
        'password': password,
      }),
    );

    print('Response status code: ${response.statusCode}');
    print('Response headers: ${response.headers}');

    if (response.statusCode != 200) {
      print('Error fetching data from $modelsUrl: ${response.statusCode}');
      print('Response body: ${response.body}');
      exit(1);
    }

    final List<dynamic> allModels = jsonDecode(response.body);
    final List<dynamic> appModels =
        allModels
            .where((m) => m['app_id'] == targetAppId && m['version'] is int)
            .toList();

    if (appModels.isEmpty) {
      print('Error: No valid models found for app_id "$targetAppId".');
      exit(1);
    }

    appModels.sort(
      (a, b) => (a['version'] as int).compareTo(b['version'] as int),
    );

    final latestModel = appModels.last;
    final int latestVersion = latestModel['version'];

    final List<dynamic> latestClientCreateDdls =
        latestModel['client_create'] is List
            ? List<dynamic>.from(latestModel['client_create'])
            : [];

    if (latestClientCreateDdls.isEmpty) {
      print(
        'Error: client_create is null or empty for the latest version ($latestVersion) of app_id "$targetAppId".',
      );
      exit(1);
    }

    final modelDefaults = latestModel['model_with_client_defaults'];
    if (modelDefaults == null || modelDefaults is! Map<String, dynamic>) {
      print(
        'Error: "model_with_client_defaults" is missing or invalid in the latest version ($latestVersion) for app_id "$targetAppId".',
      );
      exit(1);
    }

    final List<dynamic> allTables =
        modelDefaults['tables'] is List
            ? List<dynamic>.from(modelDefaults['tables'])
            : [];

    final List<dynamic> syncableTables =
        allTables
            .where(
              (t) =>
                  t is Map<String, dynamic> ? t['is_syncable'] != false : false,
            )
            .toList();

    final buffer = StringBuffer();

    buffer.writeln("import 'package:sqlite_async/sqlite_async.dart';");
    buffer.writeln("import 'package:sync_helper_flutter/sync_abstract.dart';");
    buffer.writeln();

    buffer.writeln('class SyncConstants extends AbstractSyncConstants {');
    buffer.writeln("  @override");
    buffer.writeln("  final String appId = '$targetAppId';");
    buffer.writeln("  @override");
    buffer.writeln("  final String serverUrl = '$constantsServerUrl';");
    buffer.writeln('}');
    buffer.writeln();

    buffer.writeln(
      'class PregeneratedMigrations extends AbstractPregeneratedMigrations {',
    );
    buffer.writeln('  @override');
    buffer.writeln('  final SqliteMigrations migrations = SqliteMigrations()');

    for (final modelData in appModels) {
      final int currentVersion = modelData['version'];
      final List<dynamic> clientMigrationDdls =
          modelData['client_migration'] is List
              ? List<dynamic>.from(modelData['client_migration'])
              : [];

      buffer.writeln('    ..add(SqliteMigration(');
      buffer.writeln('      $currentVersion,');
      buffer.writeln('      (tx) async {');
      generateSqlExecutionCode(
        clientMigrationDdls,
        buffer,
        8,
        'client_migration',
        currentVersion,
      );
      buffer.writeln('      },');
      buffer.writeln('    ))');
    }

    buffer.writeln('    ..createDatabase = SqliteMigration(');
    buffer.writeln('      $latestVersion,');
    buffer.writeln('      (tx) async {');
    generateSqlExecutionCode(
      latestClientCreateDdls,
      buffer,
      8,
      'client_create',
      latestVersion,
    );
    buffer.writeln('      },');
    buffer.writeln('    );');
    buffer.writeln('}');
    buffer.writeln();

    buffer.writeln('class MetaEntity extends AbstractMetaEntity {');
    buffer.writeln('  @override');
    buffer.writeln('  final Map<String, String> syncableColumnsString = {');
    for (final tableData in syncableTables) {
      if (tableData is! Map<String, dynamic>) continue;
      final tableName = tableData['name'] as String?;
      if (tableName == null || tableName.isEmpty) continue;

      final columns =
          tableData['columns'] is List
              ? List<dynamic>.from(tableData['columns'])
              : [];
      final syncableColumnNames =
          columns
              .map((c) {
                if (c is! Map<String, dynamic>) return null;
                final colName = c['name'] as String?;
                final isSyncable = c['is_syncable'] as bool? ?? true;
                if (colName != null &&
                    colName.isNotEmpty &&
                    isSyncable &&
                    colName != 'is_unsynced') {
                  return colName;
                }
                return null;
              })
              .where((c) => c != null)
              .cast<String>()
              .toList();

      if (syncableColumnNames.isNotEmpty) {
        buffer.writeln("    '$tableName': '${syncableColumnNames.join(',')}',");
      }
    }
    buffer.writeln('  };');

    buffer.writeln('  @override');
    buffer.writeln('  final Map<String, List> syncableColumnsList = {');
    for (final tableData in syncableTables) {
      if (tableData is! Map<String, dynamic>) continue;
      final tableName = tableData['name'] as String?;
      if (tableName == null || tableName.isEmpty) continue;

      final columns =
          tableData['columns'] is List
              ? List<dynamic>.from(tableData['columns'])
              : [];
      final syncableColumnNames =
          columns
              .map((c) {
                if (c is! Map<String, dynamic>) return null;
                final colName = c['name'] as String?;
                final isSyncable = c['is_syncable'] as bool? ?? true;
                if (colName != null &&
                    colName.isNotEmpty &&
                    isSyncable &&
                    colName != 'is_unsynced') {
                  return colName;
                }
                return null;
              })
              .where((c) => c != null)
              .cast<String>()
              .toList();

      if (syncableColumnNames.isNotEmpty) {
        final columnListLiteral = jsonEncode(syncableColumnNames);
        buffer.writeln("    '$tableName': $columnListLiteral,");
      }
    }
    buffer.writeln('  };');
    buffer.writeln('}');
    buffer.writeln();

    final outputFile = File(outputFilePath);
    await outputFile.writeAsString(buffer.toString());

    print('Successfully generated $outputFilePath');
  } catch (e, s) {
    print('An error occurred: $e');
    print('Stack trace:\n$s');
    exit(1);
  }
}

void generateSqlExecutionCode(
  List<dynamic> ddlObjects,
  StringBuffer buffer,
  int indentLevel,
  String context,
  int version,
) {
  final indent = ' ' * indentLevel;
  if (ddlObjects.isEmpty) {
    return;
  }

  for (final ddlObject in ddlObjects) {
    if (ddlObject is! Map<String, dynamic>) {
      print(
        'Warning: Invalid DDL object format in $context for version $version: $ddlObject',
      );
      continue;
    }

    final type = ddlObject['type'] as String?;
    final sql = ddlObject['sql'] as String?;

    if (sql == null || sql.trim().isEmpty) {
      if (ddlObjects.length == 1) {
        continue;
      } else {
        print(
          'Warning: Missing or empty SQL for DDL object in $context for version $version: $ddlObject',
        );
        continue;
      }
    }

    final escapedSql = escapeSqlString(sql.trim());

    if (type == 'execute') {
      buffer.writeln("${indent}await tx.execute(r'''$escapedSql''');");
    } else if (type == 'batch') {
      final params = ddlObject['params'];
      if (params is List && params.isNotEmpty) {
        final paramsLiteral = jsonEncode(params);
        buffer.writeln(
          "${indent}await tx.executeBatch(r'''$escapedSql''', $paramsLiteral);",
        );
      } else {
        print(
          'Warning: Missing, invalid, or empty "params" for batch operation in $context for version $version: $ddlObject. Falling back to tx.execute.',
        );
        buffer.writeln("${indent}await tx.execute(r'''$escapedSql''');");
      }
    } else {
      print(
        'Warning: Unknown DDL type "$type" in $context for version $version: $ddlObject. Defaulting to tx.execute.',
      );
      buffer.writeln("${indent}await tx.execute(r'''$escapedSql''');");
    }
  }
}

String escapeSqlString(String sql) {
  return sql.replaceAll("'''", "'''\"'\"'\"'''");
}

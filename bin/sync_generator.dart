import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;

void main(List<String> args) async {
  if (args.length != 3) {
    print('Usage: dart sync_generator.dart <server_url> <app_id> <auth_token>');
    exit(1);
  }

  String serverUrl = args[0];
  final targetAppId = args[1];
  final authToken = args[2];
  final outputFilePath = 'pregenerated.dart';

  if (serverUrl.endsWith('/')) {
    serverUrl = serverUrl.substring(0, serverUrl.length - 1);
  }

  final modelsUrl = Uri.parse('${serverUrl}/models');
  final constantsServerUrl = args[0];

  try {
    print('Fetching data from: $modelsUrl');
    final response = await http.get(
      modelsUrl,
      headers: {
        'Authorization': 'Bearer $authToken',
        'Content-Type': 'application/json',
        'Accept': 'application/json',
      },
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

    final List<dynamic> unsyncableTables =
        allTables
            .where(
              (t) =>
                  t is Map<String, dynamic> ? t['is_syncable'] == false : false,
            )
            .toList();

    final buffer = StringBuffer();

    buffer.writeln("import 'package:sqlite_async/sqlite_async.dart';");
    buffer.writeln("import 'dart:typed_data';");
    buffer.writeln("import 'dart:convert';");
    buffer.writeln("import 'package:sync_helper_flutter/sync_abstract.dart';");
    buffer.writeln();

    buffer.writeln('class SyncConstants extends AbstractSyncConstants {');
    buffer.writeln("  @override");
    buffer.writeln("  final String appId = '$targetAppId';");
    buffer.writeln("  @override");
    buffer.writeln("  final String serverUrl = '$constantsServerUrl';");
    buffer.writeln("  @override");
    buffer.writeln("  final String authToken = '$authToken';");
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

    final Set<String> generatedClasses = {};

    for (final tableData in allTables) {
      if (tableData is! Map<String, dynamic>) continue;
      final tableName = tableData['name'] as String?;
      final columns =
          tableData['columns'] is List
              ? List<dynamic>.from(tableData['columns'])
              : [];

      if (tableName == null || tableName.isEmpty || columns.isEmpty) continue;

      final className = capitalize(tableName);
      if (generatedClasses.contains(className)) continue;
      generatedClasses.add(className);

      buffer.writeln('class $className {');

      final constructorParams = <String>[];
      for (final columnData in columns) {
        if (columnData is! Map<String, dynamic>) continue;
        final columnName = columnData['name'] as String?;
        final columnType = columnData['type'] as String?;

        if (columnName == null ||
            columnName.isEmpty ||
            columnType == null ||
            columnType.isEmpty)
          continue;

        final dartType = mapSqlTypeToDart(columnType);
        final fieldName = columnName;
        buffer.writeln('  final $dartType? $fieldName;');
        constructorParams.add('this.$fieldName');
      }

      buffer.writeln();
      buffer.writeln('  $className({');
      for (final param in constructorParams) {
        buffer.writeln('    $param,');
      }
      buffer.writeln('  });');
      buffer.writeln();

      buffer.writeln(
        '  factory $className.fromMap(Map<String, dynamic> map) {',
      );
      buffer.writeln('    return $className(');
      for (final columnData in columns) {
        if (columnData is! Map<String, dynamic>) continue;
        final columnName = columnData['name'] as String?;
        final columnType = columnData['type'] as String?;

        if (columnName == null ||
            columnName.isEmpty ||
            columnType == null ||
            columnType.isEmpty)
          continue;

        final dartType = mapSqlTypeToDart(columnType);
        final fieldName = columnName;
        buffer.write("      $fieldName: map['$fieldName']");
        if (dartType == 'DateTime') {
          buffer.write(
            " != null ? DateTime.tryParse(map['$fieldName'].toString()) : null",
          );
        } else if (dartType == 'bool') {
          buffer.write(" == 1 || map['$fieldName'] == true");
        } else if (dartType == 'Uint8List') {
          buffer.write(
            " is List<int> ? Uint8List.fromList(map['$fieldName']) : (map['$fieldName'] is String ? base64Decode(map['$fieldName']) : null)",
          );
        } else if (dartType != 'String' && dartType != 'Object') {
          buffer.write(
            " != null ? ($dartType.tryParse(map['$fieldName'].toString()) ?? (map['$fieldName'] is num ? (map['$fieldName'] as num).to${dartType == 'int' ? 'Int' : 'Double'}() : null)) : null",
          );
        } else if (dartType == 'String') {
          buffer.write("?.toString()");
        }
        buffer.writeln(',');
      }
      buffer.writeln('    );');
      buffer.writeln('  }');
      buffer.writeln();

      buffer.writeln('  Map<String, dynamic> toMap() {');
      buffer.writeln('    return {');
      for (final columnData in columns) {
        if (columnData is! Map<String, dynamic>) continue;
        final columnName = columnData['name'] as String?;
        final columnType = columnData['type'] as String?;

        if (columnName == null ||
            columnName.isEmpty ||
            columnType == null ||
            columnType.isEmpty)
          continue;

        final fieldName = columnName;
        final dartType = mapSqlTypeToDart(columnType);

        buffer.write("      '$fieldName': $fieldName");
        if (dartType == 'DateTime') {
          buffer.write("?.toIso8601String()");
        } else if (dartType == 'bool') {
          buffer.write(" == true ? 1 : 0");
        } else if (dartType == 'Uint8List') {
          buffer.write(" != null ? base64Encode($fieldName!) : null");
        }
        buffer.writeln(',');
      }
      buffer.writeln('    };');
      buffer.writeln('  }');

      buffer.writeln('}');
      buffer.writeln();
    }

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

String capitalize(String s) {
  if (s.isEmpty) return s;
  return s
      .split('_')
      .map((part) {
        if (part.isEmpty) return '';
        return part[0].toUpperCase() + part.substring(1).toLowerCase();
      })
      .join('');
}

String mapSqlTypeToDart(String sqlType) {
  final lowerSqlType = sqlType.toLowerCase().split('(')[0].trim();
  switch (lowerSqlType) {
    case 'text':
    case 'varchar':
    case 'char':
    case 'clob':
    case 'string':
      return 'String';
    case 'integer':
    case 'int':
    case 'bigint':
    case 'smallint':
    case 'tinyint':
    case 'mediumint':
      return 'int';
    case 'real':
    case 'double':
    case 'float':
    case 'numeric':
    case 'decimal':
      return 'double';
    case 'blob':
      return 'Uint8List';
    case 'boolean':
      return 'bool';
    case 'date':
    case 'datetime':
    case 'timestamp':
      return 'DateTime';
    default:
      print("Warning: Unknown SQL type '$sqlType'. Mapping to 'Object'.");
      return 'Object';
  }
}

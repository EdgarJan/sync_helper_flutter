import 'package:sqlite_async/sqlite_async.dart';

abstract class AbstractSyncConstants {
  String get appId;
  String get serverUrl;
  String get auth0Domain;
  String get auth0ClientId;
}

abstract class AbstractPregeneratedMigrations {
  SqliteMigrations get migrations;
}

abstract class AbstractMetaEntity {
  Map<String, String> get syncableColumnsString;
  Map<String, List> get syncableColumnsList;
}
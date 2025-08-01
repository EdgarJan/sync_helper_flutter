import 'package:sqlite_async/sqlite_async.dart';

abstract class AbstractSyncConstants {
  String get appId;
  String get serverUrl;
  
  // Firebase Auth integration (required)
  Future<String> getFirebaseToken();
}

abstract class AbstractPregeneratedMigrations {
  SqliteMigrations get migrations;
}

abstract class AbstractMetaEntity {
  Map<String, String> get syncableColumnsString;
  Map<String, List> get syncableColumnsList;
}
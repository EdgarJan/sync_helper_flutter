# sync_helper_flutter - Offline-First Sync Library for Flutter

## Project Overview

**sync_helper_flutter** is a reusable Flutter package that provides offline-first data synchronization capabilities for Flutter applications. It implements a sophisticated bidirectional sync protocol with SQLite local storage, HTTP REST API communication, and Server-Sent Events for real-time updates.

**Type:** Flutter Package/Library (not an app)
**Version:** 1.7.4
**Repository:** https://github.com/EdgarJan/sync_helper_flutter

**Key Capabilities:**
- Offline-first architecture (all operations work offline)
- Automatic bidirectional sync (local ↔ server)
- Real-time updates via Server-Sent Events (SSE)
- Conflict-free sync with server-authoritative resolution
- Archive-based soft deletes
- User-isolated databases
- Firebase authentication integration
- Code generation tools

---

## Architecture

### Package Structure

```
sync_helper_flutter/
├── lib/
│   ├── backend_wrapper.dart          # Main implementation (688 lines)
│   │   └── BackendNotifier           # Core sync engine
│   │   └── BackendWrapper            # InheritedWidget provider
│   └── sync_abstract.dart            # Public API contracts (14 lines)
│       └── AbstractSyncConstants     # Server URL & app ID
│       └── AbstractPregeneratedMigrations  # Database schema
│       └── AbstractMetaEntity        # Syncable columns metadata
├── bin/
│   ├── sync_generator.dart           # Code generation CLI (331 lines)
│   └── mock_sync_server.dart         # Test server (227 lines)
├── test/                              # Test suite
├── pubspec.yaml                       # Dependencies
├── CHANGELOG.md                       # Version history
└── README.md                          # Package documentation
```

---

## Core Concepts

### 1. Offline-First Design
- All write operations stored locally immediately
- Reads always come from local SQLite
- Network sync happens asynchronously in background
- App functions fully without internet connection

### 2. Bidirectional Sync
**Upload (Local → Server):**
- Marks changed rows with `is_unsynced = 1`
- Batches 100 rows per HTTP request
- Clears `is_unsynced` flag on success
- Retries on failure

**Download (Server → Local):**
- Fetches rows with `lts > last_received_lts`
- Pages 1000 rows per request
- Upserts into local database
- Updates `last_received_lts` tracking

### 3. LTS (Logical Timestamp Sequence)
- Server assigns monotonically increasing integer to each row
- Client tracks `last_received_lts` per table
- Enables incremental sync (only fetch changes)
- Provides conflict detection mechanism

### 4. Real-Time Updates
- Server-Sent Events (SSE) connection to backend
- Listens for data change notifications
- Auto-triggers sync when changes detected
- Reconnects automatically on disconnect (5s backoff)

### 5. Archive Pattern (Soft Deletes)
```
Delete Flow:
1. Create archive entry with full row data
2. Delete from original table locally
3. Archive syncs to server (is_unsynced=1)
4. Server confirms and performs actual delete
5. Archive entry removed after confirmation
```

---

## Public API

### Abstract Contracts (Implemented by Consuming Apps)

```dart
// lib/sync_abstract.dart

abstract class AbstractSyncConstants {
  String get appId;        // e.g., "lt.helper.hard_app"
  String get serverUrl;    // e.g., "http://52.214.192.18:8080"
}

abstract class AbstractPregeneratedMigrations {
  SqliteMigrations get migrations;  // Database schema & migrations
}

abstract class AbstractMetaEntity {
  Map<String, String> get syncableColumnsString;
  // e.g., {"schedules": "id,lts,is_unsynced,name,comment"}

  Map<String, List> get syncableColumnsList;
  // e.g., {"schedules": ["id", "lts", "is_unsynced", "name", "comment"]}
}
```

---

### BackendNotifier (Main API)

```dart
class BackendNotifier extends ChangeNotifier {

  // INITIALIZATION
  Future<void> initDb({required String userId});
  Future<void> deinitDb();

  // DATA ACCESS
  Future<ResultSet> getAll({
    required String sql,
    String where = '',
    String order = '',
  });

  Stream<List> watch(
    String sql,
    {List<String>? triggerOnTables}
  );

  // DATA MODIFICATION
  Future<void> write({
    required String tableName,
    required Map data,
  });

  Future<void> writeBatch({
    required String tableName,
    required List<Map<String, dynamic>> dataList,
  });

  Future<void> writeTransaction(
    Future<void> Function(SafeWriteTransaction tx) callback,
  );

  Future<void> delete({
    required String tableName,
    required String id,
  });

  // SYNC CONTROL
  Future<void> fullSync();

  // STATUS GETTERS
  SqliteDatabase? get db;
  bool get sseConnected;
  bool get isSyncing;
  bool get isInitialized;
  bool get initialSyncCompleted;
  String? get syncError;
  String? get userId;
}
```

---

### BackendWrapper (Provider)

```dart
class BackendWrapper extends InheritedNotifier<BackendNotifier> {
  static BackendNotifier? of(BuildContext context) {
    return context
      .dependOnInheritedWidgetOfExactType<BackendWrapper>()
      ?.notifier;
  }
}
```

**Usage Pattern:**
```dart
// Wrap app
BackendWrapper(
  notifier: backendNotifier,
  child: MaterialApp(...),
)

// Access in widgets
final backend = BackendWrapper.of(context);
```

---

## Integration Guide

### Step 1: Add Dependency

```yaml
# pubspec.yaml
dependencies:
  sync_helper_flutter:
    git: https://github.com/EdgarJan/sync_helper_flutter.git
    ref: ba4af6e  # Specific commit for stability

  # Required peer dependencies
  firebase_core: ^4.1.1
  firebase_auth: ^6.1.0
```

### Step 2: Generate Boilerplate

```bash
# Run code generator
dart run sync_helper_flutter:sync_generator http://YOUR_SERVER:8080 your.app.id

# Interactive prompts:
# Email: (Firebase credentials)
# Password: (Firebase credentials)

# Output: lib/pregenerated.dart
```

**Generated Code Example:**
```dart
// lib/pregenerated.dart
import 'package:sync_helper_flutter/sync_abstract.dart';

class SyncConstants extends AbstractSyncConstants {
  @override
  final String appId = 'lt.helper.hard_app';

  @override
  final String serverUrl = 'http://52.214.192.18:8080';
}

class PregeneratedMigrations extends AbstractPregeneratedMigrations {
  @override
  final SqliteMigrations migrations = SqliteMigrations()
    ..add(SqliteMigration(1, (tx) async {
      await tx.execute('''
        CREATE TABLE schedules (
          id TEXT PRIMARY KEY,
          lts INTEGER,
          is_unsynced INTEGER,
          name TEXT,
          comment TEXT
        )
      ''');
    }))
    ..createDatabase = SqliteMigration(0, (tx) async {
      // Initial schema setup
    });
}

class MetaEntity extends AbstractMetaEntity {
  @override
  final Map<String, String> syncableColumnsString = {
    'schedules': 'id,lts,is_unsynced,name,comment',
  };

  @override
  final Map<String, List> syncableColumnsList = {
    'schedules': ['id', 'lts', 'is_unsynced', 'name', 'comment'],
  };
}
```

### Step 3: Initialize Firebase

```dart
// main.dart
void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Initialize Firebase FIRST
  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );

  runApp(MyApp());
}
```

### Step 4: Create BackendNotifier

```dart
class _MyAppState extends State<MyApp> {
  late BackendNotifier backendNotifier;

  @override
  void initState() {
    super.initState();
    backendNotifier = BackendNotifier(
      abstractPregeneratedMigrations: PregeneratedMigrations(),
      abstractSyncConstants: SyncConstants(),
      abstractMetaEntity: MetaEntity(),
    );
  }

  @override
  void dispose() {
    backendNotifier.deinitDb();
    super.dispose();
  }
}
```

### Step 5: Initialize on Login

```dart
Future<void> _onUserLogin(User user) async {
  // Initialize database for this user
  await backendNotifier.initDb(userId: user.uid);

  // Database ready:
  // - Local SQLite created/opened
  // - Migrations applied
  // - SSE connection established
  // - Initial sync triggered
}
```

### Step 6: Wrap App with Provider

```dart
@override
Widget build(BuildContext context) {
  return BackendWrapper(
    notifier: backendNotifier,
    child: MaterialApp(
      home: MyHomePage(),
    ),
  );
}
```

### Step 7: Use in Widgets

**Reading Data:**
```dart
class MyWidget extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final backend = BackendWrapper.of(context);

    return StreamBuilder<List>(
      stream: backend!.watch(
        'SELECT * FROM schedules ORDER BY priority DESC',
        triggerOnTables: ['schedules'],
      ),
      builder: (context, snapshot) {
        if (!snapshot.hasData) return CircularProgressIndicator();

        final schedules = snapshot.data!;
        return ListView.builder(
          itemCount: schedules.length,
          itemBuilder: (context, index) {
            final schedule = schedules[index];
            return ListTile(
              title: Text(schedule['name']),
              subtitle: Text(schedule['comment']),
            );
          },
        );
      },
    );
  }
}
```

**Writing Data:**
```dart
final backend = BackendWrapper.of(context);

await backend!.write(
  tableName: 'schedules',
  data: {
    'id': Uuid().v4(),  // Generate UUID if new
    'name': 'New Schedule',
    'comment': 'Description here',
    'priority': 1,
    'cts': DateTime.now().toIso8601String(),
  },
);

// Automatically:
// - Inserts locally with is_unsynced=1
// - Triggers sync to server
// - Notifies StreamBuilder watchers
```

**Batch Writing Data (Multiple Rows, Single Table):**
```dart
final backend = BackendWrapper.of(context);

// Efficient batch write for multiple rows in same table
await backend!.writeBatch(
  tableName: 'tasks',
  dataList: [
    {'id': 'task1', 'name': 'Task 1', 'priority': 0},
    {'id': 'task2', 'name': 'Task 2', 'priority': 1},
    {'id': 'task3', 'name': 'Task 3', 'priority': 2},
  ],
);

// Benefits:
// - Single atomic transaction (all-or-nothing)
// - Single sync cycle (not N syncs)
// - Much faster for bulk operations
// - Automatically protects 'lts' and 'is_unsynced' fields
```

**Transaction Writing (Multiple Tables or Complex Logic):**
```dart
final backend = BackendWrapper.of(context);

await backend!.writeTransaction((tx) async {
  // Write to multiple tables atomically
  await tx.write('projects', {
    'id': projectId,
    'name': 'New Project',
  });

  await tx.write('tasks', {
    'id': 'task1',
    'project_id': projectId,
    'name': 'First task',
  });

  await tx.write('tasks', {
    'id': 'task2',
    'project_id': projectId,
    'name': 'Second task',
  });

  // Can also execute custom SQL within transaction
  await tx.execute(
    'UPDATE projects SET task_count = ? WHERE id = ?',
    [2, projectId],
  );
});

// Benefits:
// - Multi-table atomic writes
// - Complex operations with queries + writes
// - Single sync cycle
// - Automatically protects sync-critical fields
// - SafeWriteTransaction wrapper prevents 'lts' modification
```

**When to Use Each Write Method:**

1. **write()** - Single row modification
   - Simple CRUD operations
   - User editing one record at a time
   - Default choice for most operations

2. **writeBatch()** - Multiple rows, same table
   - Bulk imports
   - Reordering lists (updating priorities)
   - Mass updates to same table
   - Performance-critical batch operations

3. **writeTransaction()** - Multi-table operations or complex logic
   - Creating related records across tables
   - Operations requiring reads + writes
   - Complex business logic requiring atomicity
   - Custom SQL alongside ORM writes

**Deleting Data:**
```dart
await backend!.delete(
  tableName: 'schedules',
  id: scheduleId,
);

// Automatically:
// - Creates archive entry
// - Deletes locally
// - Syncs archive to server
// - Server deletes actual row
```

---

## Sync Field Protection

### Critical Fields Managed by Sync Library

The sync library automatically manages two critical fields:

1. **`lts` (Logical Timestamp Sequence)**: Server-managed version number
   - MUST NEVER be set by client code
   - Always assigned by server
   - Used for conflict detection and incremental sync
   - Attempting to set it could break sync protocol

2. **`is_unsynced`**: Client-managed dirty flag
   - Automatically set to `1` on writes
   - Cleared to `0` after successful sync
   - Marks rows needing upload to server

### SafeWriteTransaction API

The `SafeWriteTransaction` wrapper protects these fields in transaction contexts:

```dart
class SafeWriteTransaction {
  /// Write a row with automatic sync field protection
  Future<void> write(String tableName, Map<String, dynamic> data) async {
    // Automatically strips 'lts' from data
    // Automatically sets 'is_unsynced = 1'
    // Generates UUID if 'id' missing
  }

  /// Execute raw SQL (for custom operations)
  Future<void> execute(String sql, [List<Object?>? parameters]) async;

  /// Query operations within transaction
  Future<Row?> getOptional(String sql, [List<Object?>? parameters]) async;
  Future<ResultSet> getAll(String sql, [List<Object?>? parameters]) async;
}
```

**Key Protection Mechanisms:**

1. **Automatic `lts` Removal**: Any `lts` field in data maps is stripped before write
2. **Automatic `is_unsynced = 1`**: All writes marked as needing sync
3. **UUID Generation**: Missing `id` fields automatically populated
4. **UPSERT Logic**: `INSERT...ON CONFLICT DO UPDATE` for idempotent writes

**Why This Matters:**

Without protection, application code could accidentally:
- Set `lts` field, breaking conflict detection
- Forget to set `is_unsynced`, losing changes
- Create inconsistent sync state
- Corrupt the sync protocol

The wrapper ensures correctness even in complex transaction logic.

---

## Synchronization Deep Dive

### Database Location

**Path Pattern:**
```
iOS/macOS: ~/Documents/{appId}/{userId}/helper_sync.db
Android:   /data/data/{package}/app_documents/{appId}/{userId}/helper_sync.db
Web:       IndexedDB (via sqlite_async)
```

**User Isolation:**
- Each user gets separate database file
- No data leakage between users
- Easy to clear user data (delete directory)

---

### Sync Algorithm

**Full Sync Process:**
```
1. PUSH PHASE (_sendUnsynced)
   For each table:
     a. Query: SELECT * WHERE is_unsynced = 1
     b. Batch 100 rows at a time
     c. POST /data to server
     d. On success: UPDATE SET is_unsynced = 0
     e. Repeat until no unsynced rows

2. PULL PHASE (fullSync)
   For each table:
     a. Get last_received_lts from syncing_table
     b. GET /data?name=table&lts={last_lts}&pageSize=1000
     c. Process rows:
        - If archive: DELETE from referenced table
        - Else: INSERT...ON CONFLICT DO UPDATE
     d. Update last_received_lts
     e. Repeat while page size = 1000

3. NOTIFY WATCHERS
   - Call notifyListeners()
   - StreamBuilders rebuild UI
```

**SSE Real-Time Updates:**
```dart
void _startSyncer() async {
  final token = await FirebaseAuth.instance.currentUser?.getIdToken();

  final request = await httpClient.get(
    Uri.parse('${serverUrl}/events?app_id=${appId}'),
    headers: {'Authorization': 'Bearer $token'},
  );

  request.stream
    .transform(utf8.decoder)
    .listen((data) {
      if (data.startsWith('data:')) {
        final json = jsonDecode(data.substring(5));
        print('Change detected: ${json['table']}');
        fullSync(); // Re-sync affected table
      }
    });
}
```

---

### Conflict Resolution

**Strategy:** Server Wins (Server Authoritative)

**How it Works:**
1. Client reads row: `{id: '123', lts: 5, name: 'Old'}`
2. Client modifies locally: `{id: '123', lts: 5, name: 'Modified'}`
3. Client uploads with original lts: `POST /data {..., lts: 5}`
4. Server checks:
   - If server's lts still 5: Accept change, increment lts to 6
   - If server's lts now 7: Reject (someone else modified first)
5. On rejection: Client will receive server version on next pull

**No Manual Merging Required:**
- Server version always wins
- Client changes lost if conflict detected
- Simplifies logic at cost of occasional data loss
- Suitable for non-critical data (schedules, notes, etc.)

---

### Performance Characteristics

**Batch Sizes:**
- Upload: 100 rows per request
- Download: 1000 rows per request

**Network Efficiency:**
- Only changed rows uploaded (is_unsynced filter)
- Only new rows downloaded (lts > last_received filter)
- Pagination prevents memory exhaustion

**Database Performance:**
- Indexes on id (primary key), lts, is_unsynced
- Transactions for multi-row operations
- Async operations prevent UI blocking

---

## Code Generation Tool

### sync_generator CLI

**Purpose:** Generate boilerplate code from backend schema

**Usage:**
```bash
dart run sync_helper_flutter:sync_generator <server_url> <app_id>

# Example:
dart run sync_helper_flutter:sync_generator http://52.214.192.18:8080 lt.helper.hard_app
```

**What It Does:**
1. Prompts for Firebase email/password
2. Authenticates with backend `POST /models`
3. Fetches table schemas
4. Generates:
   - SyncConstants class
   - PregeneratedMigrations class
   - MetaEntity class
   - CREATE TABLE statements
   - Migration history

**Output:** `lib/pregenerated.dart`

**When to Run:**
- Initial project setup
- After backend schema changes
- After adding new tables

---

## Testing

### Mock Server

**Purpose:** Test sync logic without real backend

**Usage:**
```bash
dart run sync_helper_flutter:mock_sync_server
```

**Capabilities:**
- In-memory data storage
- Mock /data, /events endpoints
- Simulates SSE broadcasts
- Useful for unit testing

### Test Suite

```bash
cd ~/developer/sync_helper_flutter
flutter test
```

**Test Coverage:**
- Database initialization
- CRUD operations
- Sync logic
- Conflict handling
- SSE connection management

---

## Key Dependencies

```yaml
dependencies:
  flutter: sdk

  # Database
  sqlite_async: 0.12.1            # Async SQLite wrapper
  path_provider: 2.1.5            # Platform-specific paths

  # Networking
  http: 1.5.0                     # HTTP client

  # Authentication (peer dependency)
  firebase_auth: 6.1.0            # Firebase auth

  # Utilities
  uuid: 4.5.1                     # UUID generation
  package_info_plus: 9.0.0        # App metadata
  collection: 1.19.1              # Collection utilities

  # Monitoring
  sentry_flutter: 9.6.0           # Error tracking
  device_info_plus: 12.1.0        # Device metadata
```

---

## Key Files Reference

| File | Purpose | Lines |
|------|---------|-------|
| `lib/backend_wrapper.dart` | Core sync engine & state management | ~990 |
| `lib/sync_abstract.dart` | Public API contracts | 14 |
| `bin/sync_generator.dart` | Code generation CLI tool | 331 |
| `bin/mock_sync_server.dart` | Test server implementation | 227 |
| `pubspec.yaml` | Package metadata & dependencies | ~40 |

---

## State Management Details

### BackendNotifier State Variables

```dart
class BackendNotifier extends ChangeNotifier {
  // Database
  SqliteDatabase? _db;
  String? userId;

  // Sync Status
  bool fullSyncStarted = false;        // Currently syncing?
  bool repeat = false;                  // Re-sync after current?
  bool _sseConnected = false;          // SSE connected?
  bool _initialSyncCompleted = false;  // First sync after init completed?

  // Connections
  StreamSubscription? _eventSubscription;  // SSE listener
}
```

**Important:** `initialSyncCompleted` becomes `true` only after the first `fullSync()` completes following SSE connection. Use this to wait before writing data that may conflict with server state (e.g., app version records).

### When notifyListeners() Called

1. Database initialized: `initDb()` completes
2. SSE connected/disconnected: Connection state changes
3. Sync started: `fullSyncStarted = true`
4. Sync completed: `fullSyncStarted = false`
5. Initial sync completed: `_initialSyncCompleted = true` (first sync after connect)
6. Data changed: After write/delete operations

### Listening Pattern

```dart
class MyWidget extends StatefulWidget {
  @override
  _MyWidgetState createState() => _MyWidgetState();
}

class _MyWidgetState extends State<MyWidget> {
  BackendNotifier? backend;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    backend = BackendWrapper.of(context);
    backend?.addListener(_onSyncStatusChanged);
  }

  @override
  void dispose() {
    backend?.removeListener(_onSyncStatusChanged);
    super.dispose();
  }

  void _onSyncStatusChanged() {
    setState(() {
      // Rebuild UI based on sync status
    });
  }

  @override
  Widget build(BuildContext context) {
    return Text(backend?.isSyncing == true
      ? 'Syncing...'
      : 'Synced');
  }
}
```

---

## Integration Points

### Server Backend (sync_helper_service)
**Location:** `~/developer/sync_helper_service/`

**Protocol:**
- HTTP REST API for CRUD operations
- Server-Sent Events for real-time notifications
- Firebase token authentication

**Endpoints Used:**
- `GET /data` - Fetch rows
- `POST /data` - Upload changes
- `GET /events` - SSE stream
- `GET /latest-lts` - Table version
- `POST /models` - Schema fetch (generator only)

---

## Common Tasks

### Adding a New Table

**Backend:**
1. Add table definition to backend schema
2. Deploy schema changes to server

**Client (this package):**
1. Regenerate code:
   ```bash
   dart run sync_helper_flutter:sync_generator http://SERVER:8080 APP_ID
   ```
2. New table automatically available in generated code
3. Use `backend.write(tableName: 'new_table', ...)` or other write methods

---

### Debugging Sync Issues

**Check Sync Status:**
```dart
print('DB: ${backend.db != null}');
print('SSE: ${backend.sseConnected}');
print('Syncing: ${backend.isSyncing}');
```

**Query Unsynced Rows:**
```dart
final results = await backend.getAll(
  sql: 'SELECT * FROM schedules WHERE is_unsynced = 1',
);
print('Pending upload: ${results.length} rows');
```

**Check Last Sync Position:**
```dart
final results = await backend.getAll(
  sql: 'SELECT * FROM syncing_table',
);
for (final row in results) {
  print('${row['entity_name']}: lts=${row['last_received_lts']}');
}
```

**Monitor SSE Events:**
- Add debug logs in `_startSyncer()` method
- Check if events received
- Verify `fullSync()` triggered

---

### Forcing a Full Re-Sync

```dart
// Clear sync tracking
await backend.db.execute('DELETE FROM syncing_table');

// Trigger sync
await backend.fullSync();

// All data will be re-downloaded from server
```

---

### Clearing User Data

```dart
await backend.deinitDb();

// Delete database file manually
final dbPath = '${appDocDir}/${appId}/${userId}/helper_sync.db';
await File(dbPath).delete();

// Re-initialize
await backend.initDb(userId: userId);
```

---

## Troubleshooting

### SSE Connection Keeps Dropping
- Check server health: `curl http://SERVER:8080/health`
- Verify Firebase token not expired
- Check network stability
- Review server SSE implementation
- Consider WebSocket alternative

### Sync Loop (Infinite Syncing)
- Check for rows with permanently `is_unsynced = 1`
- Verify server accepts uploads (check 403/500 errors)
- Review `post_dismisseds` table on server for rejections
- Check for validation errors in server logs

### Database Locked Errors
- Ensure only one BackendNotifier instance
- Check for concurrent writes
- Use transactions for multi-step operations
- Review sqlite_async configuration

### Data Not Syncing to Other Devices
- Verify SSE working on all devices
- Check all devices using same `app_id`
- Ensure all devices authenticated with same server
- Check backend broadcast filtering

---

## Advanced Topics

### Custom Migrations

**Manual Migration Example:**
```dart
class PregeneratedMigrations extends AbstractPregeneratedMigrations {
  @override
  final SqliteMigrations migrations = SqliteMigrations()
    ..add(SqliteMigration(1, (tx) async {
      await tx.execute('CREATE TABLE schedules (...)');
    }))
    ..add(SqliteMigration(2, (tx) async {
      // Add column to existing table
      await tx.execute('ALTER TABLE schedules ADD COLUMN tags TEXT');
    }))
    ..add(SqliteMigration(3, (tx) async {
      // Create index
      await tx.execute('CREATE INDEX idx_schedules_priority ON schedules(priority)');
    }));
}
```

**Migration Best Practices:**
- Always increment version number
- Never modify existing migrations
- Test migrations on sample data
- Keep migrations idempotent

---

### Custom Sync Rules

**Example: Only Sync Priority Schedules**
```dart
// Override _sendUnsynced to filter uploads
final results = await db.getAll(
  'SELECT * FROM schedules WHERE is_unsynced = 1 AND priority > 5',
);
```

**Note:** Requires modifying backend_wrapper.dart (fork package)

---

### Optimizing Large Datasets

**Strategies:**
1. Increase page sizes (trade-off: memory vs. speed)
2. Add database indexes
3. Implement lazy loading in UI
4. Use virtual scrolling for large lists
5. Consider pagination in app (don't load all data)

---

## Security Considerations

- **Firebase Tokens:** Automatically refreshed, expire after 1 hour
- **Local Database:** Stored in app's secure documents directory
- **User Isolation:** Database path includes userId
- **HTTPS:** Ensure backend uses HTTPS in production
- **Token Storage:** Firebase SDK handles secure storage
- **SQL Injection:** Protected via parameterized queries

---

## Performance Tips

1. **Use watch() for reactive UI** - More efficient than polling
2. **Batch operations** - Use transactions for multiple writes
3. **Limit query results** - Add WHERE/LIMIT clauses
4. **Index frequently queried columns** - Speeds up searches
5. **Avoid large blobs** - Store files separately, sync URLs only
6. **Monitor memory** - Large sync operations can spike memory
7. **Test on low-end devices** - Ensure smooth performance

---

## Future Enhancements

- WebSocket support (alternative to SSE)
- Custom conflict resolution strategies
- Partial sync (selected tables only)
- Compression for large payloads
- Delta sync (field-level changes)
- Offline queue management UI
- Sync progress callbacks
- Background sync (WorkManager)

---

## Related Documentation

- Server Backend: `~/developer/sync_helper_service/CLAUDE.md`
- Global Claude instructions: `~/.claude/CLAUDE.md`

---

**Last Updated:** 2025-10-27

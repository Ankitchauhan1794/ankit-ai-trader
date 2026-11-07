import 'sqflite/sqflite.dart';
import 'path/path.dart';

class PersistenceDb {
  static Database? _db;

  static Future<Database> get database async {
    if (_db != null) return _db!;
    _db = await _initDb();
    return _db!;
  }

  static Future<Database> _initDb() async {
    String path = join(await getDatabasesPath(), 'ankit_trader.db');
    return await openDatabase(
      path,
      version: 2,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE engine_state (
            id INTEGER PRIMARY KEY CHECK (id = 1),
            state TEXT NOT NULL,
            pause_reason TEXT,
            order_seq INTEGER DEFAULT 0,
            updated_at TEXT NOT NULL
          )
        ''');
        await db.execute('''
          CREATE TABLE event_journal (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            timestamp TEXT NOT NULL,
            type TEXT NOT NULL,
            reason TEXT NOT NULL
          )
        ''');
        await db.execute('''
          CREATE TABLE notified_alerts (
            alert_id TEXT PRIMARY KEY
          )
        ''');
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          await db.execute('CREATE TABLE IF NOT EXISTS event_journal (id INTEGER PRIMARY KEY AUTOINCREMENT, timestamp TEXT NOT NULL, type TEXT NOT NULL, reason TEXT NOT NULL)');
        }
      },
    );
  }

  static Future<void> logEvent(String type, String reason) async {
    final db = await database;
    await db.insert('event_journal', {
      'timestamp': DateTime.now().toIso8601String(),
      'type': type,
      'reason': reason,
    });
    // Prune event journal to last 500 rows
    await db.rawExecute('DELETE FROM event_journal WHERE id NOT IN (SELECT id FROM event_journal ORDER BY id DESC LIMIT 500)');
  }

  static Future<List<Map<String, dynamic>>> getLastEvents(int limit) async {
    final db = await database;
    return await db.query('event_journal', orderBy: 'id DESC', limit: limit);
  }

  static Future<void> saveEngineState(String state, String? pauseReason, int orderSeq) async {
    final db = await database;
    await db.insert(
      'engine_state',
      {
        'id': 1,
        'state': state,
        'pause_reason': pauseReason ?? '',
        'order_seq': orderSeq,
        'updated_at': DateTime.now().toIso8601String(),
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  static Future<Map<String, dynamic>?> loadEngineState() async {
    final db = await database;
    final res = await db.query('engine_state', where: 'id = 1');
    return res.isNotEmpty ? res.first : null;
  }
}

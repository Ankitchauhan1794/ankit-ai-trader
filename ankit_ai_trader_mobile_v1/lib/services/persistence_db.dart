import 'dart:convert';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';
import '../models/dual_portfolio_models.dart';
import '../models/trading_models.dart';

class PersistedEngineSnapshot {
  final BotEngineState botState;
  final UserSessionIntention userIntention;
  final double availableCashUsdt;
  final double accountEquityUsdt;
  final double startOfDayEquityUsdt;
  final bool maxDrawdownLocked;
  final String? lockedDailyLossUtcDate;
  final int? lastStopLossClosedAtMs;
  final int? lastHeartbeatMs;
  final int? lastMarketDataUpdateMs;
  final int? lastCandleUpdateMs;
  final int? runningSinceMs;
  final int totalActiveMs;
  final int serviceRestartCount;
  final int orderSeq;
  final bool autoResumeEnabled;
  final String statusBannerMessage;
  final String? lastError;
  final bool tradeAlertsEnabled;
  final Map<String, double> liveTickerPrices;
  final Map<String, LiveMarketTicker> liveTickers;
  final Map<String, double> closedCandlePrices;
  final Map<String, String> whyNoTradeForSymbol;
  final List<PaperPosition> openPositions;
  final List<SimulatedOrder> orders;
  final List<ClosedPaperTrade> closedTrades;
  final List<EquityPoint> equityCurve;
  final List<DiagnosticEvent> recentEvents;
  final Set<String> processedEntrySignalKeys;
  final int recoveryAttemptCount;
  final int? recoveryStartedAtMs;
  final int? nextRecoveryAllowedAtMs;
  final List<String> recoveryLogs;
  final ScanCycleDiagnosticsSnapshot scanDiagnostics;
  final int? lastStartupAttemptMs;
  final String? lastStartupError;
  final String? lastShutdownReason;
  final String? lastBackgroundCycleError;

  const PersistedEngineSnapshot({
    required this.botState,
    required this.userIntention,
    required this.availableCashUsdt,
    required this.accountEquityUsdt,
    this.startOfDayEquityUsdt = 100.0,
    required this.maxDrawdownLocked,
    this.lockedDailyLossUtcDate,
    this.lastStopLossClosedAtMs,
    this.lastHeartbeatMs,
    this.lastMarketDataUpdateMs,
    this.lastCandleUpdateMs,
    this.runningSinceMs,
    this.totalActiveMs = 0,
    this.serviceRestartCount = 0,
    this.orderSeq = 0,
    this.autoResumeEnabled = false,
    required this.statusBannerMessage,
    this.lastError,
    this.tradeAlertsEnabled = true,
    this.liveTickerPrices = const {},
    this.liveTickers = const {},
    this.closedCandlePrices = const {},
    this.whyNoTradeForSymbol = const {},
    this.openPositions = const [],
    this.orders = const [],
    this.closedTrades = const [],
    this.equityCurve = const [],
    this.recentEvents = const [],
    this.processedEntrySignalKeys = const {},
    this.recoveryAttemptCount = 0,
    this.recoveryStartedAtMs,
    this.nextRecoveryAllowedAtMs,
    this.recoveryLogs = const [],
    this.scanDiagnostics = const ScanCycleDiagnosticsSnapshot(),
    this.lastStartupAttemptMs,
    this.lastStartupError,
    this.lastShutdownReason,
    this.lastBackgroundCycleError,
  });
}

class PersistenceDatabase {
  static const String dbFileName = 'ankit_ai_trader_phase1.db';
  static const int currentSchemaVersion = 7;

  Database? _db;
  final Map<String, String> _inMemoryKv = {};
  final List<PaperPosition> _inMemoryOpenPositions = [];
  final List<SimulatedOrder> _inMemoryOrders = [];
  final List<ClosedPaperTrade> _inMemoryClosedTrades = [];
  final List<EquityPoint> _inMemoryEquityCurve = [];
  final List<DiagnosticEvent> _inMemoryEvents = [];
  final Set<String> _inMemoryProcessedKeys = {};
  final Map<String, Map<String, dynamic>> _inMemoryLocks = {};
  final Map<String, CoinDcxMarketRecord> _inMemoryDiscoveredMarkets = {};
  final Map<PortfolioId, PortfolioAccountSnapshot> _inMemoryPortfolioSnapshots = {};
  final bool useInMemoryFallback;

  PersistenceDatabase({this.useInMemoryFallback = false});

  Future<Database?> get database async {
    if (useInMemoryFallback) return null;
    if (_db != null) return _db;
    try {
      final dbDir = await getDatabasesPath();
      final fullPath = p.join(dbDir, dbFileName);
      _db = await openDatabase(
        fullPath,
        version: currentSchemaVersion,
        onCreate: _onCreate,
        onUpgrade: _onUpgrade,
      );
      return _db;
    } catch (_) {
      return null;
    }
  }

  Future<void> _onCreate(Database db, int version) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS engine_kv_state (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS open_positions (
        id TEXT PRIMARY KEY,
        portfolioId TEXT NOT NULL DEFAULT 'CRYPTO',
        symbol TEXT NOT NULL,
        entryPrice REAL NOT NULL,
        quantity REAL NOT NULL,
        stopLoss REAL NOT NULL,
        takeProfit REAL NOT NULL,
        entryFeeUsdt REAL NOT NULL,
        signalCandleCloseMs INTEGER NOT NULL,
        openedAtMs INTEGER NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS orders (
        id TEXT PRIMARY KEY,
        portfolioId TEXT NOT NULL DEFAULT 'CRYPTO',
        symbol TEXT NOT NULL,
        side TEXT NOT NULL,
        requestedPrice REAL NOT NULL,
        executedPrice REAL NOT NULL,
        quantity REAL NOT NULL,
        notionalUsdt REAL NOT NULL,
        feeUsdt REAL NOT NULL,
        signalCandleCloseMs INTEGER NOT NULL,
        executedAtMs INTEGER NOT NULL,
        reason TEXT NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS closed_trades (
        id TEXT PRIMARY KEY,
        portfolioId TEXT NOT NULL DEFAULT 'CRYPTO',
        symbol TEXT NOT NULL,
        entryPrice REAL NOT NULL,
        exitPrice REAL NOT NULL,
        quantity REAL NOT NULL,
        stopLoss REAL NOT NULL,
        takeProfit REAL NOT NULL,
        totalFeesUsdt REAL NOT NULL,
        realizedPnlUsdt REAL NOT NULL,
        openedAtMs INTEGER NOT NULL,
        closedAtMs INTEGER NOT NULL,
        exitReason TEXT NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS processed_signal_keys (
        signalKey TEXT PRIMARY KEY,
        processedAtMs INTEGER NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS equity_snapshots (
        timestampMs INTEGER PRIMARY KEY,
        portfolioId TEXT NOT NULL DEFAULT 'CRYPTO',
        equityUsdt REAL NOT NULL,
        availableCashUsdt REAL NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS execution_locks (
        lockName TEXT PRIMARY KEY,
        ownerId TEXT NOT NULL,
        acquiredAtMs INTEGER NOT NULL,
        expiresAtMs INTEGER NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS diagnostic_events (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        timestampMs INTEGER NOT NULL,
        eventType TEXT NOT NULL,
        reason TEXT NOT NULL
      )
    ''');
    await _createDiscoveredMarketsTable(db);
    await _createPortfolioAccountsTable(db);
    await _migrateAndSeedPortfoliosOnDb(db);
  }

  Future<void> _createDiscoveredMarketsTable(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS discovered_markets (
        pair TEXT PRIMARY KEY,
        exchangeName TEXT NOT NULL,
        coindcxName TEXT NOT NULL,
        symbol TEXT NOT NULL,
        ecode TEXT NOT NULL,
        baseCurrencyShortName TEXT NOT NULL,
        targetCurrencyShortName TEXT NOT NULL,
        baseCurrencyName TEXT NOT NULL,
        targetCurrencyName TEXT NOT NULL,
        status TEXT NOT NULL,
        baseCurrencyPrecision INTEGER NOT NULL,
        targetCurrencyPrecision INTEGER NOT NULL,
        minQuantity REAL NOT NULL,
        maxQuantity REAL NOT NULL,
        maxQuantityMarket REAL NOT NULL,
        step REAL NOT NULL,
        minNotional REAL NOT NULL,
        minPrice REAL NOT NULL,
        maxPrice REAL NOT NULL,
        orderTypesJson TEXT NOT NULL,
        latestTickerJson TEXT,
        latestDataTimestampMs INTEGER,
        lastMetadataRefreshMs INTEGER NOT NULL,
        isNewlyListed INTEGER NOT NULL DEFAULT 0,
        isInActiveMarketsList INTEGER NOT NULL DEFAULT 1,
        eligibilityStatus TEXT NOT NULL,
        eligibilityReason TEXT NOT NULL
      )
    ''');
  }

  Future<void> _createPortfolioAccountsTable(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS portfolio_accounts (
        portfolioId TEXT PRIMARY KEY,
        displayName TEXT NOT NULL,
        startingBalanceUsdt REAL NOT NULL,
        availableCashUsdt REAL NOT NULL,
        accountEquityUsdt REAL NOT NULL,
        startOfDayEquityUsdt REAL NOT NULL,
        realizedPnlUsdt REAL NOT NULL DEFAULT 0.0,
        maxDrawdownLocked INTEGER NOT NULL DEFAULT 0,
        lockedDailyLossUtcDate TEXT,
        lastStopLossClosedAtMs INTEGER,
        consecutiveLosses INTEGER NOT NULL DEFAULT 0,
        executionEnabled INTEGER NOT NULL DEFAULT 0,
        isResearchOnly INTEGER NOT NULL DEFAULT 1,
        activeStrategyId TEXT NOT NULL,
        maxOpenPositions INTEGER NOT NULL DEFAULT 5,
        maxPortfolioLossPct REAL NOT NULL DEFAULT 15.0,
        portfolioLossLockoutActive INTEGER NOT NULL DEFAULT 0,
        updatedAtMs INTEGER NOT NULL
      )
    ''');
  }

  Future<void> _migrateAndSeedPortfoliosOnDb(Database db) async {
    for (final table in [
      'open_positions',
      'orders',
      'closed_trades',
      'equity_snapshots',
    ]) {
      try {
        await db.execute(
          "ALTER TABLE $table ADD COLUMN portfolioId TEXT NOT NULL DEFAULT 'CRYPTO'",
        );
      } catch (_) {}
      try {
        await db.execute(
          "UPDATE $table SET portfolioId = 'CRYPTO' WHERE portfolioId IS NULL OR portfolioId = ''",
        );
      } catch (_) {}
    }
    try {
      await db.execute(
        "ALTER TABLE portfolio_accounts ADD COLUMN maxPortfolioLossPct REAL NOT NULL DEFAULT 15.0",
      );
    } catch (_) {}
    try {
      await db.execute(
        "ALTER TABLE portfolio_accounts ADD COLUMN portfolioLossLockoutActive INTEGER NOT NULL DEFAULT 0",
      );
    } catch (_) {}

    double cryptoCash = 100.0;
    double cryptoEquity = 100.0;
    double cryptoStartDay = 100.0;
    int cryptoMaxDdLocked = 0;
    String? cryptoLockedDate;
    int? cryptoLastSlMs;

    try {
      final kvRows = await db.query('engine_kv_state');
      final kv = <String, String>{
        for (final r in kvRows) r['key'] as String: r['value'] as String,
      };
      double parseD(String k, double fb) {
        final raw = kv[k];
        if (raw == null) return fb;
        try {
          return (jsonDecode(raw) as num).toDouble();
        } catch (_) {
          return double.tryParse(raw) ?? fb;
        }
      }

      cryptoCash = parseD('availableCashUsdt', 100.0);
      cryptoEquity = parseD('accountEquityUsdt', 100.0);
      cryptoStartDay = parseD('startOfDayEquityUsdt', 100.0);
      cryptoMaxDdLocked = kv['maxDrawdownLocked'] == 'true' ? 1 : 0;
      if (kv['lockedDailyLossUtcDate'] != null &&
          kv['lockedDailyLossUtcDate'] != 'null') {
        try {
          cryptoLockedDate =
              jsonDecode(kv['lockedDailyLossUtcDate']!)?.toString();
        } catch (_) {
          cryptoLockedDate = kv['lockedDailyLossUtcDate'];
        }
      }
      if (kv['lastStopLossClosedAtMs'] != null &&
          kv['lastStopLossClosedAtMs'] != 'null') {
        cryptoLastSlMs = int.tryParse(kv['lastStopLossClosedAtMs']!);
      }
    } catch (_) {}

    final nowMs = DateTime.now().millisecondsSinceEpoch;
    await db.insert(
      'portfolio_accounts',
      {
        'portfolioId': PortfolioId.crypto.dbKey,
        'displayName': PortfolioId.crypto.displayName,
        'startingBalanceUsdt': 100.0,
        'availableCashUsdt': cryptoCash,
        'accountEquityUsdt': cryptoEquity,
        'startOfDayEquityUsdt': cryptoStartDay,
        'realizedPnlUsdt': cryptoEquity - 100.0,
        'maxDrawdownLocked': cryptoMaxDdLocked,
        'lockedDailyLossUtcDate': cryptoLockedDate,
        'lastStopLossClosedAtMs': cryptoLastSlMs,
        'consecutiveLosses': 0,
        'executionEnabled': 1,
        'isResearchOnly': 0,
        'activeStrategyId': 'EMA_20_50_RSI_ATR_V1',
        'maxOpenPositions': 5,
        'maxPortfolioLossPct': 15.0,
        'portfolioLossLockoutActive': cryptoMaxDdLocked,
        'updatedAtMs': nowMs,
      },
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );

    await db.insert(
      'portfolio_accounts',
      {
        'portfolioId': PortfolioId.highVolatility.dbKey,
        'displayName': PortfolioId.highVolatility.displayName,
        'startingBalanceUsdt': 100.0,
        'availableCashUsdt': 100.0,
        'accountEquityUsdt': 100.0,
        'startOfDayEquityUsdt': 100.0,
        'realizedPnlUsdt': 0.0,
        'maxDrawdownLocked': 0,
        'lockedDailyLossUtcDate': null,
        'lastStopLossClosedAtMs': null,
        'consecutiveLosses': 0,
        'executionEnabled': 1,
        'isResearchOnly': 0,
        'activeStrategyId': 'HIGH_VOL_RESEARCH_CANDIDATE_V1',
        'maxOpenPositions': 5,
        'maxPortfolioLossPct': 15.0,
        'portfolioLossLockoutActive': 0,
        'updatedAtMs': nowMs,
      },
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
  }

  Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    await _onCreate(db, newVersion);
    if (oldVersion < 4) {
      await _createDiscoveredMarketsTable(db);
    }
    if (oldVersion < 6) {
      await _createPortfolioAccountsTable(db);
      await _migrateAndSeedPortfoliosOnDb(db);
    }
    if (oldVersion < 7) {
      try {
        await db.update(
          'portfolio_accounts',
          {'executionEnabled': 1, 'isResearchOnly': 0},
          where: 'portfolioId = ?',
          whereArgs: [PortfolioId.highVolatility.dbKey],
        );
      } catch (_) {}
    }
  }

  Future<void> migrateDatabaseSchemaIfNeeded(
    Database db, {
    required int oldVersion,
    int newVersion = currentSchemaVersion,
  }) async {
    await _onUpgrade(db, oldVersion, newVersion);
  }

  Future<void> saveDiscoveredMarkets(
    List<CoinDcxMarketRecord> markets, {
    required int refreshedAtMs,
  }) async {
    for (final m in markets) {
      _inMemoryDiscoveredMarkets[m.pair] = m;
    }
    await putKv('lastMarketCatalogueRefreshMs', jsonEncode(refreshedAtMs));

    final db = await database;
    if (db == null) return;
    await db.transaction((txn) async {
      for (final m in markets) {
        await txn.insert(
          'discovered_markets',
          m.toMap(),
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
    });
  }

  Future<List<CoinDcxMarketRecord>> loadDiscoveredMarkets() async {
    final db = await database;
    if (db == null) {
      final list = _inMemoryDiscoveredMarkets.values.toList()
        ..sort((a, b) => a.symbol.compareTo(b.symbol));
      return list;
    }
    final rows = await db.query('discovered_markets', orderBy: 'symbol ASC');
    if (rows.isEmpty && _inMemoryDiscoveredMarkets.isNotEmpty) {
      return _inMemoryDiscoveredMarkets.values.toList()
        ..sort((a, b) => a.symbol.compareTo(b.symbol));
    }
    final loaded = rows
        .map((r) => CoinDcxMarketRecord.fromMap(Map<String, dynamic>.from(r)))
        .toList();
    for (final m in loaded) {
      _inMemoryDiscoveredMarkets[m.pair] = m;
    }
    return loaded;
  }

  Future<int?> getLastMarketCatalogueRefreshMs() async {
    final raw = await getKv('lastMarketCatalogueRefreshMs');
    if (raw == null || raw == 'null') return null;
    try {
      return (jsonDecode(raw) as num?)?.toInt();
    } catch (_) {
      return int.tryParse(raw);
    }
  }

  Future<void> putKv(String key, String value) async {
    _inMemoryKv[key] = value;
    final db = await database;
    if (db == null) return;
    await db.insert(
      'engine_kv_state',
      {'key': key, 'value': value},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<String?> getKv(String key) async {
    final db = await database;
    if (db == null) return _inMemoryKv[key];
    final rows = await db.query(
      'engine_kv_state',
      where: 'key = ?',
      whereArgs: [key],
      limit: 1,
    );
    if (rows.isEmpty) return _inMemoryKv[key];
    return rows.first['value'] as String?;
  }

  Future<void> saveUserIntention(UserSessionIntention intention) async {
    await putKv('userIntention', intention.name);
    await logDiagnosticEvent(
      'USER_INTENTION',
      'User set session intention to ${intention.name.toUpperCase()}',
    );
  }

  Future<UserSessionIntention> loadUserIntention() async {
    final raw = await getKv('userIntention');
    return UserSessionIntention.values.firstWhere(
      (e) => e.name == raw,
      orElse: () => UserSessionIntention.stopped,
    );
  }

  Future<void> logDiagnosticEvent(
    String eventType,
    String reason, {
    int? timestampMs,
  }) async {
    final ts = timestampMs ?? DateTime.now().millisecondsSinceEpoch;
    final nextId = _inMemoryEvents.isEmpty ? 1 : _inMemoryEvents.first.id + 1;
    _inMemoryEvents.insert(
      0,
      DiagnosticEvent(
        id: nextId,
        timestampMs: ts,
        eventType: eventType,
        reason: reason,
      ),
    );
    if (_inMemoryEvents.length > 500) {
      _inMemoryEvents.removeRange(500, _inMemoryEvents.length);
    }

    final db = await database;
    if (db == null) return;
    await db.insert('diagnostic_events', {
      'timestampMs': ts,
      'eventType': eventType,
      'reason': reason,
    });
    await db.execute('''
      DELETE FROM diagnostic_events
      WHERE id NOT IN (
        SELECT id FROM diagnostic_events
        ORDER BY timestampMs DESC, id DESC
        LIMIT 500
      )
    ''');
  }

  Future<List<DiagnosticEvent>> getRecentDiagnosticEvents({
    int limit = 50,
  }) async {
    final db = await database;
    if (db == null) {
      return _inMemoryEvents.take(limit).toList();
    }
    final rows = await db.query(
      'diagnostic_events',
      orderBy: 'timestampMs DESC, id DESC',
      limit: limit,
    );
    return rows.map((r) => DiagnosticEvent.fromMap(r)).toList();
  }

  Future<void> recordHeartbeat(int timestampMs) async {
    await putKv('lastHeartbeatMs', jsonEncode(timestampMs));
  }

  Future<bool> getAutoResumeEnabled() async {
    final raw = await getKv('autoResumeEnabled');
    return raw == 'true';
  }

  Future<void> setAutoResumeEnabled(bool enabled) async {
    await putKv('autoResumeEnabled', enabled ? 'true' : 'false');
    await logDiagnosticEvent(
      'SETTING_CHANGE',
      'Auto-resume on network recovery set to ${enabled ? "ON" : "OFF"}',
    );
  }

  Future<bool> acquireExecutionLock({
    required String lockName,
    required String ownerId,
    required int nowMs,
    int ttlMs = 55000,
    bool forceTakeover = false,
  }) async {
    final db = await database;
    if (db == null) {
      final existing = _inMemoryLocks[lockName];
      if (!forceTakeover &&
          existing != null &&
          existing['ownerId'] != ownerId &&
          (existing['expiresAtMs'] as int) > nowMs) {
        return false;
      }
      _inMemoryLocks[lockName] = {
        'ownerId': ownerId,
        'acquiredAtMs': nowMs,
        'expiresAtMs': nowMs + ttlMs,
      };
      return true;
    }

    return await db.transaction((txn) async {
      final rows = await txn.query(
        'execution_locks',
        where: 'lockName = ?',
        whereArgs: [lockName],
        limit: 1,
      );
      if (!forceTakeover && rows.isNotEmpty) {
        final curOwner = rows.first['ownerId'] as String;
        final expiresAt = (rows.first['expiresAtMs'] as num).toInt();
        if (curOwner != ownerId && expiresAt > nowMs) {
          return false;
        }
      }
      await txn.insert(
        'execution_locks',
        {
          'lockName': lockName,
          'ownerId': ownerId,
          'acquiredAtMs': nowMs,
          'expiresAtMs': nowMs + ttlMs,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      return true;
    });
  }

  Future<void> releaseExecutionLock({
    required String lockName,
    required String ownerId,
  }) async {
    final db = await database;
    if (db == null) {
      if (_inMemoryLocks[lockName]?['ownerId'] == ownerId) {
        _inMemoryLocks.remove(lockName);
      }
      return;
    }
    await db.delete(
      'execution_locks',
      where: 'lockName = ? AND ownerId = ?',
      whereArgs: [lockName, ownerId],
    );
  }

  Future<void> saveRecoveryState({
    required int attemptCount,
    required int recoveryStartedAtMs,
    required int nextRecoveryAllowedAtMs,
    required String logMessage,
  }) async {
    await putKv('recoveryAttemptCount', jsonEncode(attemptCount));
    await putKv('recoveryStartedAtMs', jsonEncode(recoveryStartedAtMs));
    await putKv('nextRecoveryAllowedAtMs', jsonEncode(nextRecoveryAllowedAtMs));
    await putKv('lastError', logMessage);
    await logDiagnosticEvent(
      'RECOVERY',
      logMessage,
      timestampMs: DateTime.now().millisecondsSinceEpoch,
    );

    final rawLogs = await getKv('recoveryLogs');
    final logs = <String>[];
    if (rawLogs != null) {
      try {
        final decoded = jsonDecode(rawLogs);
        if (decoded is List) {
          logs.addAll(decoded.map((e) => e.toString()));
        }
      } catch (_) {}
    }
    logs.insert(0, logMessage);
    if (logs.length > 25) {
      logs.removeRange(25, logs.length);
    }
    await putKv('recoveryLogs', jsonEncode(logs));
  }

  Future<void> clearRecoveryState() async {
    await putKv('recoveryAttemptCount', jsonEncode(0));
    await putKv('recoveryStartedAtMs', jsonEncode(null));
    await putKv('nextRecoveryAllowedAtMs', jsonEncode(null));
    await putKv('lastError', jsonEncode(null));
  }

  Future<void> saveScanCycleDiagnostics(
    ScanCycleDiagnosticsSnapshot diagnostics,
  ) async {
    await putKv('scanCycleDiagnostics', jsonEncode(diagnostics.toMap()));
  }

  Future<ScanCycleDiagnosticsSnapshot> loadScanCycleDiagnostics() async {
    final raw = await getKv('scanCycleDiagnostics');
    if (raw == null || raw.isEmpty) {
      return const ScanCycleDiagnosticsSnapshot();
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        return ScanCycleDiagnosticsSnapshot.fromMap(
          Map<String, dynamic>.from(decoded),
        );
      }
    } catch (_) {}
    return const ScanCycleDiagnosticsSnapshot();
  }

  Future<bool> getTradeAlertsEnabled() async {
    final raw = await getKv('tradeAlertsEnabled');
    if (raw == null) return true;
    return raw == 'true';
  }

  Future<void> setTradeAlertsEnabled(bool enabled) async {
    await putKv('tradeAlertsEnabled', enabled ? 'true' : 'false');
  }

  Future<Set<String>> getNotifiedAlertIds() async {
    final raw = await getKv('notifiedAlertIds');
    if (raw == null) return {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) {
        return decoded.map((e) => e.toString()).toSet();
      }
    } catch (_) {}
    return {};
  }

  Future<void> markAlertIdNotified(String alertId) async {
    final current = await getNotifiedAlertIds();
    current.add(alertId);
    final list = current.toList();
    if (list.length > 200) {
      list.removeRange(0, list.length - 200);
    }
    await putKv('notifiedAlertIds', jsonEncode(list));
  }

  Future<void> saveFullState({
    required BotEngineState botState,
    UserSessionIntention? userIntention,
    required double availableCashUsdt,
    required double accountEquityUsdt,
    required bool maxDrawdownLocked,
    String? lockedDailyLossUtcDate,
    int? lastStopLossClosedAtMs,
    int? lastHeartbeatMs,
    int? lastMarketDataUpdateMs,
    int? lastCandleUpdateMs,
    int? runningSinceMs,
    int totalActiveMs = 0,
    int? orderSeq,
    required String statusBannerMessage,
    Map<String, double> liveTickerPrices = const {},
    Map<String, LiveMarketTicker> liveTickers = const {},
    Map<String, double> closedCandlePrices = const {},
    Map<String, String> whyNoTradeForSymbol = const {},
    required List<PaperPosition> openPositions,
    required List<SimulatedOrder> orders,
    required List<ClosedPaperTrade> closedTrades,
    required Set<String> processedEntrySignalKeys,
    ScanCycleDiagnosticsSnapshot? scanDiagnostics,
    int? lastStartupAttemptMs,
    String? lastStartupError,
    String? lastShutdownReason,
    String? lastBackgroundCycleError,
  }) async {
    await putKv('botState', botState.name);
    if (userIntention != null) {
      await putKv('userIntention', userIntention.name);
    }
    await putKv('availableCashUsdt', jsonEncode(availableCashUsdt));
    await putKv('accountEquityUsdt', jsonEncode(accountEquityUsdt));
    await putKv('maxDrawdownLocked', jsonEncode(maxDrawdownLocked));
    await putKv('lockedDailyLossUtcDate', jsonEncode(lockedDailyLossUtcDate));
    await putKv('lastStopLossClosedAtMs', jsonEncode(lastStopLossClosedAtMs));
    if (lastHeartbeatMs != null) {
      await putKv('lastHeartbeatMs', jsonEncode(lastHeartbeatMs));
    }
    if (lastMarketDataUpdateMs != null) {
      await putKv('lastMarketDataUpdateMs', jsonEncode(lastMarketDataUpdateMs));
    }
    if (lastCandleUpdateMs != null) {
      await putKv('lastCandleUpdateMs', jsonEncode(lastCandleUpdateMs));
    }
    if (orderSeq != null) {
      await putKv('orderSeq', jsonEncode(orderSeq));
    }
    await putKv('runningSinceMs', jsonEncode(runningSinceMs));
    await putKv('totalActiveMs', jsonEncode(totalActiveMs));
    await putKv('statusBannerMessage', statusBannerMessage);
    await putKv('liveTickerPrices', jsonEncode(liveTickerPrices));
    await putKv(
      'liveTickers',
      jsonEncode({for (final e in liveTickers.entries) e.key: e.value.toMap()}),
    );
    await putKv('closedCandlePrices', jsonEncode(closedCandlePrices));
    await putKv('whyNoTradeForSymbol', jsonEncode(whyNoTradeForSymbol));
    if (scanDiagnostics != null) {
      await putKv('scanCycleDiagnostics', jsonEncode(scanDiagnostics.toMap()));
    }
    if (lastStartupAttemptMs != null) {
      await putKv('lastStartupAttemptMs', jsonEncode(lastStartupAttemptMs));
    }
    if (lastStartupError != null) {
      await putKv('lastStartupError', jsonEncode(lastStartupError));
    }
    if (lastShutdownReason != null) {
      await putKv('lastShutdownReason', jsonEncode(lastShutdownReason));
    }
    if (lastBackgroundCycleError != null) {
      await putKv('lastBackgroundCycleError', jsonEncode(lastBackgroundCycleError));
    }

    final nowMs = lastHeartbeatMs ?? DateTime.now().millisecondsSinceEpoch;
    _inMemoryEquityCurve.add(
      EquityPoint(timestampMs: nowMs, equityUsdt: accountEquityUsdt),
    );
    if (_inMemoryEquityCurve.length > 120) {
      _inMemoryEquityCurve.removeRange(0, _inMemoryEquityCurve.length - 120);
    }

    _inMemoryOpenPositions
      ..clear()
      ..addAll(openPositions);
    _inMemoryOrders
      ..clear()
      ..addAll(orders);
    _inMemoryClosedTrades
      ..clear()
      ..addAll(closedTrades);
    _inMemoryProcessedKeys
      ..clear()
      ..addAll(processedEntrySignalKeys);

    final db = await database;
    if (db == null) return;

    await db.transaction((txn) async {
      await txn.delete('open_positions', where: "portfolioId = ?", whereArgs: ['CRYPTO']);
      for (final pos in openPositions) {
        await txn.insert(
          'open_positions',
          pos.toMap(),
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }

      for (final ord in orders.take(100)) {
        await txn.insert(
          'orders',
          ord.toMap(),
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }

      for (final trd in closedTrades.take(100)) {
        await txn.insert(
          'closed_trades',
          trd.toMap(),
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }

      await txn.insert(
        'equity_snapshots',
        {
          'timestampMs': nowMs,
          'portfolioId': 'CRYPTO',
          'equityUsdt': accountEquityUsdt,
          'availableCashUsdt': availableCashUsdt,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );

      for (final key in processedEntrySignalKeys) {
        await txn.insert(
          'processed_signal_keys',
          {'signalKey': key, 'processedAtMs': nowMs},
          conflictAlgorithm: ConflictAlgorithm.ignore,
        );
      }
    });
  }

  Future<PersistedEngineSnapshot> loadFullState() async {
    final db = await database;
    final kv = <String, String>{..._inMemoryKv};
    List<PaperPosition> openPos = List.from(_inMemoryOpenPositions);
    List<SimulatedOrder> ordList = List.from(_inMemoryOrders);
    List<ClosedPaperTrade> trdList = List.from(_inMemoryClosedTrades);
    List<EquityPoint> eqCurve = List.from(_inMemoryEquityCurve);
    List<DiagnosticEvent> events = List.from(_inMemoryEvents);
    Set<String> sigKeys = Set.from(_inMemoryProcessedKeys);

    if (db != null) {
      final kvRows = await db.query('engine_kv_state');
      for (final r in kvRows) {
        kv[r['key'] as String] = r['value'] as String;
      }
      const cryptoWhere = "portfolioId = ? OR portfolioId IS NULL OR portfolioId = ''";
      final posRows = await db.query('open_positions', where: cryptoWhere, whereArgs: ['CRYPTO'], orderBy: 'openedAtMs DESC');
      openPos = posRows.map((r) => PaperPosition.fromMap(r)).toList();

      final ordRows = await db.query('orders', where: cryptoWhere, whereArgs: ['CRYPTO'], orderBy: 'executedAtMs DESC', limit: 100);
      ordList = ordRows.map((r) => SimulatedOrder.fromMap(r)).toList();

      final trdRows = await db.query('closed_trades', where: cryptoWhere, whereArgs: ['CRYPTO'], orderBy: 'closedAtMs DESC', limit: 100);
      trdList = trdRows.map((r) => ClosedPaperTrade.fromMap(r)).toList();

      final eqRows = await db.query('equity_snapshots', where: cryptoWhere, whereArgs: ['CRYPTO'], orderBy: 'timestampMs DESC', limit: 120);
      eqCurve = eqRows.reversed
          .map((r) => EquityPoint(
                timestampMs: (r['timestampMs'] as num).toInt(),
                equityUsdt: (r['equityUsdt'] as num).toDouble(),
              ))
          .toList();

      final evRows = await db.query('diagnostic_events',
          orderBy: 'timestampMs DESC, id DESC', limit: 50);
      events = evRows.map((r) => DiagnosticEvent.fromMap(r)).toList();

      final keyRows = await db.query('processed_signal_keys');
      sigKeys = keyRows.map((r) => r['signalKey'] as String).toSet();
    }

    final stateName = kv['botState'] ?? BotEngineState.stopped.name;
    final botState = BotEngineState.values.firstWhere(
      (e) => e.name == stateName,
      orElse: () => BotEngineState.stopped,
    );

    final intentionName = kv['userIntention'] ??
        (botState == BotEngineState.running
            ? UserSessionIntention.running.name
            : (botState == BotEngineState.stopped ||
                    botState == BotEngineState.stoppedMaxDrawdownReached
                ? UserSessionIntention.stopped.name
                : UserSessionIntention.running.name));
    final userIntention = UserSessionIntention.values.firstWhere(
      (e) => e.name == intentionName,
      orElse: () => UserSessionIntention.stopped,
    );

    double parseDouble(String key, double fallback) {
      final raw = kv[key];
      if (raw == null) return fallback;
      try {
        return (jsonDecode(raw) as num).toDouble();
      } catch (_) {
        return double.tryParse(raw) ?? fallback;
      }
    }

    int? parseIntOrNull(String key) {
      final raw = kv[key];
      if (raw == null || raw == 'null') return null;
      try {
        return (jsonDecode(raw) as num?)?.toInt();
      } catch (_) {
        return int.tryParse(raw);
      }
    }

    bool parseBool(String key, bool fallback) {
      final raw = kv[key];
      if (raw == null) return fallback;
      return raw == 'true';
    }

    Map<String, double> parsePriceMap(String key) {
      final raw = kv[key];
      if (raw == null) return {};
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          return {
            for (final e in decoded.entries)
              e.key.toString(): (e.value as num).toDouble(),
          };
        }
      } catch (_) {}
      return {};
    }

    Map<String, LiveMarketTicker> parseTickerMap(String key) {
      final raw = kv[key];
      if (raw == null) return {};
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          return {
            for (final e in decoded.entries)
              if (e.value is Map)
                e.key.toString(): LiveMarketTicker.fromMap(
                  Map<String, dynamic>.from(e.value as Map),
                ),
          };
        }
      } catch (_) {}
      return {};
    }

    Map<String, String> parseStringMap(String key) {
      final raw = kv[key];
      if (raw == null) return {};
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          return {
            for (final e in decoded.entries)
              e.key.toString(): e.value.toString(),
          };
        }
      } catch (_) {}
      return {};
    }

    List<String> parseStringList(String key) {
      final raw = kv[key];
      if (raw == null) return [];
      try {
        final decoded = jsonDecode(raw);
        if (decoded is List) {
          return decoded.map((e) => e.toString()).toList();
        }
      } catch (_) {}
      return [];
    }

    String? parseStringOrNull(String key) {
      final raw = kv[key];
      if (raw == null || raw == 'null') return null;
      try {
        return jsonDecode(raw)?.toString();
      } catch (_) {
        return raw;
      }
    }

    return PersistedEngineSnapshot(
      botState: botState,
      userIntention: userIntention,
      availableCashUsdt: parseDouble('availableCashUsdt', 100.0),
      accountEquityUsdt: parseDouble('accountEquityUsdt', 100.0),
      startOfDayEquityUsdt: parseDouble('startOfDayEquityUsdt', 100.0),
      maxDrawdownLocked: parseBool('maxDrawdownLocked', false),
      lockedDailyLossUtcDate: parseStringOrNull('lockedDailyLossUtcDate'),
      lastStopLossClosedAtMs: parseIntOrNull('lastStopLossClosedAtMs'),
      lastHeartbeatMs: parseIntOrNull('lastHeartbeatMs'),
      lastMarketDataUpdateMs: parseIntOrNull('lastMarketDataUpdateMs'),
      lastCandleUpdateMs: parseIntOrNull('lastCandleUpdateMs'),
      runningSinceMs: parseIntOrNull('runningSinceMs'),
      totalActiveMs: parseIntOrNull('totalActiveMs') ?? 0,
      serviceRestartCount: parseIntOrNull('serviceRestartCount') ?? 0,
      orderSeq: parseIntOrNull('orderSeq') ?? ordList.length,
      autoResumeEnabled: parseBool('autoResumeEnabled', false),
      statusBannerMessage:
          kv['statusBannerMessage'] ?? 'PAPER BOT STOPPED — PRESS START',
      lastError: parseStringOrNull('lastError'),
      tradeAlertsEnabled: parseBool('tradeAlertsEnabled', true),
      liveTickerPrices: parsePriceMap('liveTickerPrices'),
      liveTickers: parseTickerMap('liveTickers'),
      closedCandlePrices: parsePriceMap('closedCandlePrices'),
      whyNoTradeForSymbol: parseStringMap('whyNoTradeForSymbol'),
      openPositions: openPos,
      orders: ordList,
      closedTrades: trdList,
      equityCurve: eqCurve,
      recentEvents: events,
      processedEntrySignalKeys: sigKeys,
      recoveryAttemptCount: parseIntOrNull('recoveryAttemptCount') ?? 0,
      recoveryStartedAtMs: parseIntOrNull('recoveryStartedAtMs'),
      nextRecoveryAllowedAtMs: parseIntOrNull('nextRecoveryAllowedAtMs'),
      recoveryLogs: parseStringList('recoveryLogs'),
      scanDiagnostics: await loadScanCycleDiagnostics(),
      lastStartupAttemptMs: parseIntOrNull('lastStartupAttemptMs'),
      lastStartupError: parseStringOrNull('lastStartupError'),
      lastShutdownReason: parseStringOrNull('lastShutdownReason'),
      lastBackgroundCycleError: parseStringOrNull('lastBackgroundCycleError'),
    );
  }

  Future<void> saveStartupDiagnostics({
    BotEngineState? botState,
    UserSessionIntention? userIntention,
    int? lastStartupAttemptMs,
    String? lastStartupError,
    bool clearStartupError = false,
    String? lastShutdownReason,
    bool clearShutdownReason = false,
    String? lastBackgroundCycleError,
    bool clearBackgroundCycleError = false,
    String? statusBannerMessage,
  }) async {
    if (botState != null) {
      await putKv('botState', botState.name);
    }
    if (userIntention != null) {
      await putKv('userIntention', userIntention.name);
    }
    if (lastStartupAttemptMs != null) {
      await putKv('lastStartupAttemptMs', jsonEncode(lastStartupAttemptMs));
    }
    if (clearStartupError) {
      await putKv('lastStartupError', jsonEncode(null));
    } else if (lastStartupError != null) {
      await putKv('lastStartupError', jsonEncode(lastStartupError));
    }
    if (clearShutdownReason) {
      await putKv('lastShutdownReason', jsonEncode(null));
    } else if (lastShutdownReason != null) {
      await putKv('lastShutdownReason', jsonEncode(lastShutdownReason));
    }
    if (clearBackgroundCycleError) {
      await putKv('lastBackgroundCycleError', jsonEncode(null));
    } else if (lastBackgroundCycleError != null) {
      await putKv('lastBackgroundCycleError', jsonEncode(lastBackgroundCycleError));
    }
    if (statusBannerMessage != null) {
      await putKv('statusBannerMessage', statusBannerMessage);
    }
  }

  Future<void> savePortfolioAccountSnapshot(
    PortfolioAccountSnapshot snapshot,
  ) async {
    _inMemoryPortfolioSnapshots[snapshot.portfolioId] = snapshot;
    final db = await database;
    if (db == null) return;

    await db.transaction((txn) async {
      await txn.insert(
        'portfolio_accounts',
        snapshot.toDbRow(),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      await txn.delete(
        'open_positions',
        where: 'portfolioId = ?',
        whereArgs: [snapshot.portfolioId.dbKey],
      );
      for (final pos in snapshot.openPositions) {
        final map = pos.toMap();
        map['portfolioId'] = snapshot.portfolioId.dbKey;
        await txn.insert(
          'open_positions',
          map,
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
      for (final ord in snapshot.orders.take(100)) {
        final map = ord.toMap();
        map['portfolioId'] = snapshot.portfolioId.dbKey;
        await txn.insert(
          'orders',
          map,
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
      for (final trd in snapshot.closedTrades.take(100)) {
        final map = trd.toMap();
        map['portfolioId'] = snapshot.portfolioId.dbKey;
        await txn.insert(
          'closed_trades',
          map,
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
    });
  }

  Future<PortfolioAccountSnapshot?> loadPortfolioAccountSnapshot(
    PortfolioId portfolioId,
  ) async {
    final db = await database;
    if (db == null) {
      return _inMemoryPortfolioSnapshots[portfolioId];
    }

    final rows = await db.query(
      'portfolio_accounts',
      where: 'portfolioId = ?',
      whereArgs: [portfolioId.dbKey],
      limit: 1,
    );
    if (rows.isEmpty) {
      return _inMemoryPortfolioSnapshots[portfolioId];
    }

    final r = rows.first;
    final whereClause = portfolioId == PortfolioId.crypto
        ? "portfolioId = ? OR portfolioId IS NULL OR portfolioId = ''"
        : 'portfolioId = ?';
    final posRows = await db.query(
      'open_positions',
      where: whereClause,
      whereArgs: [portfolioId.dbKey],
      orderBy: 'openedAtMs DESC',
    );
    final ordRows = await db.query(
      'orders',
      where: whereClause,
      whereArgs: [portfolioId.dbKey],
      orderBy: 'executedAtMs DESC',
      limit: 100,
    );
    final trdRows = await db.query(
      'closed_trades',
      where: whereClause,
      whereArgs: [portfolioId.dbKey],
      orderBy: 'closedAtMs DESC',
      limit: 100,
    );
    final eqRows = await db.query(
      'equity_snapshots',
      where: whereClause,
      whereArgs: [portfolioId.dbKey],
      orderBy: 'timestampMs DESC',
      limit: 120,
    );

    final openPos = posRows.map((m) => PaperPosition.fromMap(m)).toList();
    final orders = ordRows.map((m) => SimulatedOrder.fromMap(m)).toList();
    final closedTrades =
        trdRows.map((m) => ClosedPaperTrade.fromMap(m)).toList();
    final eqCurve = eqRows.reversed
        .map(
          (m) => EquityPoint(
            timestampMs: (m['timestampMs'] as num).toInt(),
            equityUsdt: (m['equityUsdt'] as num).toDouble(),
            portfolioId: portfolioId.dbKey,
          ),
        )
        .toList();

    final wins = closedTrades.where((t) => t.realizedPnlUsdt >= 0).length;
    final losses = closedTrades.length - wins;
    final realizedPnl =
        (r['realizedPnlUsdt'] as num?)?.toDouble() ??
        closedTrades.fold<double>(0.0, (acc, t) => acc + t.realizedPnlUsdt);
    final isResearch = (r['isResearchOnly'] as num?)?.toInt() == 1;
    final execEnabled = (r['executionEnabled'] as num?)?.toInt() == 1;
    final stratId =
        (r['activeStrategyId'] as String?) ??
        (portfolioId == PortfolioId.crypto
            ? 'EMA_20_50_RSI_ATR_V1'
            : 'HIGH_VOL_RESEARCH_CANDIDATE_V1');

    final loaded = PortfolioAccountSnapshot(
      portfolioId: portfolioId,
      displayName: (r['displayName'] as String?) ?? portfolioId.displayName,
      startingBalanceUsdt:
          (r['startingBalanceUsdt'] as num?)?.toDouble() ?? 100.0,
      availableCashUsdt: (r['availableCashUsdt'] as num?)?.toDouble() ?? 100.0,
      accountEquityUsdt: (r['accountEquityUsdt'] as num?)?.toDouble() ?? 100.0,
      startOfDayEquityUsdt:
          (r['startOfDayEquityUsdt'] as num?)?.toDouble() ?? 100.0,
      realizedPnlUsdt: realizedPnl,
      maxDrawdownLocked: (r['maxDrawdownLocked'] as num?)?.toInt() == 1,
      lockedDailyLossUtcDate: r['lockedDailyLossUtcDate'] as String?,
      lastStopLossClosedAtMs: (r['lastStopLossClosedAtMs'] as num?)?.toInt(),
      consecutiveLosses: (r['consecutiveLosses'] as num?)?.toInt() ?? 0,
      executionEnabled: execEnabled,
      isResearchOnlyMode: isResearch,
      liveTradingLocked: true,
      activeStrategyId: stratId,
      configuredMaxOpenPositions:
          (r['maxOpenPositions'] as num?)?.toInt() ?? 5,
      maxPortfolioLossPct:
          (r['maxPortfolioLossPct'] as num?)?.toDouble() ?? 15.0,
      portfolioLossLockoutActive:
          (r['portfolioLossLockoutActive'] as num?)?.toInt() == 1 ||
              (r['maxDrawdownLocked'] as num?)?.toInt() == 1,
      openPositions: openPos,
      orders: orders,
      closedTrades: closedTrades,
      equityCurve: eqCurve,
      learningContext: PortfolioLearningContext(
        portfolioId: portfolioId,
        activeStrategyId: stratId,
        evaluatedClosedTradesCount: closedTrades.length,
        observedWinningTrades: wins,
        observedLosingTrades: losses,
        cumulativeRealizedPnlUsdt: realizedPnl,
      ),
      statusSummary: isResearch
          ? 'RESEARCH-ONLY MODE • High-Vol Crypto & Metals (XAUUSD/XAGUSD) • Execution Disabled Until Provider Verified'
          : 'Active Paper Portfolio • CoinDCX Spot • \$100.00 Preserved Account',
      updatedAtMs: (r['updatedAtMs'] as num?)?.toInt() ?? 0,
    );
    _inMemoryPortfolioSnapshots[portfolioId] = loaded;
    return loaded;
  }

  Future<void> close() async {
    final db = _db;
    _db = null;
    if (db != null && db.isOpen) {
      await db.close();
    }
  }
}

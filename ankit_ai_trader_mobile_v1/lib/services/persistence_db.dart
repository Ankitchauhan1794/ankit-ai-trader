import 'dart:convert';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';
import '../models/trading_models.dart';

class PersistedEngineSnapshot {
  final BotEngineState botState;
  final UserSessionIntention userIntention;
  final double availableCashUsdt;
  final double accountEquityUsdt;
  final bool maxDrawdownLocked;
  final String? lockedDailyLossUtcDate;
  final int? lastStopLossClosedAtMs;
  final int? lastHeartbeatMs;
  final int? lastMarketDataUpdateMs;
  final int? runningSinceMs;
  final int totalActiveMs;
  final String statusBannerMessage;
  final bool tradeAlertsEnabled;
  final Map<String, double> liveTickerPrices;
  final Map<String, LiveMarketTicker> liveTickers;
  final Map<String, double> closedCandlePrices;
  final Map<String, String> whyNoTradeForSymbol;
  final List<PaperPosition> openPositions;
  final List<SimulatedOrder> orders;
  final List<ClosedPaperTrade> closedTrades;
  final Set<String> processedEntrySignalKeys;
  final int recoveryAttemptCount;
  final int? recoveryStartedAtMs;
  final int? nextRecoveryAllowedAtMs;
  final List<String> recoveryLogs;

  const PersistedEngineSnapshot({
    required this.botState,
    required this.userIntention,
    required this.availableCashUsdt,
    required this.accountEquityUsdt,
    required this.maxDrawdownLocked,
    this.lockedDailyLossUtcDate,
    this.lastStopLossClosedAtMs,
    this.lastHeartbeatMs,
    this.lastMarketDataUpdateMs,
    this.runningSinceMs,
    this.totalActiveMs = 0,
    required this.statusBannerMessage,
    this.tradeAlertsEnabled = true,
    this.liveTickerPrices = const {},
    this.liveTickers = const {},
    this.closedCandlePrices = const {},
    this.whyNoTradeForSymbol = const {},
    this.openPositions = const [],
    this.orders = const [],
    this.closedTrades = const [],
    this.processedEntrySignalKeys = const {},
    this.recoveryAttemptCount = 0,
    this.recoveryStartedAtMs,
    this.nextRecoveryAllowedAtMs,
    this.recoveryLogs = const [],
  });
}

class PersistenceDatabase {
  static const String dbFileName = 'ankit_ai_trader_phase1.db';
  Database? _db;
  final Map<String, String> _inMemoryKv = {};
  final List<PaperPosition> _inMemoryOpenPositions = [];
  final List<SimulatedOrder> _inMemoryOrders = [];
  final List<ClosedPaperTrade> _inMemoryClosedTrades = [];
  final Set<String> _inMemoryProcessedKeys = {};
  final Map<String, Map<String, dynamic>> _inMemoryLocks = {};
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
        version: 2,
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
  }

  Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    await _onCreate(db, newVersion);
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

  /// Stage 2: Persist user intention separately from runtime botState.
  Future<void> saveUserIntention(UserSessionIntention intention) async {
    await putKv('userIntention', intention.name);
  }

  Future<UserSessionIntention> loadUserIntention() async {
    final raw = await getKv('userIntention');
    return UserSessionIntention.values.firstWhere(
      (e) => e.name == raw,
      orElse: () => UserSessionIntention.stopped,
    );
  }

  /// Stage 4: Record engine heartbeat timestamp in SQLite.
  Future<void> recordHeartbeat(int timestampMs) async {
    await putKv('lastHeartbeatMs', jsonEncode(timestampMs));
  }

  /// Stage 7: Single authoritative engine execution lock.
  Future<bool> acquireExecutionLock({
    required String lockName,
    required String ownerId,
    required int nowMs,
    int ttlMs = 55000,
  }) async {
    final db = await database;
    if (db == null) {
      final existing = _inMemoryLocks[lockName];
      if (existing != null &&
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
      if (rows.isNotEmpty) {
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
    int? runningSinceMs,
    int totalActiveMs = 0,
    required String statusBannerMessage,
    Map<String, double> liveTickerPrices = const {},
    Map<String, LiveMarketTicker> liveTickers = const {},
    Map<String, double> closedCandlePrices = const {},
    Map<String, String> whyNoTradeForSymbol = const {},
    required List<PaperPosition> openPositions,
    required List<SimulatedOrder> orders,
    required List<ClosedPaperTrade> closedTrades,
    required Set<String> processedEntrySignalKeys,
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
      await txn.delete('open_positions');
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

      final nowMs = DateTime.now().millisecondsSinceEpoch;
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
    Set<String> sigKeys = Set.from(_inMemoryProcessedKeys);

    if (db != null) {
      final kvRows = await db.query('engine_kv_state');
      for (final r in kvRows) {
        kv[r['key'] as String] = r['value'] as String;
      }
      final posRows =
          await db.query('open_positions', orderBy: 'openedAtMs DESC');
      openPos = posRows.map((r) => PaperPosition.fromMap(r)).toList();

      final ordRows =
          await db.query('orders', orderBy: 'executedAtMs DESC', limit: 100);
      ordList = ordRows.map((r) => SimulatedOrder.fromMap(r)).toList();

      final trdRows = await db.query('closed_trades',
          orderBy: 'closedAtMs DESC', limit: 100);
      trdList = trdRows.map((r) => ClosedPaperTrade.fromMap(r)).toList();

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
      maxDrawdownLocked: parseBool('maxDrawdownLocked', false),
      lockedDailyLossUtcDate: parseStringOrNull('lockedDailyLossUtcDate'),
      lastStopLossClosedAtMs: parseIntOrNull('lastStopLossClosedAtMs'),
      lastHeartbeatMs: parseIntOrNull('lastHeartbeatMs'),
      lastMarketDataUpdateMs: parseIntOrNull('lastMarketDataUpdateMs'),
      runningSinceMs: parseIntOrNull('runningSinceMs'),
      totalActiveMs: parseIntOrNull('totalActiveMs') ?? 0,
      statusBannerMessage:
          kv['statusBannerMessage'] ?? 'PAPER BOT STOPPED — PRESS START',
      tradeAlertsEnabled: parseBool('tradeAlertsEnabled', true),
      liveTickerPrices: parsePriceMap('liveTickerPrices'),
      liveTickers: parseTickerMap('liveTickers'),
      closedCandlePrices: parsePriceMap('closedCandlePrices'),
      whyNoTradeForSymbol: parseStringMap('whyNoTradeForSymbol'),
      openPositions: openPos,
      orders: ordList,
      closedTrades: trdList,
      processedEntrySignalKeys: sigKeys,
      recoveryAttemptCount: parseIntOrNull('recoveryAttemptCount') ?? 0,
      recoveryStartedAtMs: parseIntOrNull('recoveryStartedAtMs'),
      nextRecoveryAllowedAtMs: parseIntOrNull('nextRecoveryAllowedAtMs'),
      recoveryLogs: parseStringList('recoveryLogs'),
    );
  }

  Future<void> close() async {
    final db = _db;
    _db = null;
    if (db != null && db.isOpen) {
      await db.close();
    }
  }
}

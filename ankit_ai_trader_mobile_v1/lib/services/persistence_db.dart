import 'dart:convert';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';
import '../models/trading_models.dart';
import 'paper_broker.dart';
import 'strategy_engine.dart';

class PersistedEngineSnapshot {
  final BotEngineState botState;
  final MarketDataStatus marketDataStatus;
  final String statusBannerMessage;
  final int? lastMarketDataUpdateMs;
  final Map<String, double> latestPrices;
  final Map<String, StrategyEvaluationResult> latestEvaluations;
  final bool tradeAlertsEnabled;
  final Set<String> notifiedAlertIds;

  const PersistedEngineSnapshot({
    required this.botState,
    required this.marketDataStatus,
    required this.statusBannerMessage,
    this.lastMarketDataUpdateMs,
    required this.latestPrices,
    required this.latestEvaluations,
    this.tradeAlertsEnabled = true,
    this.notifiedAlertIds = const {},
  });
}

class PersistenceDatabase {
  static const int schemaVersion = 2;
  Database? _db;

  Future<Database> get database async {
    if (_db != null) return _db!;
    final dbPath = await getDatabasesPath();
    final fullPath = p.join(dbPath, 'ankit_ai_trader_phase1.db');
    _db = await openDatabase(
      fullPath,
      version: schemaVersion,
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
    );
    return _db!;
  }

  Future<void> openWithCustomDatabase(Database customDb) async {
    _db = customDb;
    await _onCreate(customDb, schemaVersion);
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

    await db.execute('''
      CREATE TABLE IF NOT EXISTS processed_signal_keys (
        signalKey TEXT PRIMARY KEY,
        processedAtMs INTEGER NOT NULL
      )
    ''');
  }

  Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 2) {
      await _onCreate(db, newVersion);
    }
  }

  /// Reads whether Trade Alert notifications are enabled from `engine_kv_state`.
  /// Defaults to `true` (ON) when not yet set.
  Future<bool> getTradeAlertsEnabled() async {
    final db = await database;
    final rows = await db.query(
      'engine_kv_state',
      where: 'key = ?',
      whereArgs: ['tradeAlertsEnabled'],
    );
    if (rows.isEmpty) return true;
    final decoded = jsonDecode(rows.first['value'] as String);
    if (decoded is bool) return decoded;
    return true;
  }

  /// Persists the "Trade alert notifications" ON/OFF toggle in `engine_kv_state`
  /// so it survives app restarts and process death and takes effect immediately.
  Future<void> setTradeAlertsEnabled(bool enabled) async {
    final db = await database;
    await db.insert(
      'engine_kv_state',
      {'key': 'tradeAlertsEnabled', 'value': jsonEncode(enabled)},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// Reads the set of already-notified alert IDs (order IDs / lock event keys)
  /// from `engine_kv_state` so service restarts cannot send duplicate alerts.
  Future<Set<String>> getNotifiedAlertIds() async {
    final db = await database;
    final rows = await db.query(
      'engine_kv_state',
      where: 'key = ?',
      whereArgs: ['notifiedAlertIds'],
    );
    if (rows.isEmpty) return <String>{};
    final decoded = jsonDecode(rows.first['value'] as String);
    if (decoded is List) {
      return decoded.map((e) => e.toString()).toSet();
    }
    return <String>{};
  }

  /// Marks an alert ID (such as `ENTRY:ORD-BUY-...`, `EXIT:ORD-SELL-...`, or `LOCK:...`)
  /// as sent in `engine_kv_state`. Returns `true` if newly recorded, or `false` if it was
  /// already notified previously.
  Future<bool> markAlertIdNotified(String alertId) async {
    final db = await database;
    return db.transaction<bool>((txn) async {
      final rows = await txn.query(
        'engine_kv_state',
        where: 'key = ?',
        whereArgs: ['notifiedAlertIds'],
      );
      final existing = <String>{};
      if (rows.isNotEmpty) {
        final decoded = jsonDecode(rows.first['value'] as String);
        if (decoded is List) {
          existing.addAll(decoded.map((e) => e.toString()));
        }
      }
      if (existing.contains(alertId)) {
        return false;
      }
      existing.add(alertId);
      await txn.insert(
        'engine_kv_state',
        {
          'key': 'notifiedAlertIds',
          'value': jsonEncode(existing.toList()),
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      await txn.insert(
        'engine_kv_state',
        {
          'key': 'lastNotifiedOrderId',
          'value': jsonEncode(alertId),
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      return true;
    });
  }

  Future<String?> getLastNotifiedOrderId() async {
    final db = await database;
    final rows = await db.query(
      'engine_kv_state',
      where: 'key = ?',
      whereArgs: ['lastNotifiedOrderId'],
    );
    if (rows.isEmpty) return null;
    final decoded = jsonDecode(rows.first['value'] as String);
    return decoded?.toString();
  }

  /// Acquires a persistent SQLite execution lease so that only the single authoritative
  /// engine can execute candle evaluations and trade mutations at any time.
  Future<bool> acquireExecutionLock({
    required String ownerId,
    required int nowMs,
    int leaseDurationMs = 55000,
  }) async {
    final db = await database;
    return db.transaction<bool>((txn) async {
      final rows = await txn.query(
        'execution_locks',
        where: 'lockName = ?',
        whereArgs: ['AUTHORITATIVE_ENGINE_LOCK'],
      );
      if (rows.isNotEmpty) {
        final currentOwner = rows.first['ownerId'] as String;
        final expiresAt = (rows.first['expiresAtMs'] as num).toInt();
        if (currentOwner != ownerId && expiresAt > nowMs) {
          return false;
        }
      }
      await txn.insert(
        'execution_locks',
        {
          'lockName': 'AUTHORITATIVE_ENGINE_LOCK',
          'ownerId': ownerId,
          'acquiredAtMs': nowMs,
          'expiresAtMs': nowMs + leaseDurationMs,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      return true;
    });
  }

  Future<void> releaseExecutionLock(String ownerId) async {
    final db = await database;
    await db.delete(
      'execution_locks',
      where: 'lockName = ? AND ownerId = ?',
      whereArgs: ['AUTHORITATIVE_ENGINE_LOCK', ownerId],
    );
  }

  Future<void> saveFullState({
    required PaperBroker broker,
    required BotEngineState botState,
    required Map<String, double> latestPrices,
    MarketDataStatus marketDataStatus = MarketDataStatus.connected,
    String statusBannerMessage = '',
    int? lastMarketDataUpdateMs,
    Map<String, StrategyEvaluationResult>? latestEvaluations,
  }) async {
    final db = await database;
    final nowMs = DateTime.now().toUtc().millisecondsSinceEpoch;
    broker.ensureUtcDayBaseline(nowMs, latestPrices);

    await db.transaction((txn) async {
      Future<void> putKv(String k, Object v) async {
        await txn.insert(
          'engine_kv_state',
          {'key': k, 'value': jsonEncode(v)},
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }

      await putKv('availableCashUsdt', broker.availableCashUsdt);
      await putKv('realizedPnlUsdt', broker.realizedPnlUsdt);
      await putKv('unrealizedPnlUsdt', broker.unrealizedPnl(latestPrices));
      await putKv('accountEquityUsdt', broker.accountEquity(latestPrices));
      await putKv('currentUtcDateKey', broker.currentUtcDateKey);
      await putKv('startOfDayEquityUsdt', broker.startOfDayEquityUsdt);
      await putKv('dailyStartEquityByUtcDate', broker.dailyStartEquityByUtcDate);
      await putKv('maxDrawdownLocked', broker.maxDrawdownLocked);
      await putKv(
          'pendingEmergencyLiquidation', broker.pendingEmergencyLiquidation);
      await putKv('lockedDailyLossUtcDate', broker.lockedDailyLossUtcDate ?? '');
      await putKv('botState', botState.name);
      await putKv('marketDataStatus', marketDataStatus.name);
      if (statusBannerMessage.isNotEmpty) {
        await putKv('statusBannerMessage', statusBannerMessage);
      }
      if (lastMarketDataUpdateMs != null) {
        await putKv('lastMarketDataUpdateMs', lastMarketDataUpdateMs);
      }
      await putKv('latestPrices', latestPrices);
      if (latestEvaluations != null) {
        final evalMap = <String, dynamic>{};
        latestEvaluations.forEach((k, v) {
          evalMap[k] = v.toMap();
        });
        await putKv('latestEvaluations', evalMap);
      }
      await putKv('strategyConfig', broker.strategyConfig.toMap());
      await putKv('riskConfig', broker.riskConfig.toMap());
      await putKv('dailyRealizedPnl', broker.dailyRealizedPnlByUtcDate);
      await putKv(
        'lastProcessedCandleCloseMs',
        broker.lastProcessedCandleCloseMs,
      );
      await putKv(
        'processedEntrySignalKeys',
        broker.processedEntrySignalKeys.toList(),
      );

      final serializedPending = <String, Map<String, dynamic>>{};
      broker.pendingSignalsBySymbol.forEach((sym, sig) {
        serializedPending[sym] = sig.toMap();
      });
      await putKv('pendingSignalsBySymbol', serializedPending);

      for (final sigKey in broker.processedEntrySignalKeys) {
        await txn.insert(
          'processed_signal_keys',
          {'signalKey': sigKey, 'processedAtMs': nowMs},
          conflictAlgorithm: ConflictAlgorithm.ignore,
        );
      }

      await txn.delete('open_positions');
      for (final pos in broker.openPositions.values) {
        await txn.insert(
          'open_positions',
          pos.toMap(),
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }

      for (final trade in broker.closedTrades) {
        await txn.insert(
          'closed_trades',
          trade.toMap(),
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }

      for (final order in broker.orderHistory) {
        await txn.insert(
          'orders',
          order.toMap(),
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }

      await txn.insert(
        'equity_snapshots',
        {
          'timestampMs': nowMs,
          'equityUsdt': broker.accountEquity(latestPrices),
          'availableCashUsdt': broker.availableCashUsdt,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    });
  }

  /// Restores state into `broker` and returns the full `PersistedEngineSnapshot`.
  /// CRITICAL: Never silently resets an existing account if a corrupt JSON or SQLite error occurs;
  /// any restoration error is thrown to the caller so the engine pauses safely without wiping state.
  Future<PersistedEngineSnapshot> restoreFullSnapshot(PaperBroker broker) async {
    final db = await database;
    final kvRows = await db.query('engine_kv_state');
    if (kvRows.isEmpty) {
      return const PersistedEngineSnapshot(
        botState: BotEngineState.stopped,
        marketDataStatus: MarketDataStatus.disconnected,
        statusBannerMessage: 'ENGINE STOPPED — PRESS START TO RUN PAPER BOT',
        latestPrices: {'BTCUSDT': 0.0, 'ETHUSDT': 0.0},
        latestEvaluations: {},
        tradeAlertsEnabled: true,
        notifiedAlertIds: {},
      );
    }

    final kv = <String, dynamic>{
      for (final r in kvRows)
        r['key'] as String: jsonDecode(r['value'] as String),
    };

    if (kv['strategyConfig'] is Map) {
      broker.strategyConfig = StrategyConfig.fromMap(
        Map<String, dynamic>.from(kv['strategyConfig'] as Map),
      );
    }
    if (kv['riskConfig'] is Map) {
      broker.riskConfig = RiskConfig.fromMap(
        Map<String, dynamic>.from(kv['riskConfig'] as Map),
      );
    }

    broker.availableCashUsdt =
        (kv['availableCashUsdt'] as num?)?.toDouble() ??
            broker.riskConfig.initialCapitalUsdt;
    broker.realizedPnlUsdt =
        (kv['realizedPnlUsdt'] as num?)?.toDouble() ?? 0.0;
    broker.currentUtcDateKey = (kv['currentUtcDateKey'] as String?) ?? '';
    broker.startOfDayEquityUsdt =
        (kv['startOfDayEquityUsdt'] as num?)?.toDouble() ??
            broker.riskConfig.initialCapitalUsdt;

    broker.dailyStartEquityByUtcDate.clear();
    if (kv['dailyStartEquityByUtcDate'] is Map) {
      (kv['dailyStartEquityByUtcDate'] as Map).forEach((k, v) {
        broker.dailyStartEquityByUtcDate[k.toString()] = (v as num).toDouble();
      });
    }

    broker.maxDrawdownLocked = (kv['maxDrawdownLocked'] as bool?) ?? false;
    broker.pendingEmergencyLiquidation =
        (kv['pendingEmergencyLiquidation'] as bool?) ?? false;
    final lockedDay = (kv['lockedDailyLossUtcDate'] as String?) ?? '';
    broker.lockedDailyLossUtcDate = lockedDay.isEmpty ? null : lockedDay;

    broker.dailyRealizedPnlByUtcDate.clear();
    if (kv['dailyRealizedPnl'] is Map) {
      (kv['dailyRealizedPnl'] as Map).forEach((k, v) {
        broker.dailyRealizedPnlByUtcDate[k.toString()] = (v as num).toDouble();
      });
    }

    broker.lastProcessedCandleCloseMs.clear();
    if (kv['lastProcessedCandleCloseMs'] is Map) {
      (kv['lastProcessedCandleCloseMs'] as Map).forEach((k, v) {
        broker.lastProcessedCandleCloseMs[k.toString()] = (v as num).toInt();
      });
    }

    broker.processedEntrySignalKeys.clear();
    if (kv['processedEntrySignalKeys'] is List) {
      for (final item in (kv['processedEntrySignalKeys'] as List)) {
        broker.processedEntrySignalKeys.add(item.toString());
      }
    }
    final sigKeyRows = await db.query('processed_signal_keys');
    for (final row in sigKeyRows) {
      broker.processedEntrySignalKeys.add(row['signalKey'] as String);
    }

    broker.pendingSignalsBySymbol.clear();
    if (kv['pendingSignalsBySymbol'] is Map) {
      (kv['pendingSignalsBySymbol'] as Map).forEach((k, v) {
        if (v is Map) {
          broker.pendingSignalsBySymbol[k.toString()] =
              PendingEntrySignal.fromMap(Map<String, dynamic>.from(v));
        }
      });
    }

    broker.openPositions.clear();
    final openRows = await db.query('open_positions');
    for (final row in openRows) {
      final pos = PaperPosition.fromMap(row);
      broker.openPositions[pos.symbol] = pos;
    }

    broker.closedTrades.clear();
    final tradeRows =
        await db.query('closed_trades', orderBy: 'closedAtMs DESC');
    for (final row in tradeRows) {
      broker.closedTrades.add(ClosedPaperTrade.fromMap(row));
    }

    broker.orderHistory.clear();
    final orderRows = await db.query('orders', orderBy: 'executedAtMs DESC');
    for (final row in orderRows) {
      broker.orderHistory.add(SimulatedOrder.fromMap(row));
    }

    final stateName = (kv['botState'] as String?) ?? BotEngineState.stopped.name;
    final botState = BotEngineState.values.firstWhere(
      (e) => e.name == stateName,
      orElse: () => BotEngineState.stopped,
    );

    final mktName = (kv['marketDataStatus'] as String?) ??
        MarketDataStatus.disconnected.name;
    final mktStatus = MarketDataStatus.values.firstWhere(
      (e) => e.name == mktName,
      orElse: () => MarketDataStatus.disconnected,
    );

    final banner = (kv['statusBannerMessage'] as String?) ??
        'ENGINE STOPPED — PRESS START TO RUN PAPER BOT';
    final lastUpdateMs = (kv['lastMarketDataUpdateMs'] as num?)?.toInt();

    final restoredPrices = <String, double>{
      'BTCUSDT': 0.0,
      'ETHUSDT': 0.0,
    };
    if (kv['latestPrices'] is Map) {
      (kv['latestPrices'] as Map).forEach((k, v) {
        restoredPrices[k.toString()] = (v as num).toDouble();
      });
    }

    final restoredEvals = <String, StrategyEvaluationResult>{};
    if (kv['latestEvaluations'] is Map) {
      (kv['latestEvaluations'] as Map).forEach((k, v) {
        if (v is Map) {
          restoredEvals[k.toString()] = StrategyEvaluationResult.fromMap(
            Map<String, dynamic>.from(v),
          );
        }
      });
    }

    final alertsEnabled = (kv['tradeAlertsEnabled'] as bool?) ?? true;
    final notifiedIds = <String>{};
    if (kv['notifiedAlertIds'] is List) {
      for (final item in (kv['notifiedAlertIds'] as List)) {
        notifiedIds.add(item.toString());
      }
    }

    return PersistedEngineSnapshot(
      botState: botState,
      marketDataStatus: mktStatus,
      statusBannerMessage: banner,
      lastMarketDataUpdateMs: lastUpdateMs,
      latestPrices: restoredPrices,
      latestEvaluations: restoredEvals,
      tradeAlertsEnabled: alertsEnabled,
      notifiedAlertIds: notifiedIds,
    );
  }

  Future<BotEngineState> restoreIntoBroker(PaperBroker broker) async {
    final snap = await restoreFullSnapshot(broker);
    return snap.botState;
  }

  Future<void> clearAllTables() async {
    final db = await database;
    final alertsEnabled = await getTradeAlertsEnabled();
    await db.delete('engine_kv_state');
    await db.delete('open_positions');
    await db.delete('closed_trades');
    await db.delete('orders');
    await db.delete('equity_snapshots');
    await db.delete('execution_locks');
    await db.delete('processed_signal_keys');
    await setTradeAlertsEnabled(alertsEnabled);
  }

  Future<void> close() async {
    await _db?.close();
    _db = null;
  }
}

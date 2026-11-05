import 'dart:convert';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';
import '../models/trading_models.dart';
import 'paper_broker.dart';

class PersistenceDatabase {
  Database? _db;

  Future<Database> get database async {
    if (_db != null) return _db!;
    final dbPath = await getDatabasesPath();
    final fullPath = p.join(dbPath, 'ankit_ai_trader_phase1.db');
    _db = await openDatabase(
      fullPath,
      version: 1,
      onCreate: _onCreate,
    );
    return _db!;
  }

  Future<void> openWithCustomDatabase(Database customDb) async {
    _db = customDb;
    await _onCreate(customDb, 1);
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
  }

  Future<void> saveFullState({
    required PaperBroker broker,
    required BotEngineState botState,
    required Map<String, double> latestPrices,
  }) async {
    final db = await database;
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
      await putKv('maxDrawdownLocked', broker.maxDrawdownLocked);
      await putKv('lockedDailyLossUtcDate', broker.lockedDailyLossUtcDate ?? '');
      await putKv('botState', botState.name);
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

      final nowMs = DateTime.now().toUtc().millisecondsSinceEpoch;
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

  Future<BotEngineState> restoreIntoBroker(PaperBroker broker) async {
    final db = await database;
    final kvRows = await db.query('engine_kv_state');
    if (kvRows.isEmpty) {
      return BotEngineState.stopped;
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
    broker.maxDrawdownLocked = (kv['maxDrawdownLocked'] as bool?) ?? false;
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
    return BotEngineState.values.firstWhere(
      (e) => e.name == stateName,
      orElse: () => BotEngineState.stopped,
    );
  }

  Future<void> clearAllTables() async {
    final db = await database;
    await db.delete('engine_kv_state');
    await db.delete('open_positions');
    await db.delete('closed_trades');
    await db.delete('orders');
    await db.delete('equity_snapshots');
  }

  Future<void> close() async {
    await _db?.close();
    _db = null;
  }
}
import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:ankit_ai_trader/models/trading_models.dart';
import 'package:ankit_ai_trader/services/authoritative_engine.dart';
import 'package:ankit_ai_trader/services/coindcx_market_service.dart';
import 'package:ankit_ai_trader/services/indicator_engine.dart';
import 'package:ankit_ai_trader/services/paper_broker.dart';
import 'package:ankit_ai_trader/services/persistence_db.dart';
import 'package:ankit_ai_trader/services/risk_manager.dart';
import 'package:ankit_ai_trader/services/strategy_engine.dart';
import 'package:ankit_ai_trader/services/trade_alert_formatter.dart';
import 'package:ankit_ai_trader/services/trading_coordinator.dart';

class FakeEngineCommandBridge implements EngineCommandBridge {
  final AuthoritativeTradingEngine? engine;
  final bool serviceStartsSuccessfully;
  final bool dartEngineInitializesSuccessfully;
  final bool throwPlatformExceptionOnStart;

  FakeEngineCommandBridge({
    this.engine,
    this.serviceStartsSuccessfully = true,
    this.dartEngineInitializesSuccessfully = true,
    this.throwPlatformExceptionOnStart = false,
  });

  @override
  Future<bool> ensureServiceStartedAndReady() async {
    if (throwPlatformExceptionOnStart) {
      throw PlatformException(
        code: 'SERVICE_START_FAILED',
        message: 'Android foreground service rejected start',
      );
    }
    return serviceStartsSuccessfully && dartEngineInitializesSuccessfully;
  }

  @override
  Future<bool> dispatchCommand(String command) async {
    if (!serviceStartsSuccessfully ||
        !dartEngineInitializesSuccessfully ||
        engine == null) {
      return false;
    }
    return await engine!.handleCommand(command);
  }

  @override
  Future<void> notifyNetworkChanged(bool isConnected) async {
    if (engine != null &&
        serviceStartsSuccessfully &&
        dartEngineInitializesSuccessfully) {
      await engine!.handleNetworkTransition(isConnected);
    }
  }

  @override
  Future<bool> isServiceAndEngineReady() async {
    return serviceStartsSuccessfully && dartEngineInitializesSuccessfully;
  }
}

List<Candle> buildContiguousCandles({
  required String symbol,
  required String interval,
  required int startOpenMs,
  required int count,
  required double Function(int index) closeBuilder,
}) {
  final step = CoinDcxMarketService.intervalDurationMs(interval);
  return List<Candle>.generate(count, (i) {
    final openMs = startOpenMs + (i * step);
    final c = closeBuilder(i);
    return Candle(
      symbol: symbol,
      interval: interval,
      openTimeMs: openMs,
      closeTimeMs: openMs + step,
      open: c - 0.2,
      high: c + 1.5,
      low: c - 1.5,
      close: c,
      volume: 25.0,
    );
  });
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  group('Phase 1 Final Verification — 21 Deterministic Tests', () {
    test('Test 1: Single authoritative engine enforcement via SQLite execution lease lock', () async {
      final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
      final persistence = PersistenceDatabase();
      await persistence.openWithCustomDatabase(db);

      const nowMs = 1700000000000;
      final lock1 = await persistence.acquireExecutionLock(
        ownerId: 'ENGINE_A',
        nowMs: nowMs,
        leaseDurationMs: 60000,
      );
      expect(lock1, isTrue);

      // Competing engine B cannot acquire the lock while ENGINE_A holds an active lease
      final lock2 = await persistence.acquireExecutionLock(
        ownerId: 'ENGINE_B',
        nowMs: nowMs + 1000,
        leaseDurationMs: 60000,
      );
      expect(lock2, isFalse);

      // Once ENGINE_A releases the lock, ENGINE_B can acquire it
      await persistence.releaseExecutionLock('ENGINE_A');
      final lock3 = await persistence.acquireExecutionLock(
        ownerId: 'ENGINE_B',
        nowMs: nowMs + 2000,
        leaseDurationMs: 60000,
      );
      expect(lock3, isTrue);

      await persistence.close();
    });

    test('Test 2: Duplicate execution prevention on repeated candle callbacks & signal keys', () {
      final broker = PaperBroker();
      const baseMs = 1700000000000;
      final candles15m = buildContiguousCandles(
        symbol: 'BTCUSDT',
        interval: '15m',
        startOpenMs: baseMs,
        count: 60,
        closeBuilder: (i) => 100.0 + i * 0.5,
      );
      final candles1h = buildContiguousCandles(
        symbol: 'BTCUSDT',
        interval: '1h',
        startOpenMs: baseMs - (60 * 3600000),
        count: 75,
        closeBuilder: (i) => 90.0 + i * 0.5,
      );

      // First call warms up and sets checkpoint at candles15m.last.closeTimeMs
      final first = broker.processClosedCandleStream(
        symbol: 'BTCUSDT',
        closed15m: candles15m,
        closed1h: candles1h,
        latestPrices: {},
      );
      expect(first.evaluations.first.description, contains('WARM-UP COMPLETE'));

      // Repeated call with identical candles processes 0 new candles
      final second = broker.processClosedCandleStream(
        symbol: 'BTCUSDT',
        closed15m: candles15m,
        closed1h: candles1h,
        latestPrices: {},
      );
      expect(second.evaluations.first.description, 'NO NEW CLOSED 15M CANDLES');
      expect(broker.orderHistory, isEmpty);
    });

    test('Test 3: Fresh-account historical warm-up establishes checkpoint without generating historical trades', () {
      final broker = PaperBroker();
      const baseMs = 1700000000000;
      final candles1h = buildContiguousCandles(
        symbol: 'BTCUSDT',
        interval: '1h',
        startOpenMs: baseMs - (80 * 3600000),
        count: 100,
        closeBuilder: (i) => 100.0 + i * 1.0,
      );
      // Construct 15m series that has a crossover inside historical bars
      final candles15m = buildContiguousCandles(
        symbol: 'BTCUSDT',
        interval: '15m',
        startOpenMs: baseMs,
        count: 80,
        closeBuilder: (i) => i < 55 ? 120.0 - i * 0.2 : 109.0 + (i - 55) * 0.6,
      );

      final outcome = broker.processClosedCandleStream(
        symbol: 'BTCUSDT',
        closed15m: candles15m,
        closed1h: candles1h,
        latestPrices: {},
        allowHistoricalWarmupTrades: false,
      );

      expect(outcome.pausedOnMissingNextCandle, isFalse);
      expect(broker.openPositions, isEmpty);
      expect(broker.closedTrades, isEmpty);
      expect(broker.pendingSignalsBySymbol, isEmpty);
      expect(
        broker.lastProcessedCandleCloseMs['BTCUSDT'],
        candles15m.last.closeTimeMs,
      );
    });

    test('Test 4: Sequential candle processing evaluates multiple new contiguous 15m candles in chronological order', () {
      final broker = PaperBroker();
      const baseMs = 1700000000000;
      final all15m = buildContiguousCandles(
        symbol: 'BTCUSDT',
        interval: '15m',
        startOpenMs: baseMs,
        count: 65,
        closeBuilder: (i) => 100.0 + i * 0.2,
      );
      final all1h = buildContiguousCandles(
        symbol: 'BTCUSDT',
        interval: '1h',
        startOpenMs: baseMs - (60 * 3600000),
        count: 80,
        closeBuilder: (i) => 95.0 + i * 0.5,
      );

      // Warm up on first 60 candles
      broker.processClosedCandleStream(
        symbol: 'BTCUSDT',
        closed15m: all15m.sublist(0, 60),
        closed1h: all1h,
        latestPrices: {},
      );

      // Now feed 5 new contiguous closed candles (indices 60..64)
      final outcome = broker.processClosedCandleStream(
        symbol: 'BTCUSDT',
        closed15m: all15m,
        closed1h: all1h,
        latestPrices: {},
      );

      expect(outcome.pausedOnMissingNextCandle, isFalse);
      expect(outcome.evaluations.length, 5);
      expect(
        broker.lastProcessedCandleCloseMs['BTCUSDT'],
        all15m.last.closeTimeMs,
      );
    });

    test('Test 5: Immediate next-candle entry executes BUY at open of C+1 with configured slippage & fees', () {
      final broker = PaperBroker();
      const signalCloseMs = 1700054000000;
      broker.lastProcessedCandleCloseMs['BTCUSDT'] = signalCloseMs;
      broker.pendingSignalsBySymbol['BTCUSDT'] = const PendingEntrySignal(
        symbol: 'BTCUSDT',
        signalCandleCloseMs: signalCloseMs,
        atr14: 2.0,
        rsi14: 58.0,
        ema20: 105.0,
        ema50: 104.0,
      );

      final candles15m = buildContiguousCandles(
        symbol: 'BTCUSDT',
        interval: '15m',
        startOpenMs: signalCloseMs - (59 * 900000),
        count: 61, // index 60 opens at signalCloseMs (C+1)
        closeBuilder: (i) => 100.0 + i * 0.1,
      );
      final candles1h = buildContiguousCandles(
        symbol: 'BTCUSDT',
        interval: '1h',
        startOpenMs: signalCloseMs - (60 * 3600000),
        count: 65,
        closeBuilder: (i) => 100.0 + i * 0.2,
      );

      final nextCandleOpen = candles15m
          .firstWhere((c) => c.openTimeMs == signalCloseMs)
          .open;
      final outcome = broker.processClosedCandleStream(
        symbol: 'BTCUSDT',
        closed15m: candles15m,
        closed1h: candles1h,
        latestPrices: {},
      );

      expect(outcome.pausedOnMissingNextCandle, isFalse);
      expect(broker.openPositions.containsKey('BTCUSDT'), isTrue);
      final pos = broker.openPositions['BTCUSDT']!;
      expect(
        pos.entryPrice,
        closeTo(nextCandleOpen * (1.0 + broker.riskConfig.slippageRate), 1e-6),
      );
      expect(pos.openedAtMs, signalCloseMs);
    });

    test('Test 6: Missing next candle C+1 discards stale pending signal and pauses safely without executing at C+2', () {
      final broker = PaperBroker();
      const signalCloseMs = 1700054000000;
      broker.lastProcessedCandleCloseMs['BTCUSDT'] = signalCloseMs;
      broker.pendingSignalsBySymbol['BTCUSDT'] = const PendingEntrySignal(
        symbol: 'BTCUSDT',
        signalCandleCloseMs: signalCloseMs,
        atr14: 2.0,
        rsi14: 58.0,
        ema20: 105.0,
        ema50: 104.0,
      );

      final history = buildContiguousCandles(
        symbol: 'BTCUSDT',
        interval: '15m',
        startOpenMs: signalCloseMs - (60 * 900000),
        count: 60,
        closeBuilder: (i) => 100.0,
      );
      // C+1 (opening at signalCloseMs) is missing; next available candle opens at signalCloseMs + 900000 (C+2)
      const cPlus2 = Candle(
        symbol: 'BTCUSDT',
        interval: '15m',
        openTimeMs: signalCloseMs + 900000,
        closeTimeMs: signalCloseMs + 1800000,
        open: 101.0,
        high: 102.0,
        low: 100.0,
        close: 101.5,
        volume: 15.0,
      );

      final outcome = broker.processClosedCandleStream(
        symbol: 'BTCUSDT',
        closed15m: [...history, cPlus2],
        closed1h: const [],
        latestPrices: {},
      );

      expect(outcome.pausedOnMissingNextCandle, isTrue);
      expect(broker.pendingSignalsBySymbol.containsKey('BTCUSDT'), isFalse);
      expect(broker.openPositions.isEmpty, isTrue);
    });

    test('Test 7: Pending entry signal and processed checkpoints persist and restore atomically in SQLite', () async {
      final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
      final persistence = PersistenceDatabase();
      await persistence.openWithCustomDatabase(db);

      final broker1 = PaperBroker();
      broker1.lastProcessedCandleCloseMs['BTCUSDT'] = 1700000900000;
      broker1.pendingSignalsBySymbol['BTCUSDT'] = const PendingEntrySignal(
        symbol: 'BTCUSDT',
        signalCandleCloseMs: 1700000900000,
        atr14: 2.25,
        rsi14: 59.5,
        ema20: 105.0,
        ema50: 103.5,
      );

      await persistence.saveFullState(
        broker: broker1,
        botState: BotEngineState.running,
        latestPrices: const {'BTCUSDT': 105.0},
      );

      final broker2 = PaperBroker();
      final snap = await persistence.restoreFullSnapshot(broker2);
      expect(snap.botState, BotEngineState.running);
      expect(broker2.lastProcessedCandleCloseMs['BTCUSDT'], 1700000900000);
      expect(broker2.pendingSignalsBySymbol['BTCUSDT']?.atr14, closeTo(2.25, 1e-6));

      await persistence.close();
    });

    test('Test 8: Both 15m and 1h timeframe freshness checks detect stale data', () {
      const nowMs = 1700020000000;
      final fresh15m = [
        const Candle(
          symbol: 'BTCUSDT',
          interval: '15m',
          openTimeMs: nowMs - 1800000,
          closeTimeMs: nowMs - 900000,
          open: 100,
          high: 101,
          low: 99,
          close: 100,
          volume: 10,
        ),
      ];
      final stale15m = [
        const Candle(
          symbol: 'BTCUSDT',
          interval: '15m',
          openTimeMs: nowMs - 5000000,
          closeTimeMs: nowMs - 4100000, // > 2.5 * 15m old
          open: 100,
          high: 101,
          low: 99,
          close: 100,
          volume: 10,
        ),
      ];
      final stale1h = [
        const Candle(
          symbol: 'BTCUSDT',
          interval: '1h',
          openTimeMs: nowMs - 15000000,
          closeTimeMs: nowMs - 11400000, // > 2.5 * 1h old
          open: 100,
          high: 101,
          low: 99,
          close: 100,
          volume: 10,
        ),
      ];

      expect(
        CoinDcxMarketService.isDataStale(
          closedCandles: fresh15m,
          interval: '15m',
          nowMs: nowMs,
        ),
        isFalse,
      );
      expect(
        CoinDcxMarketService.isDataStale(
          closedCandles: stale15m,
          interval: '15m',
          nowMs: nowMs,
        ),
        isTrue,
      );
      expect(
        CoinDcxMarketService.isDataStale(
          closedCandles: stale1h,
          interval: '1h',
          nowMs: nowMs,
        ),
        isTrue,
      );
    });

    test('Test 9: Both 15m and 1h timeframe missing-candle gap checks detect non-contiguous bars', () {
      const baseMs = 1700000000000;
      final contiguous15m = buildContiguousCandles(
        symbol: 'BTCUSDT',
        interval: '15m',
        startOpenMs: baseMs,
        count: 6,
        closeBuilder: (_) => 100.0,
      );
      final gapped15m = [
        contiguous15m[0],
        contiguous15m[1],
        contiguous15m[3], // missing index 2
        contiguous15m[4],
      ];

      final contiguous1h = buildContiguousCandles(
        symbol: 'BTCUSDT',
        interval: '1h',
        startOpenMs: baseMs,
        count: 6,
        closeBuilder: (_) => 100.0,
      );
      final gapped1h = [
        contiguous1h[0],
        contiguous1h[2], // missing index 1
        contiguous1h[3],
      ];

      expect(
        CoinDcxMarketService.hasRecentMissingCandleGap(
          closedCandles: contiguous15m,
          interval: '15m',
        ),
        isFalse,
      );
      expect(
        CoinDcxMarketService.hasRecentMissingCandleGap(
          closedCandles: gapped15m,
          interval: '15m',
        ),
        isTrue,
      );
      expect(
        CoinDcxMarketService.hasRecentMissingCandleGap(
          closedCandles: gapped1h,
          interval: '1h',
        ),
        isTrue,
      );
    });

    test('Test 10: Realized plus unrealized daily loss against start-of-day baseline triggers \$2 daily lock', () {
      final broker = PaperBroker();
      const day1Ms = 1700006400000; // 2023-11-15 UTC
      broker.ensureUtcDayBaseline(day1Ms, const {'BTCUSDT': 100.0});
      expect(broker.startOfDayEquityUsdt, closeTo(100.0, 1e-6));

      // Simulate -$1.10 realized loss and open a position with -$0.95 unrealized loss (total -$2.05)
      broker.availableCashUsdt = 48.90;
      broker.realizedPnlUsdt = -1.10;
      broker.dailyRealizedPnlByUtcDate[RiskManager.utcDayKey(day1Ms)] = -1.10;
      broker.openPositions['BTCUSDT'] = const PaperPosition(
        id: 'POS-1',
        symbol: 'BTCUSDT',
        entryPrice: 100.0,
        quantity: 0.50, // cost 50.0
        stopLoss: 94.0,
        takeProfit: 112.0,
        entryFeeUsdt: 0.05,
        signalCandleCloseMs: day1Ms - 900000,
        openedAtMs: day1Ms,
      );

      // Mark price 98.2 -> gross 49.1 -> net ~49.05 -> total equity ~97.95 (-$2.05 vs $100 start of day)
      final locked = broker.isDailyLockedAt(day1Ms, const {'BTCUSDT': 98.2});
      expect(locked, isTrue);
      expect(broker.lockedDailyLossUtcDate, RiskManager.utcDayKey(day1Ms));
    });

    test('Test 11: Daily UTC reset with an open position carried across midnight establishes new baseline without resetting \$100 account', () {
      final broker = PaperBroker();
      const day1Ms = 1700006400000; // 2023-11-15 00:00 UTC
      const day2Ms = day1Ms + 86400000; // 2023-11-16 00:00 UTC

      // Day 1: lock reached at equity $97.90 with open position
      broker.availableCashUsdt = 47.90;
      broker.openPositions['BTCUSDT'] = const PaperPosition(
        id: 'POS-CARRY',
        symbol: 'BTCUSDT',
        entryPrice: 100.0,
        quantity: 0.50,
        stopLoss: 94.0,
        takeProfit: 112.0,
        entryFeeUsdt: 0.05,
        signalCandleCloseMs: day1Ms - 900000,
        openedAtMs: day1Ms,
      );
      broker.ensureUtcDayBaseline(day1Ms, const {'BTCUSDT': 102.0});
      broker.lockedDailyLossUtcDate = RiskManager.utcDayKey(day1Ms);

      // Cross midnight into Day 2 with BTC at 100.0 (equity ~ $97.85)
      final lockedOnDay2 =
          broker.isDailyLockedAt(day2Ms, const {'BTCUSDT': 100.0});
      expect(lockedOnDay2, isFalse);
      expect(broker.currentUtcDateKey, RiskManager.utcDayKey(day2Ms));
      expect(
        broker.startOfDayEquityUsdt,
        closeTo(broker.accountEquity(const {'BTCUSDT': 100.0}), 1e-6),
      );
      expect(broker.openPositions.containsKey('BTCUSDT'), isTrue);
    });

    test('Test 12: Continued SL/TP management during daily loss lock closes position when stop-loss or take-profit is hit', () {
      final broker = PaperBroker();
      const t0 = 1700006400000;
      broker.lastProcessedCandleCloseMs['BTCUSDT'] = t0;
      broker.lockedDailyLossUtcDate = RiskManager.utcDayKey(t0);
      broker.availableCashUsdt = 48.0;
      broker.openPositions['BTCUSDT'] = const PaperPosition(
        id: 'POS-LOCKED-MANAGE',
        symbol: 'BTCUSDT',
        entryPrice: 100.0,
        quantity: 0.50,
        stopLoss: 97.0,
        takeProfit: 106.0,
        entryFeeUsdt: 0.05,
        signalCandleCloseMs: t0 - 900000,
        openedAtMs: t0,
      );

      final history = buildContiguousCandles(
        symbol: 'BTCUSDT',
        interval: '15m',
        startOpenMs: t0 - (60 * 900000),
        count: 60,
        closeBuilder: (_) => 100.0,
      );
      // Next closed candle hits Take-Profit (106.5 >= 106.0) while daily lock is active
      const tpCandle = Candle(
        symbol: 'BTCUSDT',
        interval: '15m',
        openTimeMs: t0,
        closeTimeMs: t0 + 900000,
        open: 100.5,
        high: 106.5,
        low: 100.0,
        close: 106.2,
        volume: 30.0,
      );

      broker.processClosedCandleStream(
        symbol: 'BTCUSDT',
        closed15m: [...history, tpCandle],
        closed1h: const [],
        latestPrices: {},
      );

      expect(broker.openPositions.isEmpty, isTrue);
      expect(broker.closedTrades.first.exitReason, 'TAKE_PROFIT');
    });

    test('Test 13: \$90 maximum drawdown protection liquidates with valid price or sets pendingEmergencyLiquidation if price unavailable', () {
      final broker = PaperBroker();
      const nowMs = 1700006400000;
      broker.availableCashUsdt = 40.0;
      broker.openPositions['BTCUSDT'] = const PaperPosition(
        id: 'POS-DD',
        symbol: 'BTCUSDT',
        entryPrice: 100.0,
        quantity: 0.50,
        stopLoss: 90.0,
        takeProfit: 120.0,
        entryFeeUsdt: 0.05,
        signalCandleCloseMs: nowMs - 900000,
        openedAtMs: nowMs,
      );

      // 1) If equity <= $90 with a valid market quote, lock immediately & liquidate
      broker.availableCashUsdt = 39.0;
      broker.enforceMaxDrawdownCheck(nowMs, const {'BTCUSDT': 98.0});
      expect(broker.maxDrawdownLocked, isTrue);
      expect(broker.openPositions.isEmpty, isTrue);
      expect(
        broker.closedTrades.first.exitReason,
        'MAX_DRAWDOWN_EMERGENCY_LIQUIDATION',
      );

      // 2) Test when valid market price is unavailable (empty map) when drawdown is reached
      final brokerNoQuote = PaperBroker();
      brokerNoQuote.availableCashUsdt = 39.0;
      brokerNoQuote.openPositions['BTCUSDT'] = const PaperPosition(
        id: 'POS-NO-QUOTE',
        symbol: 'BTCUSDT',
        entryPrice: 100.0,
        quantity: 0.50,
        stopLoss: 90.0,
        takeProfit: 120.0,
        entryFeeUsdt: 0.05,
        signalCandleCloseMs: nowMs - 900000,
        openedAtMs: nowMs,
      );
      brokerNoQuote.enforceMaxDrawdownCheck(nowMs, const {});
      expect(brokerNoQuote.maxDrawdownLocked, isTrue);
      expect(brokerNoQuote.pendingEmergencyLiquidation, isTrue);
      expect(brokerNoQuote.openPositions.isNotEmpty, isTrue);
    });

    test('Test 14: Position sizing caps risk at \$1 (1%), accounts for fees & slippage, and rejects oversized minNotional', () {
      const riskCfg = RiskConfig(
        initialCapitalUsdt: 100.0,
        maxRiskPerTradeFraction: 0.01,
        feeRate: 0.001,
        slippageRate: 0.0005,
      );
      const rm = RiskManager(config: riskCfg);
      const strat = StrategyConfig();

      final approved = rm.evaluateEntryAndSize(
        rawNextOpenPrice: 100.0,
        atr14: 2.0,
        strategyConfig: strat,
        availableCashUsdt: 100.0,
        currentEquityUsdt: 100.0,
        startOfDayEquityUsdt: 100.0,
        todayRealizedPnlUsdt: 0.0,
        todayUnrealizedPnlUsdt: 0.0,
        currentOpenPositionsCount: 0,
      );

      expect(approved.approved, isTrue);
      expect(approved.estimatedRiskUsdt <= 1.000001, isTrue);
      expect(
        approved.estimatedNotionalUsdt + approved.estimatedEntryFeeUsdt <= 100.0,
        isTrue,
      );

      final rejected = rm.evaluateEntryAndSize(
        rawNextOpenPrice: 100.0,
        atr14: 2.0,
        strategyConfig: strat,
        availableCashUsdt: 100.0,
        currentEquityUsdt: 100.0,
        startOfDayEquityUsdt: 100.0,
        todayRealizedPnlUsdt: 0.0,
        todayUnrealizedPnlUsdt: 0.0,
        currentOpenPositionsCount: 0,
        minNotionalUsdt: 95.0,
      );
      expect(rejected.approved, isFalse);
    });

    test('Test 15: Conservative SL/TP execution selects Stop-Loss when both levels are touched in the same candle', () {
      const engine = StrategyEngine();
      const pos = PaperPosition(
        id: 'POS-1',
        symbol: 'BTCUSDT',
        entryPrice: 100.0,
        quantity: 0.25,
        stopLoss: 97.0,
        takeProfit: 106.0,
        entryFeeUsdt: 0.025,
        signalCandleCloseMs: 1000,
        openedAtMs: 1000,
      );

      const dualTouchCandle = Candle(
        symbol: 'BTCUSDT',
        interval: '15m',
        openTimeMs: 2000,
        closeTimeMs: 3000,
        open: 100.0,
        high: 108.0,
        low: 96.0,
        close: 105.0,
        volume: 10.0,
      );

      final decision = engine.checkStopLossOrTakeProfit(
        position: pos,
        candle: dualTouchCandle,
      );
      expect(decision.shouldExit, isTrue);
      expect(decision.exitReferencePrice, closeTo(97.0, 1e-6));
      expect(decision.reason, 'STOP_LOSS_CONSERVATIVE_BOTH_TOUCHED');
    });

    test('Test 16: SQLite restoration after restart preserves account, orders, trades, and requires manual START', () async {
      final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
      final persistence = PersistenceDatabase();
      await persistence.openWithCustomDatabase(db);

      final broker1 = PaperBroker();
      broker1.availableCashUsdt = 96.40;
      broker1.realizedPnlUsdt = -3.60;
      broker1.orderHistory.add(
        const SimulatedOrder(
          id: 'ORD-1',
          symbol: 'BTCUSDT',
          side: 'BUY',
          requestedPrice: 50000.0,
          executedPrice: 50025.0,
          quantity: 0.001,
          notionalUsdt: 50.025,
          feeUsdt: 0.05,
          signalCandleCloseMs: 1700000000000,
          executedAtMs: 1700000900000,
          reason: 'SIGNAL_NEXT_OPEN_ENTRY',
        ),
      );

      await persistence.saveFullState(
        broker: broker1,
        botState: BotEngineState.running,
        latestPrices: const {'BTCUSDT': 50000.0},
      );

      final coordinator = TradingCoordinator(
        persistence: persistence,
        commandBridge: FakeEngineCommandBridge(
          serviceStartsSuccessfully: false,
          dartEngineInitializesSuccessfully: false,
        ),
        customInternetProbe: () async => true,
      );
      await coordinator.initialize(enablePlatformChannels: false);

      expect(coordinator.broker.availableCashUsdt, closeTo(96.40, 1e-6));
      expect(coordinator.broker.orderHistory.length, 1);
      expect(
        coordinator.engineState,
        BotEngineState.pausedAfterRecoveryManualStartRequired,
      );

      await persistence.close();
    });

    test('Test 17: Internet loss pauses authoritative engine and automatic reconnection requires manual START (via real MethodChannelEngineBridge)', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
      final persistence = PersistenceDatabase();
      await persistence.openWithCustomDatabase(db);

      final nowMs = DateTime.now().toUtc().millisecondsSinceEpoch;
      final mockClient = MockClient((request) async {
        if (request.url.toString().contains('markets_details')) {
          return http.Response(
            jsonEncode([
              {
                'symbol': 'BTCUSDT',
                'pair': 'B-BTC_USDT',
                'status': 'active',
                'base_currency_short_name': 'USDT',
                'target_currency_short_name': 'BTC',
                'min_notional': 1.0,
                'min_quantity': 0.0001,
              },
              {
                'symbol': 'ETHUSDT',
                'pair': 'B-ETH_USDT',
                'status': 'active',
                'base_currency_short_name': 'USDT',
                'target_currency_short_name': 'ETH',
                'min_notional': 1.0,
                'min_quantity': 0.001,
              },
            ]),
            200,
          );
        }
        if (request.url.toString().contains('/exchange/ticker')) {
          return http.Response(jsonEncode([]), 200);
        }
        final is1h = request.url.queryParameters['interval'] == '1h';
        final step = is1h ? 3600000 : 900000;
        final baseOpen = ((nowMs ~/ step) - 65) * step;
        final list = List.generate(65, (i) {
          final t = baseOpen + (i * step);
          return {
            'time': t,
            'open': 50000 + i * 10,
            'high': 50050 + i * 10,
            'low': 49950 + i * 10,
            'close': 50020 + i * 10,
            'volume': 12.5,
          };
        });
        return http.Response(jsonEncode(list), 200);
      });

      final mktService = CoinDcxMarketService(client: mockClient);
      final authEngine = AuthoritativeTradingEngine(
        marketService: mktService,
        persistence: persistence,
      );

      // Wire the real MethodChannelEngineBridge ('com.ankit.aitrader/service')
      const serviceChannel = MethodChannel('com.ankit.aitrader/service');
      final recordedMethodCalls = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(serviceChannel, (MethodCall call) async {
        recordedMethodCalls.add(call.method);
        switch (call.method) {
          case 'startService':
            return true;
          case 'isServiceRunning':
            return true;
          case 'dispatchCommand':
            final cmd = (call.arguments as Map?)?['command']?.toString() ?? '';
            return await authEngine.handleCommand(cmd, nowOverrideMs: nowMs);
          case 'notifyNetworkChanged':
            final connected =
                (call.arguments as Map?)?['connected'] as bool? ?? true;
            await authEngine.handleNetworkTransition(
              connected,
              nowOverrideMs: nowMs,
            );
            return true;
          default:
            return true;
        }
      });

      final realBridge = MethodChannelEngineBridge();
      final coordinator = TradingCoordinator(
        marketService: mktService,
        persistence: persistence,
        commandBridge: realBridge,
        customInternetProbe: () async => true,
      );
      await coordinator.initialize(enablePlatformChannels: false);
      await coordinator.manualStartBot();
      expect(coordinator.engineState, BotEngineState.running);
      expect(recordedMethodCalls, contains('startService'));
      expect(recordedMethodCalls, contains('dispatchCommand'));

      // Internet lost -> routed through real MethodChannelEngineBridge.notifyNetworkChanged(false)
      await coordinator.handleConnectivityTransition(false);
      expect(recordedMethodCalls, contains('notifyNetworkChanged'));
      expect(coordinator.engineState, BotEngineState.pausedNetworkLoss);

      // Internet recovered -> must remain paused until manual START
      await coordinator.handleConnectivityTransition(true);
      expect(
        coordinator.engineState,
        BotEngineState.pausedAfterRecoveryManualStartRequired,
      );

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(serviceChannel, null);
      await persistence.close();
    });

    test('Test 18: Background engine initialization failure prevents dashboard from reporting RUNNING or starting a fallback engine', () async {
      final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
      final persistence = PersistenceDatabase();
      await persistence.openWithCustomDatabase(db);

      final bridge = FakeEngineCommandBridge(
        serviceStartsSuccessfully: true,
        dartEngineInitializesSuccessfully: false,
      );
      final coordinator = TradingCoordinator(
        persistence: persistence,
        commandBridge: bridge,
        customInternetProbe: () async => true,
      );
      await coordinator.initialize(enablePlatformChannels: false);
      await coordinator.manualStartBot();

      expect(coordinator.foregroundServiceActive, isFalse);
      expect(coordinator.engineState, BotEngineState.stopped);
      expect(
        coordinator.statusBannerMessage,
        contains('BACKGROUND ENGINE DID NOT ACKNOWLEDGE READY'),
      );

      await persistence.close();
    });

    test('Test 19: Foreground service startup failure surfaces PlatformException error and keeps engine stopped', () async {
      final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
      final persistence = PersistenceDatabase();
      await persistence.openWithCustomDatabase(db);

      final bridge = FakeEngineCommandBridge(
        throwPlatformExceptionOnStart: true,
      );
      final coordinator = TradingCoordinator(
        persistence: persistence,
        commandBridge: bridge,
        customInternetProbe: () async => true,
      );
      await coordinator.initialize(enablePlatformChannels: false);
      await coordinator.manualStartBot();

      expect(coordinator.foregroundServiceActive, isFalse);
      expect(coordinator.engineState, BotEngineState.stopped);
      expect(coordinator.statusBannerMessage, contains('SERVICE START ERROR'));

      await persistence.close();
    });

    test('Test 20: Historical backtest calculation correctness over deterministic bullish crossover dataset', () {
      const baseTime = 1700000000000;
      final candles1h = buildContiguousCandles(
        symbol: 'BTCUSDT',
        interval: '1h',
        startOpenMs: baseTime - (60 * 3600000),
        count: 150,
        closeBuilder: (i) => 100.0 + i * 0.8,
      );

      final candles15m = buildContiguousCandles(
        symbol: 'BTCUSDT',
        interval: '15m',
        startOpenMs: baseTime,
        count: 240,
        closeBuilder: (i) {
          if (i < 40) return 100.0 + (i.isEven ? 0.2 : -0.2);
          if (i < 55) return 99.5 - (i - 40) * 0.05 + (i.isEven ? 0.15 : -0.15);
          if (i < 75) {
            final step = i - 55;
            return 99.0 + step * 0.12 + (i.isEven ? 0.18 : -0.14);
          }
          if (i < 110) return 101.5 + (i - 75) * 0.35;
          return 113.0 + (i - 110) * 0.05;
        },
      );

      final report = PaperBroker.runHistoricalBacktest(
        symbol: 'BTCUSDT',
        candles15m: candles15m,
        candles1h: candles1h,
      );

      expect(report.totalTrades, greaterThan(0));
      expect(report.winningTrades, greaterThan(0));
      expect(report.netPnlUsdt, greaterThan(0.0));
      expect(report.profitFactor, greaterThan(1.0));
      expect(report.endingEquityUsdt, closeTo(100.0 + report.netPnlUsdt, 1e-6));
      expect(report.maxDrawdownUsdt >= 0.0, isTrue);
      expect(report.winRatePercent >= 0.0 && report.winRatePercent <= 100.0, isTrue);
    });

    test('Test 21: Technical indicators (EMA 20/50, RSI 14, ATR 14) mathematical verification including post-seed recursion', () {
      // 1. EMA seed + post-seed recursion with non-linear jump after seed
      final prices = List<double>.generate(60, (i) {
        if (i < 20) return 100.0 + i * 2.0; // indices 0..19 -> SMA20 seed = 119.0
        if (i == 20) return 150.0; // non-linear jump to test EMA recursion
        if (i == 21) return 160.0;
        return 100.0 + i * 2.0;
      });
      final ema20 = IndicatorEngine.calculateEmaSeries(prices, 20);
      expect(ema20[18], isNull);
      expect(ema20[19], closeTo(119.0, 1e-6)); // seed
      // Recursion step 1: (150.0 - 119.0) * (2/21) + 119.0 = 121.95238095238095
      expect(ema20[20], closeTo(121.95238095, 1e-6));
      // Recursion step 2: (160.0 - 121.95238095238095) * (2/21) + 121.95238095238095 = 125.57596372
      expect(ema20[21], closeTo(125.57596372, 1e-6));

      final linear50 = List<double>.generate(55, (i) => 100.0 + i * 2.0);
      linear50[50] = 250.0; // jump right after EMA50 seed (149.0)
      final ema50 = IndicatorEngine.calculateEmaSeries(linear50, 50);
      expect(ema50[49], closeTo(149.0, 1e-6)); // seed
      // Recursion: (250.0 - 149.0) * (2/51) + 149.0 = 152.9607843137255
      expect(ema50[50], closeTo(152.96078431, 1e-6));

      // 2. RSI 14 Wilder seed + post-seed recursion
      // Indices 0..14 alternate 100, 101 -> 7 gains of +1, 7 losses of -1 -> seed RSI[14] = 50.0
      final rsiPrices = <double>[
        for (int i = 0; i <= 14; i++) i.isEven ? 100.0 : 101.0,
        103.0, // index 15: change +3.0 -> avgGain=(0.5*13+3)/14=9.5/14, avgLoss=(0.5*13)/14=6.5/14 -> RSI = 59.375
        101.0, // index 16: change -2.0 -> avgGain=123.5/196, avgLoss=112.5/196 -> RSI = 52.33050847
      ];
      final rsiSeries = IndicatorEngine.calculateRsiSeries(rsiPrices, 14);
      expect(rsiSeries[13], isNull);
      expect(rsiSeries[14], closeTo(50.0, 1e-6)); // seed
      expect(rsiSeries[15], closeTo(59.375, 1e-6)); // Wilder recursion step 1
      expect(rsiSeries[16], closeTo(52.33050847, 1e-6)); // Wilder recursion step 2

      // 3. ATR 14 seed + Wilder post-seed recursion
      final baseCandles = buildContiguousCandles(
        symbol: 'BTCUSDT',
        interval: '15m',
        startOpenMs: 1700000000000,
        count: 14,
        closeBuilder: (_) => 100.0, // high=101.5, low=98.5 -> TR=3.0
      );
      const candle14 = Candle(
        symbol: 'BTCUSDT',
        interval: '15m',
        openTimeMs: 1700000000000 + 14 * 900000,
        closeTimeMs: 1700000000000 + 15 * 900000,
        open: 100.0,
        high: 105.0,
        low: 98.0,
        close: 104.0,
        volume: 25.0,
      ); // TR = 7.0 -> ATR[14] = (3.0 * 13 + 7.0) / 14 = 46/14 = 3.28571429
      const candle15 = Candle(
        symbol: 'BTCUSDT',
        interval: '15m',
        openTimeMs: 1700000000000 + 15 * 900000,
        closeTimeMs: 1700000000000 + 16 * 900000,
        open: 104.0,
        high: 106.0,
        low: 101.0,
        close: 105.0,
        volume: 25.0,
      ); // TR = 5.0 -> ATR[15] = ((46/14)*13 + 5.0) / 14 = 668/196 = 3.40816327

      final atr14 = IndicatorEngine.calculateAtrSeries(
        [...baseCandles, candle14, candle15],
        14,
      );
      expect(atr14[12], isNull);
      expect(atr14[13], closeTo(3.0, 1e-6)); // seed
      expect(atr14[14], closeTo(46.0 / 14.0, 1e-6)); // recursion step 1
      expect(atr14[15], closeTo(668.0 / 196.0, 1e-6)); // recursion step 2
    });

    test('Test 22: Trade alert text formatting for ENTRY, EXIT, and SAFETY LOCK includes PAPER TRADE label and required metrics', () {
      const buyOrder = SimulatedOrder(
        id: 'ORD-BUY-1001',
        symbol: 'BTCUSDT',
        side: 'BUY',
        requestedPrice: 50000.0,
        executedPrice: 50025.0,
        quantity: 0.001,
        notionalUsdt: 50.025,
        feeUsdt: 0.05,
        signalCandleCloseMs: 1700000000000,
        executedAtMs: 1700000900000,
        reason: 'SIGNAL_NEXT_OPEN_ENTRY',
      );
      const position = PaperPosition(
        id: 'POS-1001',
        symbol: 'BTCUSDT',
        entryPrice: 50025.0,
        quantity: 0.001,
        stopLoss: 49125.0,
        takeProfit: 51825.0,
        entryFeeUsdt: 0.05,
        signalCandleCloseMs: 1700000000000,
        openedAtMs: 1700000900000,
      );

      final entryAlert = TradeAlertFormatter.formatEntryAlert(
        buyOrder: buyOrder,
        position: position,
      );
      expect(entryAlert.alertId, 'ENTRY:ORD-BUY-1001');
      expect(entryAlert.title, contains('PAPER TRADE ENTRY'));
      expect(entryAlert.body, contains('[PAPER TRADE]'));
      expect(entryAlert.body, contains('BUY BTCUSDT'));
      expect(entryAlert.body, contains('Entry: \$50025.00'));
      expect(entryAlert.body, contains('Qty: 0.001000'));
      expect(entryAlert.body, contains('SL: \$49125.00'));
      expect(entryAlert.body, contains('TP: \$51825.00'));
      expect(entryAlert.body, contains('Risked: \$1.00'));

      const sellOrder = SimulatedOrder(
        id: 'ORD-SELL-1002',
        symbol: 'BTCUSDT',
        side: 'SELL',
        requestedPrice: 51825.0,
        executedPrice: 51799.09,
        quantity: 0.001,
        notionalUsdt: 51.799,
        feeUsdt: 0.0518,
        signalCandleCloseMs: 1700000000000,
        executedAtMs: 1700001800000,
        reason: 'TAKE_PROFIT',
      );
      const closedTrade = ClosedPaperTrade(
        id: 'TRD-1002',
        symbol: 'BTCUSDT',
        entryPrice: 50025.0,
        exitPrice: 51799.09,
        quantity: 0.001,
        stopLoss: 49125.0,
        takeProfit: 51825.0,
        totalFeesUsdt: 0.1018,
        realizedPnlUsdt: 1.67,
        openedAtMs: 1700000900000,
        closedAtMs: 1700001800000,
        exitReason: 'TAKE_PROFIT',
      );

      final exitAlert = TradeAlertFormatter.formatExitAlert(
        sellOrder: sellOrder,
        closedTrade: closedTrade,
        newAccountEquityUsdt: 101.67,
      );
      expect(exitAlert.alertId, 'EXIT:ORD-SELL-1002');
      expect(exitAlert.title, contains('PAPER TRADE EXIT'));
      expect(exitAlert.body, contains('[PAPER TRADE]'));
      expect(exitAlert.body, contains('EXIT BTCUSDT @ \$51799.09'));
      expect(exitAlert.body, contains('Reason: TAKE_PROFIT'));
      expect(exitAlert.body, contains('Net P&L: +\$1.67'));
      expect(exitAlert.body, contains('Equity: \$101.67'));

      final lockAlert = TradeAlertFormatter.formatSafetyLockAlert(
        lockTypeKey: 'DAILY_LOSS_LIMIT:2026-11-05',
        lockTitle: 'DAILY LOSS LIMIT (\$2.00) REACHED',
        reasonDetail: 'New entries locked.',
        currentEquityUsdt: 97.95,
      );
      expect(lockAlert.title, contains('PAPER TRADE SAFETY LOCK'));
      expect(lockAlert.body, contains('[PAPER TRADE]'));
      expect(lockAlert.body, contains('Equity: \$97.95'));
    });

    test('Test 23: Trade alert notifications ON/OFF toggle defaults to ON and persists in SQLite engine_kv_state across restarts', () async {
      final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
      final persistence = PersistenceDatabase();
      await persistence.openWithCustomDatabase(db);

      // Default is ON (true)
      expect(await persistence.getTradeAlertsEnabled(), isTrue);

      // Turn OFF and verify persistence
      await persistence.setTradeAlertsEnabled(false);
      expect(await persistence.getTradeAlertsEnabled(), isFalse);

      final snapOff = await persistence.restoreFullSnapshot(PaperBroker());
      expect(snapOff.tradeAlertsEnabled, isFalse);

      // Turn ON and verify persistence
      await persistence.setTradeAlertsEnabled(true);
      expect(await persistence.getTradeAlertsEnabled(), isTrue);

      await persistence.close();
    });

    test('Test 24: Authoritative engine sends NO trade alert when toggle is OFF while keeping foreground service notification active', () async {
      final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
      final persistence = PersistenceDatabase();
      await persistence.openWithCustomDatabase(db);

      final sentAlerts = <TradeAlertPayload>[];
      final serviceNotifications = <String>[];

      final engine = AuthoritativeTradingEngine(
        marketService: CoinDcxMarketService(),
        persistence: persistence,
        onNotificationUpdate: (title, text) async {
          serviceNotifications.add('$title|$text');
        },
        onTradeAlert: (alert) async {
          sentAlerts.add(alert);
        },
      );

      // Set toggle to OFF in SQLite
      await persistence.setTradeAlertsEnabled(false);

      const sampleAlert = TradeAlertPayload(
        alertId: 'ENTRY:ORD-BUY-5001',
        title: 'PAPER TRADE ENTRY — BTCUSDT (BUY)',
        body: '[PAPER TRADE] BUY BTCUSDT',
      );
      final dispatchedWhenOff =
          await engine.dispatchAlertIfEnabledAndNew(sampleAlert);
      expect(dispatchedWhenOff, isFalse);
      expect(sentAlerts, isEmpty);

      // Pause command still updates the ongoing foreground service notification
      await engine.handleCommand('PAUSE', nowOverrideMs: 1700000000000);
      expect(serviceNotifications.isNotEmpty, isTrue);

      await persistence.close();
    });

    test('Test 25: Duplicate alert guard prevents sending a second alert for the same order ID across restarts', () async {
      final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
      final persistence = PersistenceDatabase();
      await persistence.openWithCustomDatabase(db);

      final sentAlerts = <TradeAlertPayload>[];
      final engine1 = AuthoritativeTradingEngine(
        marketService: CoinDcxMarketService(),
        persistence: persistence,
        onTradeAlert: (alert) async {
          sentAlerts.add(alert);
        },
      );

      const alert = TradeAlertPayload(
        alertId: 'ENTRY:ORD-BUY-9001',
        title: 'PAPER TRADE ENTRY — BTCUSDT (BUY)',
        body: '[PAPER TRADE] BUY BTCUSDT',
      );

      // First dispatch succeeds
      final firstSend = await engine1.dispatchAlertIfEnabledAndNew(alert);
      expect(firstSend, isTrue);
      expect(sentAlerts.length, 1);
      expect(await persistence.getLastNotifiedOrderId(), 'ENTRY:ORD-BUY-9001');

      // Simulated service recreation / second engine instance attempting the same order ID
      final engine2 = AuthoritativeTradingEngine(
        marketService: CoinDcxMarketService(),
        persistence: persistence,
        onTradeAlert: (a) async {
          sentAlerts.add(a);
        },
      );
      final duplicateSend = await engine2.dispatchAlertIfEnabledAndNew(alert);
      expect(duplicateSend, isFalse);
      expect(sentAlerts.length, 1);

      await persistence.close();
    });

    test('Test 26: CoinDCX /exchange/ticker parser extracts valid BTCUSDT and ETHUSDT last_price and ignores malformed entries', () async {
      final rawTickerResponse = [
        {
          'market': 'BTCUSDT',
          'change_24_hour': '2.45',
          'high': '68950.00',
          'low': '66200.00',
          'volume': '1420.55',
          'last_price': '68425.75',
          'bid': '68425.00',
          'ask': '68426.50',
          'timestamp': 1700054000000,
        },
        {
          'market': 'B-ETH_USDT',
          'change_24_hour': '1.12',
          'high': '3520.00',
          'low': '3410.00',
          'volume': '8540.10',
          'last_price': 3489.25,
          'bid': '3489.00',
          'ask': '3489.50',
          'timestamp': 1700054000000,
        },
        {
          'market': 'SOLUSDT',
          'last_price': '185.40',
        },
        {
          'market': 'BTCINR',
          'last_price': '5800000.00',
        },
        {
          'market': 'ETHUSDT',
          'last_price': '-10.0', // invalid negative price ignored
        },
      ];

      final parsed = CoinDcxMarketService.parseLiveTickerPrices(
        rawList: rawTickerResponse,
      );
      expect(parsed['BTCUSDT'], closeTo(68425.75, 1e-6));
      expect(parsed['ETHUSDT'], closeTo(3489.25, 1e-6));
      expect(parsed.containsKey('SOLUSDT'), isFalse);

      final mockClient = MockClient((request) async {
        expect(request.url.toString(), CoinDcxMarketService.tickerUrl);
        return http.Response(jsonEncode(rawTickerResponse), 200);
      });
      final service = CoinDcxMarketService(client: mockClient);
      final fetched = await service.fetchLiveTickerPrices();
      expect(fetched['BTCUSDT'], closeTo(68425.75, 1e-6));
      expect(fetched['ETHUSDT'], closeTo(3489.25, 1e-6));
    });

    test('Test 27: Ongoing notification includes live BTC/ETH ticker prices and equity while strategy & SL/TP use only closed candles', () async {
      final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
      final persistence = PersistenceDatabase();
      await persistence.openWithCustomDatabase(db);

      final nowMs = DateTime.now().toUtc().millisecondsSinceEpoch;
      final mockClient = MockClient((request) async {
        final url = request.url.toString();
        if (url.contains('markets_details')) {
          return http.Response(
            jsonEncode([
              {
                'symbol': 'BTCUSDT',
                'pair': 'B-BTC_USDT',
                'status': 'active',
                'base_currency_short_name': 'USDT',
                'target_currency_short_name': 'BTC',
                'min_notional': 1.0,
                'min_quantity': 0.0001,
              },
              {
                'symbol': 'ETHUSDT',
                'pair': 'B-ETH_USDT',
                'status': 'active',
                'base_currency_short_name': 'USDT',
                'target_currency_short_name': 'ETH',
                'min_notional': 1.0,
                'min_quantity': 0.001,
              },
            ]),
            200,
          );
        }
        if (url.contains('/exchange/ticker')) {
          return http.Response(
            jsonEncode([
              {
                'market': 'BTCUSDT',
                'last_price': '67890.50',
                'timestamp': nowMs,
              },
              {
                'market': 'ETHUSDT',
                'last_price': '3456.75',
                'timestamp': nowMs,
              },
            ]),
            200,
          );
        }
        final is1h = request.url.queryParameters['interval'] == '1h';
        final step = is1h ? 3600000 : 900000;
        final baseOpen = ((nowMs ~/ step) - 65) * step;
        final list = List.generate(65, (i) {
          final t = baseOpen + (i * step);
          return {
            'time': t,
            'open': 50000 + i * 10,
            'high': 50050 + i * 10,
            'low': 49950 + i * 10,
            'close': 50020 + i * 10,
            'volume': 12.5,
          };
        });
        return http.Response(jsonEncode(list), 200);
      });

      final serviceNotifications = <String>[];
      final mktService = CoinDcxMarketService(client: mockClient);
      final authEngine = AuthoritativeTradingEngine(
        marketService: mktService,
        persistence: persistence,
        onNotificationUpdate: (title, text) async {
          serviceNotifications.add('$title|$text');
        },
      );

      final started = await authEngine.handleCommand('START', nowOverrideMs: nowMs);
      expect(started, isTrue);
      expect(serviceNotifications.isNotEmpty, isTrue);

      final lastNotif = serviceNotifications.last;
      expect(lastNotif, contains('Eq: \$100.00'));
      expect(lastNotif, contains('BTC: \$67890.50'));
      expect(lastNotif, contains('ETH: \$3456.75'));

      final snap = await persistence.restoreFullSnapshot(PaperBroker());
      expect(snap.latestPrices['BTCUSDT'], closeTo(67890.50, 1e-6));
      expect(snap.latestPrices['ETHUSDT'], closeTo(3456.75, 1e-6));

      await persistence.close();
    });

    test('Test 28: Indicator values (EMA20/50, RSI14, ATR14, 1h trend) are kept when NO NEW CLOSED 15M CANDLES and only null when truly warming up', () async {
      final broker = PaperBroker();
      const baseMs = 1700000000000;
      final candles15m = buildContiguousCandles(
        symbol: 'BTCUSDT',
        interval: '15m',
        startOpenMs: baseMs,
        count: 60,
        closeBuilder: (i) => 100.0 + i * 0.5,
      );
      final candles1h = buildContiguousCandles(
        symbol: 'BTCUSDT',
        interval: '1h',
        startOpenMs: baseMs - (60 * 3600000),
        count: 75,
        closeBuilder: (i) => 90.0 + i * 0.5,
      );

      // First call warms up
      final first = broker.processClosedCandleStream(
        symbol: 'BTCUSDT',
        closed15m: candles15m,
        closed1h: candles1h,
        latestPrices: {},
      );
      expect(first.evaluations.first.ema20_15m, isNotNull);
      expect(first.evaluations.first.ema50_15m, isNotNull);
      expect(first.evaluations.first.rsi14_15m, isNotNull);
      expect(first.evaluations.first.atr14_15m, isNotNull);

      // Second call with no new closed candles keeps all indicator values non-null
      final second = broker.processClosedCandleStream(
        symbol: 'BTCUSDT',
        closed15m: candles15m,
        closed1h: candles1h,
        latestPrices: {},
      );
      final evalNoNew = second.evaluations.first;
      expect(evalNoNew.description, 'NO NEW CLOSED 15M CANDLES');
      expect(evalNoNew.ema20_15m, closeTo(first.evaluations.first.ema20_15m!, 1e-6));
      expect(evalNoNew.ema50_15m, closeTo(first.evaluations.first.ema50_15m!, 1e-6));
      expect(evalNoNew.rsi14_15m, closeTo(first.evaluations.first.rsi14_15m!, 1e-6));
      expect(evalNoNew.atr14_15m, closeTo(first.evaluations.first.atr14_15m!, 1e-6));
      expect(evalNoNew.higherTimeframeBullish, isTrue);

      // Truly too few candles (<52) returns null indicators and warming up / insufficient history
      final short15m = candles15m.sublist(0, 20);
      final shortEval = broker.strategyEngine.evaluateClosedCandles(
        closed15m: short15m,
        closed1h: candles1h.sublist(0, 20),
        hasOpenPosition: false,
      );
      expect(shortEval.ema20_15m, isNull);
    });

    test('Test 29: Active timer persists runningSinceMs in engine_kv_state and accumulates totalActiveMs across pause/resume', () async {
      final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
      final persistence = PersistenceDatabase();
      await persistence.openWithCustomDatabase(db);
      final broker = PaperBroker();

      const tStart = 1700000000000;
      await persistence.saveFullState(
        broker: broker,
        botState: BotEngineState.running,
        latestPrices: const {'BTCUSDT': 68000.0},
        nowOverrideMs: tStart,
      );

      final snapRunning = await persistence.restoreFullSnapshot(broker);
      expect(snapRunning.runningSinceMs, tStart);
      expect(snapRunning.totalActiveMs, 0);

      // Pause after 2 hours (7,200,000 ms)
      const tPause = tStart + 7200000;
      await persistence.saveFullState(
        broker: broker,
        botState: BotEngineState.pausedAfterRecoveryManualStartRequired,
        latestPrices: const {'BTCUSDT': 68100.0},
        nowOverrideMs: tPause,
      );

      final snapPaused = await persistence.restoreFullSnapshot(broker);
      expect(snapPaused.runningSinceMs, isNull);
      expect(snapPaused.lastSessionDurationMs, 7200000);
      expect(snapPaused.totalActiveMs, 7200000);
      expect(
        ActiveTimerSummary.formatHhMmSs(snapPaused.lastSessionDurationMs),
        '02:00:00',
      );

      // Resume at tResume and run for 35 minutes (2,100,000 ms), then stop
      const tResume = tPause + 600000;
      await persistence.saveFullState(
        broker: broker,
        botState: BotEngineState.running,
        latestPrices: const {'BTCUSDT': 68200.0},
        nowOverrideMs: tResume,
      );

      const tStop = tResume + 2100000;
      await persistence.saveFullState(
        broker: broker,
        botState: BotEngineState.stopped,
        latestPrices: const {'BTCUSDT': 68300.0},
        nowOverrideMs: tStop,
      );

      final snapStopped = await persistence.restoreFullSnapshot(broker);
      expect(snapStopped.runningSinceMs, isNull);
      expect(snapStopped.lastSessionDurationMs, 2100000);
      expect(snapStopped.totalActiveMs, 9300000); // 2h 35m total
      expect(
        ActiveTimerSummary.formatDaysHhMm(snapStopped.totalActiveMs),
        '0d 02:35',
      );

      await persistence.close();
    });

    test('Test 30: Why-no-trade helper reports each first failed condition accurately (stale, locked/paused, 1h not bullish, RSI outside 50-65, no EMA cross, risk rejected, below minimum order)', () {
      const baseEval = StrategyEvaluationResult(
        signalType: StrategySignalType.none,
        description: 'SCANNING 15M (1H BULLISH, RSI 56.0)',
        evaluatedCandleCloseMs: 1700000900000,
        ema20_15m: 105.0,
        ema50_15m: 103.0,
        rsi14_15m: 56.0,
        atr14_15m: 1.5,
        ema20_1h: 104.0,
        ema50_1h: 101.0,
        higherTimeframeBullish: true,
      );

      // 1. Stale data
      expect(
        StrategyEngine.deriveWhyNoTradeReason(
          botState: BotEngineState.pausedStaleData,
          marketDataStatus: MarketDataStatus.stale,
          eval: baseEval,
        ),
        'Why no trade: Stale data',
      );

      // 2. Locked / paused
      expect(
        StrategyEngine.deriveWhyNoTradeReason(
          botState: BotEngineState.lockedDailyLossLimit,
          marketDataStatus: MarketDataStatus.connected,
          eval: baseEval,
        ),
        contains('Why no trade: Locked/paused'),
      );

      // 3. 1h not bullish
      const bearish1hEval = StrategyEvaluationResult(
        signalType: StrategySignalType.waitingHigherTimeframe,
        description: '15M CROSSOVER BLOCKED: 1H TREND NOT BULLISH',
        evaluatedCandleCloseMs: 1700000900000,
        ema20_15m: 105.0,
        ema50_15m: 103.0,
        rsi14_15m: 56.0,
        atr14_15m: 1.5,
        ema20_1h: 99.0,
        ema50_1h: 101.0,
        higherTimeframeBullish: false,
      );
      expect(
        StrategyEngine.deriveWhyNoTradeReason(
          botState: BotEngineState.running,
          marketDataStatus: MarketDataStatus.connected,
          eval: bearish1hEval,
        ),
        'Why no trade: 1h not bullish',
      );

      // 4. RSI outside 50-65
      const rsiOutEval = StrategyEvaluationResult(
        signalType: StrategySignalType.none,
        description: 'SCANNING 15M (1H BULLISH, RSI 71.2)',
        evaluatedCandleCloseMs: 1700000900000,
        ema20_15m: 105.0,
        ema50_15m: 103.0,
        rsi14_15m: 71.2,
        atr14_15m: 1.5,
        ema20_1h: 104.0,
        ema50_1h: 101.0,
        higherTimeframeBullish: true,
      );
      expect(
        StrategyEngine.deriveWhyNoTradeReason(
          botState: BotEngineState.running,
          marketDataStatus: MarketDataStatus.connected,
          eval: rsiOutEval,
        ),
        'Why no trade: RSI outside 50-65 (71.2)',
      );

      // 5. No EMA cross
      expect(
        StrategyEngine.deriveWhyNoTradeReason(
          botState: BotEngineState.running,
          marketDataStatus: MarketDataStatus.connected,
          eval: baseEval,
        ),
        'Why no trade: No EMA cross',
      );

      // 6. Below minimum order
      expect(
        StrategyEngine.deriveWhyNoTradeReason(
          botState: BotEngineState.running,
          marketDataStatus: MarketDataStatus.connected,
          eval: baseEval,
          lastSizingRejectionReason: 'QUANTITY BELOW EXCHANGE MINIMUM',
        ),
        'Why no trade: Below minimum order',
      );

      // 7. Risk rejected
      const riskBlockedEval = StrategyEvaluationResult(
        signalType: StrategySignalType.blockedByRisk,
        description: 'TRADE RISK EXCEEDS 1% LIMIT',
        evaluatedCandleCloseMs: 1700000900000,
        ema20_15m: 105.0,
        ema50_15m: 103.0,
        rsi14_15m: 56.0,
        atr14_15m: 1.5,
        ema20_1h: 104.0,
        ema50_1h: 101.0,
        higherTimeframeBullish: true,
      );
      expect(
        StrategyEngine.deriveWhyNoTradeReason(
          botState: BotEngineState.running,
          marketDataStatus: MarketDataStatus.connected,
          eval: riskBlockedEval,
        ),
        'Why no trade: Risk rejected',
      );
    });

    test('Test 31: Bounded auto-recovery retries with 30s -> 60s -> 120s backoff for up to 10 minutes and only pauses after 10m window expires', () async {
      final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
      final persistence = PersistenceDatabase();
      await persistence.openWithCustomDatabase(db);

      const t0 = 1700050000000;
      await persistence.saveFullState(
        broker: PaperBroker(),
        botState: BotEngineState.running,
        latestPrices: const {'BTCUSDT': 68000.0, 'ETHUSDT': 3400.0},
        nowOverrideMs: t0,
      );

      final recordedDelays = <int>[];
      final scheduledRetries = <int>[];
      final mockClient = MockClient((request) async {
        final url = request.url.toString();
        if (url.contains('markets_details')) {
          return http.Response(
            jsonEncode([
              {
                'symbol': 'BTCUSDT',
                'pair': 'B-BTC_USDT',
                'status': 'active',
                'base_currency_short_name': 'USDT',
                'target_currency_short_name': 'BTC',
                'min_notional': 1.0,
                'min_quantity': 0.0001,
              },
              {
                'symbol': 'ETHUSDT',
                'pair': 'B-ETH_USDT',
                'status': 'active',
                'base_currency_short_name': 'USDT',
                'target_currency_short_name': 'ETH',
                'min_notional': 1.0,
                'min_quantity': 0.001,
              },
            ]),
            200,
          );
        }
        // Simulate transient HTTP 503 failure on candle fetches
        return http.Response('Service Unavailable', 503);
      });

      final engine = AuthoritativeTradingEngine(
        marketService: CoinDcxMarketService(client: mockClient),
        persistence: persistence,
        delayProvider: (delayMs) async {
          recordedDelays.add(delayMs);
        },
        onScheduleRetry: (delayMs, reason) async {
          scheduledRetries.add(delayMs);
        },
      );

      // 1st failed cycle at t0: in-cycle retry schedule [30s, 60s, 120s] + cycle-level retry #1 (30s)
      final ok1 = await engine.executeAuthoritativeCycle(
        allowTradingExecution: true,
        nowOverrideMs: t0,
      );
      expect(ok1, isFalse);
      expect(recordedDelays.sublist(0, 3), [30000, 60000, 120000]);
      expect(scheduledRetries.first, 30000);

      // Engine must remain RUNNING during the 10-minute bounded window
      final snapAfter1 = await persistence.restoreFullSnapshot(PaperBroker());
      expect(snapAfter1.botState, BotEngineState.running);
      expect(snapAfter1.recoveryAttemptCount, 1);
      expect(snapAfter1.recoveryLogs, isNotEmpty);

      // 2nd failed cycle at t0 + 35s: cycle-level backoff steps to 60s, still RUNNING
      await engine.executeAuthoritativeCycle(
        allowTradingExecution: true,
        nowOverrideMs: t0 + 35000,
      );
      final snapAfter2 = await persistence.restoreFullSnapshot(PaperBroker());
      expect(snapAfter2.botState, BotEngineState.running);
      expect(snapAfter2.recoveryAttemptCount, 2);
      expect(scheduledRetries[1], 60000);

      // 3rd failed cycle at t0 + 100s: cycle-level backoff steps to 120s, still RUNNING
      await engine.executeAuthoritativeCycle(
        allowTradingExecution: true,
        nowOverrideMs: t0 + 100000,
      );
      final snapAfter3 = await persistence.restoreFullSnapshot(PaperBroker());
      expect(snapAfter3.botState, BotEngineState.running);
      expect(snapAfter3.recoveryAttemptCount, 3);
      expect(scheduledRetries[2], 120000);

      // After 10 minutes (t0 + 601,000 ms), bounded recovery expires and transitions to PAUSED
      await engine.executeAuthoritativeCycle(
        allowTradingExecution: true,
        nowOverrideMs: t0 + 601000,
      );
      final snapExpired = await persistence.restoreFullSnapshot(PaperBroker());
      expect(
        snapExpired.botState,
        BotEngineState.pausedAfterRecoveryManualStartRequired,
      );
      expect(
        snapExpired.statusBannerMessage,
        contains('PAUSED AFTER 10M AUTO-RECOVERY'),
      );

      await persistence.close();
    });

    test('Test 32: Reconnect on reopen keeps RUNNING and shows RECONNECTED banner when heartbeat is under 5m old, and pauses only when service is dead AND heartbeat >= 5m old', () async {
      final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
      final persistence = PersistenceDatabase();
      await persistence.openWithCustomDatabase(db);

      const baseNowMs = 1700050300000;
      // Case A: Heartbeat is 45 seconds old (< 5 minutes)
      const recentHbMs = baseNowMs - 45000;
      await persistence.saveFullState(
        broker: PaperBroker(),
        botState: BotEngineState.running,
        latestPrices: const {'BTCUSDT': 68100.0, 'ETHUSDT': 3410.0},
        lastHeartbeatMs: recentHbMs,
        nowOverrideMs: recentHbMs,
      );

      final coordinatorReconnect = TradingCoordinator(
        persistence: persistence,
        commandBridge: FakeEngineCommandBridge(
          serviceStartsSuccessfully: true,
          dartEngineInitializesSuccessfully: true,
        ),
        customInternetProbe: () async => true,
        nowMsProvider: () => baseNowMs,
      );
      await coordinatorReconnect.initialize(enablePlatformChannels: false);

      expect(coordinatorReconnect.engineState, BotEngineState.running);
      expect(
        coordinatorReconnect.statusBannerMessage,
        startsWith('RECONNECTED — heartbeat '),
      );
      expect(
        coordinatorReconnect.formatHeartbeatStatus(nowOverrideMs: baseNowMs),
        contains('(45s ago)'),
      );

      // Case B: Service is dead AND heartbeat is 6 minutes old (>= 5 minutes) -> downgrade to paused
      const staleHbMs = baseNowMs - (6 * 60 * 1000);
      await persistence.saveFullState(
        broker: PaperBroker(),
        botState: BotEngineState.running,
        latestPrices: const {'BTCUSDT': 68100.0, 'ETHUSDT': 3410.0},
        lastHeartbeatMs: staleHbMs,
        nowOverrideMs: staleHbMs,
      );

      final coordinatorDead = TradingCoordinator(
        persistence: persistence,
        commandBridge: FakeEngineCommandBridge(
          serviceStartsSuccessfully: false,
          dartEngineInitializesSuccessfully: false,
        ),
        customInternetProbe: () async => true,
        nowMsProvider: () => baseNowMs,
      );
      await coordinatorDead.initialize(enablePlatformChannels: false);

      expect(
        coordinatorDead.engineState,
        BotEngineState.pausedAfterRecoveryManualStartRequired,
      );

      await persistence.close();
    });

    test('Test 33: Per-symbol isolation ensures a BTC failure does not skip ETH and keeps the engine RUNNING when ETH succeeds', () async {
      final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
      final persistence = PersistenceDatabase();
      await persistence.openWithCustomDatabase(db);

      const nowMs = 1700054000000;
      final mockClient = MockClient((request) async {
        final url = request.url.toString();
        if (url.contains('markets_details')) {
          return http.Response(
            jsonEncode([
              {
                'symbol': 'BTCUSDT',
                'pair': 'B-BTC_USDT',
                'status': 'active',
                'base_currency_short_name': 'USDT',
                'target_currency_short_name': 'BTC',
                'min_notional': 1.0,
                'min_quantity': 0.0001,
              },
              {
                'symbol': 'ETHUSDT',
                'pair': 'B-ETH_USDT',
                'status': 'active',
                'base_currency_short_name': 'USDT',
                'target_currency_short_name': 'ETH',
                'min_notional': 1.0,
                'min_quantity': 0.001,
              },
            ]),
            200,
          );
        }
        if (url.contains('/exchange/ticker')) {
          return http.Response(jsonEncode([]), 200);
        }
        final pair = request.url.queryParameters['pair'] ?? '';
        // Simulate BTCUSDT throwing HTTP 500 while ETHUSDT succeeds with valid closed candles
        if (pair.contains('BTC')) {
          return http.Response('BTC Upstream Error', 500);
        }
        final is1h = request.url.queryParameters['interval'] == '1h';
        final step = is1h ? 3600000 : 900000;
        final baseOpen = ((nowMs ~/ step) - 65) * step;
        final list = List.generate(65, (i) {
          final t = baseOpen + (i * step);
          return {
            'time': t,
            'open': 3400 + i * 2,
            'high': 3410 + i * 2,
            'low': 3390 + i * 2,
            'close': 3405 + i * 2,
            'volume': 20.0,
          };
        });
        return http.Response(jsonEncode(list), 200);
      });

      final engine = AuthoritativeTradingEngine(
        marketService: CoinDcxMarketService(client: mockClient),
        persistence: persistence,
      );

      final ok = await engine.handleCommand('START', nowOverrideMs: nowMs);
      expect(ok, isTrue);

      final snap = await persistence.restoreFullSnapshot(PaperBroker());
      expect(snap.botState, BotEngineState.running);
      expect(snap.latestEvaluations.containsKey('ETHUSDT'), isTrue);
      expect(snap.latestPrices['ETHUSDT'], greaterThan(3400.0));
      expect(snap.statusBannerMessage, contains('PARTIAL FEED'));

      await persistence.close();
    });

    test('Test 34: Explicit STOP stops the bot and is never auto-restarted by subsequent background ticks', () async {
      final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
      final persistence = PersistenceDatabase();
      await persistence.openWithCustomDatabase(db);

      const nowMs = 1700054000000;
      final mockClient = MockClient((request) async {
        final url = request.url.toString();
        if (url.contains('markets_details')) {
          return http.Response(
            jsonEncode([
              {
                'symbol': 'BTCUSDT',
                'pair': 'B-BTC_USDT',
                'status': 'active',
                'base_currency_short_name': 'USDT',
                'target_currency_short_name': 'BTC',
                'min_notional': 1.0,
                'min_quantity': 0.0001,
              },
              {
                'symbol': 'ETHUSDT',
                'pair': 'B-ETH_USDT',
                'status': 'active',
                'base_currency_short_name': 'USDT',
                'target_currency_short_name': 'ETH',
                'min_notional': 1.0,
                'min_quantity': 0.001,
              },
            ]),
            200,
          );
        }
        if (url.contains('/exchange/ticker')) {
          return http.Response(jsonEncode([]), 200);
        }
        final is1h = request.url.queryParameters['interval'] == '1h';
        final step = is1h ? 3600000 : 900000;
        final baseOpen = ((nowMs ~/ step) - 65) * step;
        final list = List.generate(65, (i) {
          final t = baseOpen + (i * step);
          return {
            'time': t,
            'open': 50000 + i * 10,
            'high': 50050 + i * 10,
            'low': 49950 + i * 10,
            'close': 50020 + i * 10,
            'volume': 12.5,
          };
        });
        return http.Response(jsonEncode(list), 200);
      });

      final engine = AuthoritativeTradingEngine(
        marketService: CoinDcxMarketService(client: mockClient),
        persistence: persistence,
      );

      // Start the bot
      final started = await engine.handleCommand('START', nowOverrideMs: nowMs);
      expect(started, isTrue);
      expect(
        (await persistence.restoreFullSnapshot(PaperBroker())).botState,
        BotEngineState.running,
      );

      // User presses STOP
      final stopped =
          await engine.handleCommand('STOP', nowOverrideMs: nowMs + 10000);
      expect(stopped, isTrue);
      expect(
        (await persistence.restoreFullSnapshot(PaperBroker())).botState,
        BotEngineState.stopped,
      );

      // Subsequent background ticks must return false and NEVER transition back to running
      final tickAfterStop = await engine.executeAuthoritativeCycle(
        allowTradingExecution: true,
        nowOverrideMs: nowMs + 70000,
      );
      expect(tickAfterStop, isFalse);
      expect(
        (await persistence.restoreFullSnapshot(PaperBroker())).botState,
        BotEngineState.stopped,
      );

      await persistence.close();
    });
  });
}

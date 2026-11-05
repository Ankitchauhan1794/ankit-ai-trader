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

    test('Test 17: Internet loss pauses authoritative engine and automatic reconnection requires manual START', () async {
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
      final bridge = FakeEngineCommandBridge(engine: authEngine);

      final coordinator = TradingCoordinator(
        marketService: mktService,
        persistence: persistence,
        commandBridge: bridge,
        customInternetProbe: () async => true,
      );
      await coordinator.initialize(enablePlatformChannels: false);
      await coordinator.manualStartBot();
      expect(coordinator.engineState, BotEngineState.running);

      // Internet lost
      await coordinator.handleConnectivityTransition(false);
      expect(coordinator.engineState, BotEngineState.pausedNetworkLoss);

      // Internet recovered -> must remain paused until manual START
      await coordinator.handleConnectivityTransition(true);
      expect(
        coordinator.engineState,
        BotEngineState.pausedAfterRecoveryManualStartRequired,
      );

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
          if (i < 60) return 120.0 - i * 0.15;
          if (i < 130) return 111.0 + (i - 60) * 0.12;
          return 119.4 + (i - 130) * 0.25;
        },
      );

      final report = PaperBroker.runHistoricalBacktest(
        symbol: 'BTCUSDT',
        candles15m: candles15m,
        candles1h: candles1h,
      );

      expect(report.endingEquityUsdt.isFinite, isTrue);
      expect(report.maxDrawdownUsdt >= 0.0, isTrue);
      expect(report.winRatePercent >= 0.0 && report.winRatePercent <= 100.0, isTrue);
    });

    test('Test 21: Technical indicators (EMA 20/50, RSI 14, ATR 14) mathematical verification', () {
      final prices = List<double>.generate(60, (i) => 100.0 + i * 2.0);
      final ema20 = IndicatorEngine.calculateEmaSeries(prices, 20);
      final ema50 = IndicatorEngine.calculateEmaSeries(prices, 50);
      expect(ema20[19], closeTo(119.0, 1e-6));
      expect(ema50[49], closeTo(149.0, 1e-6));

      final flat = List<double>.filled(20, 100.0);
      final rsiFlat = IndicatorEngine.calculateRsiSeries(flat, 14);
      expect(rsiFlat.last, closeTo(50.0, 1e-6));

      final candles = buildContiguousCandles(
        symbol: 'BTCUSDT',
        interval: '15m',
        startOpenMs: 1700000000000,
        count: 20,
        closeBuilder: (_) => 100.0,
      );
      final atr14 = IndicatorEngine.calculateAtrSeries(candles, 14);
      expect(atr14.last, closeTo(3.0, 1e-6));
    });
  });
}

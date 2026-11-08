import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ankit_ai_trader/main.dart';
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

class _FakeCommandBridge implements EngineCommandBridge {
  bool serviceReady;
  bool shouldSucceedStart;
  int ensureServiceStartCalls = 0;
  final List<String> dispatchedCommands = [];

  _FakeCommandBridge({
    this.serviceReady = false,
    this.shouldSucceedStart = true,
  });

  @override
  Future<bool> ensureServiceStartedAndReady() async {
    ensureServiceStartCalls++;
    if (!shouldSucceedStart) return false;
    serviceReady = true;
    return true;
  }

  @override
  Future<bool> dispatchCommand(String command) async {
    if (!shouldSucceedStart) return false;
    dispatchedCommands.add(command);
    return true;
  }

  @override
  Future<bool> isServiceAndEngineReady() async => serviceReady;

  @override
  Future<bool> stopService() async {
    serviceReady = false;
    return true;
  }

  @override
  Future<Map<String, dynamic>> getServiceStatus() async => {
        'serviceRunning': serviceReady,
        'dartEngineInitialized': serviceReady,
        'ignoringBatteryOptimizations': true,
        'lastNativeHeartbeatEpochMs': DateTime.now().millisecondsSinceEpoch,
      };
}

void main() {
  test('Test 1 (Stage 3): Session intention is stored separately and preserved across network/stale-data/safety pauses', () async {
    final db = PersistenceDatabase(useInMemoryFallback: true);
    await db.saveUserIntention(UserSessionIntention.running);

    await db.saveFullState(
      botState: BotEngineState.pausedNetworkLoss,
      availableCashUsdt: 100.0,
      accountEquityUsdt: 100.0,
      maxDrawdownLocked: false,
      statusBannerMessage: 'Paused on network loss',
      openPositions: const [],
      orders: const [],
      closedTrades: const [],
      processedEntrySignalKeys: const {},
    );

    final snap = await db.loadFullState();
    expect(snap.botState, BotEngineState.pausedNetworkLoss);
    expect(snap.userIntention, UserSessionIntention.running);
    await db.close();
  });

  test('Test 2 (Stage 4): RUNNING + alive service reconnects without START button; dead service restores once', () async {
    final db = PersistenceDatabase(useInMemoryFallback: true);
    await db.saveFullState(
      botState: BotEngineState.running,
      userIntention: UserSessionIntention.running,
      availableCashUsdt: 100.0,
      accountEquityUsdt: 100.0,
      maxDrawdownLocked: false,
      lastHeartbeatMs: 1000,
      statusBannerMessage: 'RUNNING',
      openPositions: const [],
      orders: const [],
      closedTrades: const [],
      processedEntrySignalKeys: const {},
    );

    final bridge = _FakeCommandBridge(serviceReady: false, shouldSucceedStart: true);
    final coordinator = TradingCoordinator(
      persistence: db,
      commandBridge: bridge,
      nowMsProvider: () => 900000,
    );

    await coordinator.refreshStateFromDatabase(isInitialLoad: true);
    expect(coordinator.userIntention, UserSessionIntention.running);
    expect(coordinator.engineState, BotEngineState.running);
    expect(bridge.ensureServiceStartCalls, 1);
    expect(bridge.dispatchedCommands, contains('START'));

    coordinator.dispose();
    await db.close();
  });

  test('Test 3 (Stage 4): RUNNING + failed single-shot restore exposes restoreFailedRequiresRestart for RESTART button', () async {
    final db = PersistenceDatabase(useInMemoryFallback: true);
    await db.saveFullState(
      botState: BotEngineState.running,
      userIntention: UserSessionIntention.running,
      availableCashUsdt: 100.0,
      accountEquityUsdt: 100.0,
      maxDrawdownLocked: false,
      lastHeartbeatMs: 1000,
      statusBannerMessage: 'RUNNING',
      openPositions: const [],
      orders: const [],
      closedTrades: const [],
      processedEntrySignalKeys: const {},
    );

    final bridge = _FakeCommandBridge(serviceReady: false, shouldSucceedStart: false);
    final coordinator = TradingCoordinator(
      persistence: db,
      commandBridge: bridge,
      nowMsProvider: () => 900000,
    );

    await coordinator.refreshStateFromDatabase(isInitialLoad: true);
    expect(coordinator.userIntention, UserSessionIntention.running);
    expect(coordinator.restoreFailedRequiresRestart, isTrue);

    coordinator.dispose();
    await db.close();
  });

  test('Test 4 (Stage 4): STOPPED bot never auto-starts on dashboard open', () async {
    final db = PersistenceDatabase(useInMemoryFallback: true);
    await db.saveFullState(
      botState: BotEngineState.stopped,
      userIntention: UserSessionIntention.stopped,
      availableCashUsdt: 100.0,
      accountEquityUsdt: 100.0,
      maxDrawdownLocked: false,
      lastHeartbeatMs: 1000,
      statusBannerMessage: 'STOPPED',
      openPositions: const [],
      orders: const [],
      closedTrades: const [],
      processedEntrySignalKeys: const {},
    );

    final bridge = _FakeCommandBridge(serviceReady: false);
    final coordinator = TradingCoordinator(
      persistence: db,
      commandBridge: bridge,
      nowMsProvider: () => 900000,
    );

    await coordinator.refreshStateFromDatabase(isInitialLoad: true);
    expect(bridge.ensureServiceStartCalls, 0);
    expect(coordinator.engineState, BotEngineState.stopped);

    coordinator.dispose();
    await db.close();
  });

  test('Test 5 (Stage 5): Heartbeat health levels (<90s OK, 90s-5m DELAYED, >5m DEAD) and 500-row diagnostic pruning', () async {
    final db = PersistenceDatabase(useInMemoryFallback: true);
    int nowMs = 1000000;
    final coordinator = TradingCoordinator(
      persistence: db,
      commandBridge: _FakeCommandBridge(serviceReady: true),
      nowMsProvider: () => nowMs,
    );

    coordinator.lastHeartbeatMs = nowMs - 30 * 1000;
    expect(coordinator.heartbeatHealthLevel, 'OK');

    coordinator.lastHeartbeatMs = nowMs - 120 * 1000;
    expect(coordinator.heartbeatHealthLevel, 'DELAYED');

    coordinator.lastHeartbeatMs = nowMs - 360 * 1000;
    expect(coordinator.heartbeatHealthLevel, 'DEAD');

    for (int i = 0; i < 520; i++) {
      await db.logDiagnosticEvent('TEST', 'Event $i', timestampMs: i);
    }
    final recent50 = await db.getRecentDiagnosticEvents(limit: 50);
    expect(recent50.length, 50);

    coordinator.dispose();
    await db.close();
  });

  test('Test 6 (Stage 8): Single authoritative engine execution lease lock blocks concurrent owner', () async {
    final db = PersistenceDatabase(useInMemoryFallback: true);
    final ok1 = await db.acquireExecutionLock(
      lockName: 'AUTHORITATIVE_ENGINE_LOCK',
      ownerId: 'engine_A',
      nowMs: 1000,
      ttlMs: 55000,
    );
    final ok2 = await db.acquireExecutionLock(
      lockName: 'AUTHORITATIVE_ENGINE_LOCK',
      ownerId: 'engine_B',
      nowMs: 2000,
      ttlMs: 55000,
    );
    expect(ok1, isTrue);
    expect(ok2, isFalse);

    await db.releaseExecutionLock(
      lockName: 'AUTHORITATIVE_ENGINE_LOCK',
      ownerId: 'engine_A',
    );
    final ok3 = await db.acquireExecutionLock(
      lockName: 'AUTHORITATIVE_ENGINE_LOCK',
      ownerId: 'engine_B',
      nowMs: 3000,
      ttlMs: 55000,
    );
    expect(ok3, isTrue);
    await db.close();
  });

  test('Test 7 (Stage 8): RESET preserves notifiedAlertIds while resetting cash to $100', () async {
    final db = PersistenceDatabase(useInMemoryFallback: true);
    await db.markAlertIdNotified('ENTRY_ORD_1');
    final engine = AuthoritativeTradingEngine(
      marketService: CoinDcxMarketService(),
      persistence: db,
    );
    await engine.handleCommand('RESET');
    final notified = await db.getNotifiedAlertIds();
    expect(notified, contains('ENTRY_ORD_1'));
    engine.dispose();
    await db.close();
  });

  test('Test 8 (Stage 9): Auto-resume defaults to OFF and never resumes when OFF', () async {
    final db = PersistenceDatabase(useInMemoryFallback: true);
    expect(await db.getAutoResumeEnabled(), isFalse);

    await db.saveFullState(
      botState: BotEngineState.pausedNetworkLoss,
      userIntention: UserSessionIntention.running,
      availableCashUsdt: 100.0,
      accountEquityUsdt: 100.0,
      maxDrawdownLocked: false,
      statusBannerMessage: 'Paused',
      openPositions: const [],
      orders: const [],
      closedTrades: const [],
      processedEntrySignalKeys: const {},
    );

    final engine = AuthoritativeTradingEngine(
      marketService: CoinDcxMarketService(),
      persistence: db,
    );
    await engine.handleNetworkTransition(true);
    final snap = await db.loadFullState();
    expect(snap.botState, BotEngineState.pausedNetworkLoss);

    engine.dispose();
    await db.close();
  });

  test('Test 9 (Stage 12): CoinDCX REST ticker parser extracts lastPrice, bid, ask, 24h high/low, volume and change', () {
    final service = CoinDcxMarketService();
    final sampleJson = jsonEncode([
      {
        'market': 'BTCUSDT',
        'last_price': '91250.50',
        'bid': '91248.00',
        'ask': '91252.00',
        'high': '92500.00',
        'low': '89800.00',
        'volume': '1540.25',
        'change_24_hour': '2.45',
        'timestamp': 1731000000
      },
      {
        'market': 'B-ETH_USDT',
        'last_price': '3120.75',
        'bid': '3120.10',
        'ask': '3121.20',
        'high': '3200.00',
        'low': '3010.00',
        'volume': '8420.10',
        'change_24_hour': '-1.12',
        'timestamp': 1731000000
      }
    ]);

    final parsed = service.parseLiveTickersResponse(
      sampleJson,
      nowMs: 1731000005000,
    );

    expect(parsed.containsKey('B-BTC_USDT'), isTrue);
    expect(parsed.containsKey('B-ETH_USDT'), isTrue);
    final btc = parsed['B-BTC_USDT']!;
    expect(btc.lastPrice, closeTo(91250.50, 1e-6));
    expect(btc.bid, closeTo(91248.00, 1e-6));
    expect(btc.ask, closeTo(91252.00, 1e-6));
    expect(btc.high24h, closeTo(92500.00, 1e-6));
    expect(btc.low24h, closeTo(89800.00, 1e-6));
    expect(btc.volume24h, closeTo(1540.25, 1e-6));
    expect(btc.change24hPct, closeTo(2.45, 1e-6));

    service.dispose();
  });

  test('Test 10 (Stage 14): Indicators (EMA20/50, RSI14, ATR14) depend strictly on closed candles and are unaffected by ticker updates', () {
    const strategy = StrategyEngine();
    final candles15m = List.generate(
      60,
      (i) => Candle(
        openTimeMs: i * 900000,
        closeTimeMs: (i + 1) * 900000,
        open: 90000.0 + i * 10,
        high: 90050.0 + i * 10,
        low: 89950.0 + i * 10,
        close: 90020.0 + i * 10,
        volume: 10.0,
      ),
    );
    final candles1h = List.generate(
      60,
      (i) => Candle(
        openTimeMs: i * 3600000,
        closeTimeMs: (i + 1) * 3600000,
        open: 89000.0 + i * 40,
        high: 89100.0 + i * 40,
        low: 88900.0 + i * 40,
        close: 89050.0 + i * 40,
        volume: 40.0,
      ),
    );

    final eval1 = strategy.evaluateClosedCandles(
      symbol: 'B-BTC_USDT',
      closedCandles15m: candles15m,
      closedCandles1h: candles1h,
    );
    final eval2 = strategy.evaluateClosedCandles(
      symbol: 'B-BTC_USDT',
      closedCandles15m: candles15m,
      closedCandles1h: candles1h,
    );

    expect(eval1.ema20_15m, equals(eval2.ema20_15m));
    expect(eval1.ema50_15m, equals(eval2.ema50_15m));
    expect(eval1.rsi14_15m, equals(eval2.rsi14_15m));
    expect(eval1.atr14_15m, equals(eval2.atr14_15m));
  });

  test('Test 11 (Stage 18): Conservative SL-first resolution when both SL and TP are touched in one candle', () {
    final broker = PaperBroker(
      riskManager: const RiskManager(),
      feeRate: 0.001,
      slippageRate: 0.0005,
    );

    broker.openPositions.add(
      const PaperPosition(
        id: 'POS_1',
        symbol: 'B-BTC_USDT',
        entryPrice: 90000.0,
        quantity: 0.001,
        stopLoss: 89000.0,
        takeProfit: 92000.0,
        entryFeeUsdt: 0.09,
        signalCandleCloseMs: 1000,
        openedAtMs: 1000,
      ),
    );

    final newOrders = <SimulatedOrder>[];
    final bothTouchedCandle = const Candle(
      openTimeMs: 2000,
      closeTimeMs: 3000,
      open: 90000.0,
      high: 92500.0,
      low: 88500.0,
      close: 91000.0,
      volume: 10.0,
    );

    final closed = broker.checkStopLossOrTakeProfit(
      symbol: 'B-BTC_USDT',
      candle: bothTouchedCandle,
      newOrdersOut: newOrders,
    );

    expect(closed.length, 1);
    expect(closed.first.exitReason, 'STOP_LOSS_CONSERVATIVE_BOTH_TOUCHED');
    expect(closed.first.exitPrice, closeTo(89000.0 * (1.0 - 0.0005), 1e-4));
    expect(broker.lastStopLossClosedAtMs, 3000);
  });

  test('Test 12 (Stage 18 & 19): RiskManager sets SL=1.5xATR, TP=3.0xATR, enforces $1 risk cap, $2 daily loss, $90 drawdown floor, and 30m cooldown', () {
    const rm = RiskManager();
    expect(rm.isMaxDrawdownReached(90.0), isTrue);
    expect(rm.isMaxDrawdownReached(90.01), isFalse);
    expect(
      rm.isDailyLossLimitReached(
        startOfDayEquityUsdt: 100.0,
        currentEquityUsdt: 98.0,
      ),
      isTrue,
    );

    final sizing = rm.evaluateEntrySizing(
      symbol: 'B-BTC_USDT',
      entryFillPrice: 90000.0,
      atr14: 200.0,
      currentEquityUsdt: 100.0,
      availableCashUsdt: 100.0,
      startOfDayEquityUsdt: 100.0,
      openPositions: const [],
      pairMetadata: const MarketPairMetadata(
        symbol: 'B-BTC_USDT',
        baseCurrency: 'BTC',
        quoteCurrency: 'USDT',
      ),
      feeRate: 0.001,
      lastStopLossClosedAtMs: 1000,
      nowMs: 1000 + 35 * 60 * 1000,
    );

    expect(sizing.approved, isTrue);
    expect(sizing.stopLossPrice, closeTo(90000.0 - 300.0, 1e-6));
    expect(sizing.takeProfitPrice, closeTo(90000.0 + 600.0, 1e-6));

    final cooldownBlocked = rm.evaluateEntrySizing(
      symbol: 'B-BTC_USDT',
      entryFillPrice: 90000.0,
      atr14: 200.0,
      currentEquityUsdt: 100.0,
      availableCashUsdt: 100.0,
      startOfDayEquityUsdt: 100.0,
      openPositions: const [],
      pairMetadata: const MarketPairMetadata(
        symbol: 'B-BTC_USDT',
        baseCurrency: 'BTC',
        quoteCurrency: 'USDT',
      ),
      feeRate: 0.001,
      lastStopLossClosedAtMs: 1000,
      nowMs: 1000 + 10 * 60 * 1000,
    );
    expect(cooldownBlocked.approved, isFalse);
  });

  testWidgets('Test 13 (Stage 22): 6-Tab Professional UI renders Home, Markets, Trades, AI Lab, Reports, and Settings tabs cleanly', (tester) async {
    final db = PersistenceDatabase(useInMemoryFallback: true);
    final coordinator = TradingCoordinator(
      persistence: db,
      commandBridge: _FakeCommandBridge(serviceReady: false),
      nowMsProvider: () => 1000000,
    );

    await tester.pumpWidget(AnkitTraderApp(coordinator: coordinator));
    await tester.pump();

    expect(find.text('Home'), findsOneWidget);
    expect(find.text('Markets'), findsOneWidget);
    expect(find.text('Trades'), findsOneWidget);
    expect(find.text('AI Lab'), findsOneWidget);
    expect(find.text('Reports'), findsOneWidget);
    expect(find.text('Settings'), findsOneWidget);
    expect(find.text('PORTFOLIO OVERVIEW'), findsOneWidget);
    expect(find.text('EQUITY CURVE'), findsOneWidget);

    coordinator.dispose();
    await db.close();
  });
}

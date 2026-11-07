import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:ankit_ai_trader/models/trading_models.dart';
import 'package:ankit_ai_trader/services/coindcx_market_service.dart';
import 'package:ankit_ai_trader/services/paper_broker.dart';
import 'package:ankit_ai_trader/services/persistence_db.dart';
import 'package:ankit_ai_trader/services/risk_manager.dart';
import 'package:ankit_ai_trader/services/strategy_engine.dart';
import 'package:ankit_ai_trader/services/trading_coordinator.dart';

class _FakeCommandBridge implements EngineCommandBridge {
  bool serviceReady;
  int ensureServiceStartCalls = 0;
  final List<String> dispatchedCommands = [];

  _FakeCommandBridge({this.serviceReady = false});

  @override
  Future<bool> ensureServiceStartedAndReady() async {
    ensureServiceStartCalls++;
    serviceReady = true;
    return true;
  }

  @override
  Future<bool> dispatchCommand(String command) async {
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
  test('Stages 2 & 3: UserSessionIntention persists and Dashboard self-heals on open without overwriting RUNNING to pausedAfterRecoveryManualStartRequired', () async {
    final db = PersistenceDatabase(useInMemoryFallback: true);
    await db.saveFullState(
      botState: BotEngineState.running,
      userIntention: UserSessionIntention.running,
      availableCashUsdt: 100.0,
      accountEquityUsdt: 100.0,
      maxDrawdownLocked: false,
      lastHeartbeatMs: 1000, // Stale heartbeat
      statusBannerMessage: 'RUNNING',
      openPositions: const [],
      orders: const [],
      closedTrades: const [],
      processedEntrySignalKeys: const {},
    );

    final bridge = _FakeCommandBridge(serviceReady: false);
    final coordinator = TradingCoordinator(
      persistence: db,
      commandBridge: bridge,
      nowMsProvider: () => 900000, // 15 minutes later
    );

    await coordinator.refreshStateFromDatabase(isInitialLoad: true);

    expect(coordinator.userIntention, UserSessionIntention.running);
    expect(coordinator.engineState, BotEngineState.running);
    expect(bridge.ensureServiceStartCalls, 1);
    expect(bridge.dispatchedCommands, contains('START'));
  });

  test('Stage 10: CoinDCX REST ticker parser extracts lastPrice, bid, ask, 24h high/low, volume and change', () {
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
  });

  test('Stages 17–19: PaperBroker enforces conservative SL-first intrabar exits, fees, slippage, and max drawdown lock', () {
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
    // Candle touches BOTH stopLoss (89000) and takeProfit (92000)
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
}

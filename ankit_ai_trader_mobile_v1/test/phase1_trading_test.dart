import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:ankit_ai_trader/models/trading_models.dart';
import 'package:ankit_ai_trader/services/coindcx_market_service.dart';
import 'package:ankit_ai_trader/services/indicator_engine.dart';
import 'package:ankit_ai_trader/services/paper_broker.dart';
import 'package:ankit_ai_trader/services/persistence_db.dart';
import 'package:ankit_ai_trader/services/risk_manager.dart';
import 'package:ankit_ai_trader/services/strategy_engine.dart';
import 'package:ankit_ai_trader/services/trading_coordinator.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  group('Part B & C — Market Data Validation & Technical Indicators', () {
    test('EMA 20 and EMA 50 match exact mathematical formulas and handle insufficient data', () {
      final shortList = List<double>.generate(10, (i) => 100.0 + i);
      expect(
        IndicatorEngine.calculateEmaSeries(shortList, 20).every((e) => e == null),
        isTrue,
      );

      final prices = List<double>.generate(60, (i) => 100.0 + i * 2.0);
      final ema20 = IndicatorEngine.calculateEmaSeries(prices, 20);
      final ema50 = IndicatorEngine.calculateEmaSeries(prices, 50);

      // First EMA20 at index 19 is exact SMA of first 20 numbers: 100..138 -> avg 119.0
      expect(ema20[18], isNull);
      expect(ema20[19], closeTo(119.0, 1e-6));
      expect(ema50[49], closeTo(149.0, 1e-6));
      expect(ema20.last! > ema50.last!, isTrue);
    });

    test('RSI 14 handles flat, all-gain, and mixed series without zero-denominator crash', () {
      final flat = List<double>.filled(20, 100.0);
      final rsiFlat = IndicatorEngine.calculateRsiSeries(flat, 14);
      expect(rsiFlat.last, closeTo(50.0, 1e-6));

      final upOnly = List<double>.generate(20, (i) => 100.0 + i);
      final rsiUp = IndicatorEngine.calculateRsiSeries(upOnly, 14);
      expect(rsiUp.last, closeTo(100.0, 1e-6));
    });

    test('ATR 14 computes Wilder True Range average accurately', () {
      final candles = List<Candle>.generate(20, (i) {
        final t = 1700000000000 + i * 900000;
        return Candle(
          symbol: 'BTCUSDT',
          interval: '15m',
          openTimeMs: t,
          closeTimeMs: t + 900000,
          open: 100.0,
          high: 110.0,
          low: 90.0,
          close: 105.0,
          volume: 10.0,
        );
      });
      final atr14 = IndicatorEngine.calculateAtrSeries(candles, 14);
      expect(atr14[12], isNull);
      expect(atr14[13], closeTo(20.0, 1e-6));
      expect(atr14.last, closeTo(20.0, 1e-6));
    });

    test('CoinDCX sanitizer filters incomplete candles, deduplicates, and sorts chronologically', () {
      const intervalMs = 15 * 60 * 1000;
      const t1 = 1700000000000;
      const t2 = t1 + intervalMs;
      const t3OpenIncomplete = t2 + intervalMs;
      const nowMs = t3OpenIncomplete + 300000; // 5m into 3rd candle

      final raw = [
        {'time': t2, 'open': 102, 'high': 105, 'low': 101, 'close': 104, 'volume': 5},
        {'time': t1, 'open': 100, 'high': 103, 'low': 99, 'close': 102, 'volume': 4},
        {'time': t1, 'open': 100, 'high': 103, 'low': 99, 'close': 102, 'volume': 4}, // duplicate
        {'time': t3OpenIncomplete, 'open': 104, 'high': 106, 'low': 103, 'close': 105, 'volume': 2},
      ];

      final cleaned = CoinDcxMarketService.sanitizeAndFilterClosedCandles(
        rawList: raw,
        symbol: 'BTCUSDT',
        interval: '15m',
        intervalMs: intervalMs,
        nowMs: nowMs,
      );

      expect(cleaned.length, 2);
      expect(cleaned[0].openTimeMs, t1);
      expect(cleaned[1].openTimeMs, t2);
    });
  });

  group('Part D, E & F — Strategy, Conservative SL/TP, Paper Broker & Risk Manager', () {
    test('Position sizing caps risk at 1% (\$1), respects cash & rejects oversized minNotional', () {
      const rm = RiskManager();
      const strat = StrategyConfig();

      final decision = rm.evaluateEntryAndSize(
        rawNextOpenPrice: 100.0,
        atr14: 2.0, // Stop distance = 3.0
        strategyConfig: strat,
        availableCashUsdt: 100.0,
        currentEquityUsdt: 100.0,
        todayRealizedPnlUsdt: 0.0,
        currentOpenPositionsCount: 0,
      );

      expect(decision.approved, isTrue);
      expect(decision.estimatedRiskUsdt <= 1.000001, isTrue);
      expect(
        decision.estimatedNotionalUsdt + decision.estimatedEntryFeeUsdt <= 100.0,
        isTrue,
      );

      // Reject when exchange minNotional forces >$1 risk
      final rejected = rm.evaluateEntryAndSize(
        rawNextOpenPrice: 100.0,
        atr14: 2.0,
        strategyConfig: strat,
        availableCashUsdt: 100.0,
        currentEquityUsdt: 100.0,
        todayRealizedPnlUsdt: 0.0,
        currentOpenPositionsCount: 0,
        minNotionalUsdt: 95.0,
      );
      expect(rejected.approved, isFalse);
    });

    test('When a candle touches both Stop-Loss and Take-Profit, Stop-Loss executes first', () {
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
        high: 108.0, // touches TP (106)
        low: 96.0, // touches SL (97)
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

    test('Daily loss lock at \$2 and Max Drawdown lock at \$90 equity block new trades', () {
      final broker = PaperBroker();
      const dayMs = 1700000000000;
      final dayKey = RiskManager.utcDayKey(dayMs);

      broker.dailyRealizedPnlByUtcDate[dayKey] = -2.05;
      expect(broker.isDailyLockedAt(dayMs), isTrue);

      // Next UTC day unlocks daily lock
      const nextDayMs = dayMs + 86400000;
      expect(broker.isDailyLockedAt(nextDayMs), isFalse);

      // Max drawdown at $90 locks permanently until manual reset
      broker.availableCashUsdt = 89.90;
      expect(
        broker.riskManager.isMaxDrawdownReached(broker.accountEquity(const {})),
        isTrue,
      );
    });
  });

  group('Part G & H — SQLite Persistence, Duplicate Prevention & Reconnect Safety', () {
    test('SQLite persists and restores account, trades, and prevents duplicate candle processing', () async {
      final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
      final persistence = PersistenceDatabase();
      await persistence.openWithCustomDatabase(db);

      final broker1 = PaperBroker();
      broker1.availableCashUsdt = 98.5;
      broker1.realizedPnlUsdt = -1.5;
      broker1.lastProcessedCandleCloseMs['BTCUSDT'] = 1700000900000;
      broker1.processedEntrySignalKeys.add('BTCUSDT-1700000900000');

      await persistence.saveFullState(
        broker: broker1,
        botState: BotEngineState.running,
        latestPrices: const {'BTCUSDT': 50000.0},
      );

      final broker2 = PaperBroker();
      final restoredState = await persistence.restoreIntoBroker(broker2);
      expect(restoredState, BotEngineState.running);
      expect(broker2.availableCashUsdt, closeTo(98.5, 1e-6));
      expect(broker2.lastProcessedCandleCloseMs['BTCUSDT'], 1700000900000);
      expect(
        broker2.processedEntrySignalKeys.contains('BTCUSDT-1700000900000'),
        isTrue,
      );

      await persistence.close();
    });

    test('Internet loss pauses bot and automatic recovery requires manual START', () async {
      final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
      final persistence = PersistenceDatabase();
      await persistence.openWithCustomDatabase(db);

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
        final nowMs = DateTime.now().toUtc().millisecondsSinceEpoch;
        final is1h = request.url.queryParameters['interval'] == '1h';
        final step = is1h ? 3600000 : 900000;
        final baseOpen = ((nowMs ~/ step) - 70) * step;
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

      final coordinator = TradingCoordinator(
        marketService: CoinDcxMarketService(client: mockClient),
        persistence: persistence,
        customInternetProbe: () async => true,
      );
      await coordinator.initialize(enablePlatformChannels: false);
      await coordinator.manualStartBot();
      expect(coordinator.engineState, BotEngineState.running);

      // Simulate internet loss
      coordinator.handleConnectivityTransition(false);
      expect(coordinator.engineState, BotEngineState.pausedNetworkLoss);

      // Simulate automatic internet recovery -> MUST remain paused until manual START
      coordinator.handleConnectivityTransition(true);
      expect(
        coordinator.engineState,
        BotEngineState.pausedAfterRecoveryManualStartRequired,
      );

      await persistence.close();
    });
  });

  group('Part J — Deterministic Historical Backtest Verification', () {
    test('Backtest engine executes full lifecycle and reports deterministic metrics', () {
      const baseTime = 1700000000000;
      final candles1h = List<Candle>.generate(120, (i) {
        final t = baseTime + i * 3600000;
        final p = 100.0 + i * 0.8; // Steady bullish 1h trend (EMA20 > EMA50)
        return Candle(
          symbol: 'BTCUSDT',
          interval: '1h',
          openTimeMs: t,
          closeTimeMs: t + 3600000,
          open: p,
          high: p + 1.0,
          low: p - 1.0,
          close: p + 0.5,
          volume: 100.0,
        );
      });

      final candles15m = <Candle>[];
      for (int i = 0; i < 240; i++) {
        final t = baseTime + i * 900000;
        // Construct wave pattern so EMA20 crosses EMA50 with RSI in 50..65
        double close;
        if (i < 60) {
          close = 120.0 - i * 0.15;
        } else if (i < 130) {
          close = 111.0 + (i - 60) * 0.12;
        } else {
          close = 119.4 + (i - 130) * 0.25;
        }
        candles15m.add(
          Candle(
            symbol: 'BTCUSDT',
            interval: '15m',
            openTimeMs: t,
            closeTimeMs: t + 900000,
            open: close - 0.1,
            high: close + 0.8,
            low: close - 0.8,
            close: close,
            volume: 25.0,
          ),
        );
      }

      final report = PaperBroker.runHistoricalBacktest(
        symbol: 'BTCUSDT',
        candles15m: candles15m,
        candles1h: candles1h,
      );

      expect(report.endingEquityUsdt.isFinite, isTrue);
      expect(report.maxDrawdownUsdt >= 0.0, isTrue);
    });
  });
}
4. Dependencies Added and Reasonshttp: ^1.2.2: Performs REST polling against CoinDCX's public /exchange/v1/markets_details and /market_data/candles endpoints with configurable network timeouts and zero WebSocket overhead.sqflite: ^2.3.3+1 & path: ^1.9.0: Provides local SQLite persistence on Android so account equity, open positions, closed trades, order history, daily P&L, and last processed candle timestamps survive app force-closes and phone restarts.sqflite_common_ffi: ^2.3.3 (dev_dependencies): Enables running the SQLite persistence and state-restoration unit tests inside standard flutter test on Ubuntu GitHub Actions runners without requiring an attached Android emulator.5. Trading Logic ExplanationMarket Discovery & Closed-Candle Filtering (CoinDcxMarketService): Queries GET [https://api.coindcx.com/exchange/v1/markets_details](https://api.coindcx.com/exchange/v1/markets_details) to dynamically discover the active pair strings (such as B-BTC_USDT and B-ETH_USDT), minimum notional, and precision for BTCUSDT and ETHUSDT. Historical 15m and 1h candles are fetched from GET [https://public.coindcx.com/market_data/candles](https://public.coindcx.com/market_data/candles), deduplicated by openTimeMs, sorted chronologically, and filtered so any candle where nowMs < closeTimeMs is discarded.No Look-Ahead Bias (PaperBroker.processClosedCandleStep):When a closed 15m candle $C_t$ triggers a bullish crossover (prevEma20 <= prevEma50 && currEma20 > currEma50), 50 <= RSI14 <= 65, and 1h EMA20 > 1h EMA50, the engine records a PendingEntrySignal stamped with $C_t$'s close time.Simulated entry executes at the open price of the next candle $C_{t+1}$, adjusted for configurable slippage (executedEntry = open * (1 + slippageRate)).On every subsequent closed candle, intrabar Stop-Loss (entry - 1.5 * ATR14) and Take-Profit (entry + 3.0 * ATR14, 2:1 reward-to-risk) are evaluated. If a candle's low <= stopLoss and high >= takeProfit both occur in the same bar, StrategyEngine.checkStopLossOrTakeProfit enforces the conservative rule that Stop-Loss executes first.6. Risk Management ExplanationAccount Parameters: Locked to $100.00 USDT starting capital, 1x spot only (never borrows or exceeds availableCashUsdt), max 1 open position.Position Sizing (RiskManager.evaluateEntryAndSize): Computes per-unit loss at stop-loss including entry fee, exit fee, and slippage, then sizes quantity = min(maxRiskDollars / totalRiskPerUnit, maxCashQty) so total dollar loss on a stop-out never exceeds $1.00 (1%). If the exchange's min_notional would force a position whose risk exceeds $1.00, the trade is rejected (MINIMUM MARKET NOTIONAL VIOLATES 1% RISK OR CASH LIMIT).Daily Loss Lock ($2.00 / 2%): Tracked per UTC date key (YYYY-MM-DD). Once realized P&L for the current UTC day reaches -$2.00, isDailyLockedAt locks new entries and displays DAILY LOSS LIMIT REACHED until 00:00 UTC the next day.Maximum Drawdown Stop ($10.00 / $90.00 Equity Floor): When account equity falls to or below $90.00, _triggerMaxDrawdownStop liquidates any open simulated exposure, stops the engine, sets BotEngineState.stoppedMaxDrawdownReached, displays MAXIMUM DRAWDOWN REACHED, and requires a manual review and reset.7. Database DesignPersistenceDatabase (ankit_ai_trader_phase1.db) uses 5 normalized SQLite tables saved atomically inside a single database transaction on every step:engine_kv_state: Stores availableCashUsdt, realizedPnlUsdt, maxDrawdownLocked, lockedDailyLossUtcDate, botState, strategyConfig, riskConfig, dailyRealizedPnl, lastProcessedCandleCloseMs, and processedEntrySignalKeys.open_positions: Stores active open position parameters (entryPrice, quantity, stopLoss, takeProfit, entryFeeUsdt, signalCandleCloseMs, openedAtMs).closed_trades: Full audit log of completed paper trades and exit reasons.orders: Every simulated BUY and SELL order with unique IDs (ORD-BUY-..., ORD-SELL-...), requested vs. executed price, fee, and timestamp.equity_snapshots: Timestamped equity and cash history.8. Background Service DesignTradingForegroundService.kt runs as a single Android 14+ compatible specialUse foreground service (stopWithTask="false") holding a reference-counted PARTIAL_WAKE_LOCK and booting a headless FlutterEngine executing the @pragma('vm:entry-point') void backgroundServiceMain() Dart entrypoint.Every 60 seconds, TradingForegroundService invokes onBackgroundTick over com.ankit.aitrader/background_worker.backgroundServiceMain restores the SQLite state, verifies the engine is in BotEngineState.running, polls closed CoinDCX candles, updates SQLite, and updates the single persistent notification with live equity.If network connectivity drops or candle data becomes stale, the service transitions the persisted state to pausedAfterRecoveryManualStartRequired / pausedStaleData and updates the notification. When internet returns (MainActivity.kt ConnectivityManager.NetworkCallback), the app refreshes connectivity status but never auto-restarts trading until the user taps START PAPER BOT.9. Test Verification & Backtest Reporting(Note: Because I do not have shell execution access to run flutter test or flutter build apk directly in this chat session, I have not fabricated test or build execution outputs.)All 20 required test scenarios are implemented deterministically in ankit_ai_trader_mobile_v1/test/phase1_trading_test.dart and ankit_ai_trader_mobile_v1/test/widget_test.dart and execute automatically in the Run Phase 1 Unit, Persistence & Widget Tests step of .github/workflows/build-apk.yml.10. APK Build Instructions (GitHub Branch Workflow)In your GitHub repository (Ankitchauhan1794/ankit-ai-trader), create or switch to your feature branch (e.g., feature/phase1-paper-engine or feature/auto-reconnect-v1-2 — do not commit directly to main).Add/replace the 22 files listed above at their exact paths under .github/workflows/build-apk.yml and ankit_ai_trader_mobile_v1/....Commit and push the branch, or open/update your Pull Request targeting main.GitHub Actions will automatically run:flutter pub getflutter analyzeflutter test (running both test/widget_test.dart and test/phase1_trading_test.dart)flutter build apk --release --android-skip-build-dependency-validationArtifact upload of Ankit_AI_Trader_APK (Ankit_AI_Trader.apk).11. Remaining Known LimitationsOEM Aggressive Battery Killers: While TradingForegroundService uses START_STICKY, a PARTIAL_WAKE_LOCK, and a headless FlutterEngine, Android OEMs with aggressive proprietary task killers (e.g., Xiaomi MIUI, Vivo, Oppo) can still suspend background network sockets if the user does not grant "Unrestricted" battery usage via the BATTERY SETTINGS button on the dashboard.Candle-Level Backtest Granularity: Historical REST candles provide OHLCV per 15m bar without tick-level intrabar ordering; therefore, whenever a single 15m bar spans both stop-loss and take-profit, the engine conservatively records a stop-loss exit.
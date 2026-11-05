import '../models/trading_models.dart';
import 'coindcx_market_service.dart';
import 'paper_broker.dart';
import 'persistence_db.dart';
import 'strategy_engine.dart';

/// The SINGLE authoritative trading execution engine.
/// Hosted exclusively inside `TradingForegroundService`'s headless background Dart isolate.
/// The UI dashboard NEVER instantiates or runs this class to execute trades in production;
/// the dashboard only dispatches commands (`START`, `PAUSE`, `STOP`, `RESET`, `REFRESH_QUOTES`)
/// and reads committed state snapshots from `PersistenceDatabase`.
class AuthoritativeTradingEngine {
  static const String backgroundOwnerId = 'HEADLESS_FOREGROUND_SERVICE_ISOLATE';

  final CoinDcxMarketService marketService;
  final PersistenceDatabase persistence;
  final PaperBroker broker;
  final String ownerId;
  final Future<void> Function(String title, String text)? onNotificationUpdate;

  bool _isCycleRunning = false;

  AuthoritativeTradingEngine({
    required this.marketService,
    required this.persistence,
    PaperBroker? broker,
    this.ownerId = backgroundOwnerId,
    this.onNotificationUpdate,
  }) : broker = broker ?? PaperBroker();

  /// Handles commands dispatched from the UI (`START`, `PAUSE`, `STOP`, `RESET`, `REFRESH_QUOTES`).
  Future<bool> handleCommand(String command, {int? nowOverrideMs}) async {
    final nowMs =
        nowOverrideMs ?? DateTime.now().toUtc().millisecondsSinceEpoch;
    final acquired = await persistence.acquireExecutionLock(
      ownerId: ownerId,
      nowMs: nowMs,
    );
    if (!acquired) {
      return false;
    }

    try {
      final snap = await persistence.restoreFullSnapshot(broker);
      final prices = Map<String, double>.from(snap.latestPrices);

      switch (command) {
        case 'START':
          if (broker.maxDrawdownLocked ||
              broker.riskManager
                  .isMaxDrawdownReached(broker.accountEquity(prices))) {
            await persistence.saveFullState(
              broker: broker,
              botState: BotEngineState.stoppedMaxDrawdownReached,
              latestPrices: prices,
              marketDataStatus: snap.marketDataStatus,
              statusBannerMessage:
                  'MAXIMUM DRAWDOWN REACHED — MANUAL RESET REQUIRED',
            );
            return false;
          }
          await persistence.releaseExecutionLock(ownerId);
          return await executeAuthoritativeCycle(
            allowTradingExecution: true,
            transitionToRunningOnSuccess: true,
            nowOverrideMs: nowOverrideMs,
          );

        case 'PAUSE':
          await persistence.saveFullState(
            broker: broker,
            botState: BotEngineState.pausedAfterRecoveryManualStartRequired,
            latestPrices: prices,
            marketDataStatus: snap.marketDataStatus,
            statusBannerMessage: 'BOT PAUSED MANUALLY — PRESS START TO RESUME',
            lastMarketDataUpdateMs: snap.lastMarketDataUpdateMs,
            latestEvaluations: snap.latestEvaluations,
          );
          await _notify(
            'Ankit AI Trader — PAUSED',
            'Paused manually. Manual START required.',
          );
          return true;

        case 'STOP':
          await persistence.saveFullState(
            broker: broker,
            botState: BotEngineState.stopped,
            latestPrices: prices,
            marketDataStatus: snap.marketDataStatus,
            statusBannerMessage: 'ENGINE STOPPED BY USER',
            lastMarketDataUpdateMs: snap.lastMarketDataUpdateMs,
            latestEvaluations: snap.latestEvaluations,
          );
          await _notify(
            'Ankit AI Trader — STOPPED',
            'Engine stopped by user.',
          );
          return true;

        case 'RESET':
          broker.manualResetPaperAccount();
          await persistence.clearAllTables();
          await persistence.saveFullState(
            broker: broker,
            botState: BotEngineState.stopped,
            latestPrices: const {'BTCUSDT': 0.0, 'ETHUSDT': 0.0},
            marketDataStatus: MarketDataStatus.disconnected,
            statusBannerMessage: 'PAPER ACCOUNT RESET TO \$100.00 USDT',
          );
          await _notify(
            'Ankit AI Trader — RESET',
            'Paper account reset to \$100.00 USDT.',
          );
          return true;

        case 'REFRESH_QUOTES':
          await persistence.releaseExecutionLock(ownerId);
          return await executeAuthoritativeCycle(
            allowTradingExecution: false,
            transitionToRunningOnSuccess: false,
            nowOverrideMs: nowOverrideMs,
          );

        default:
          return false;
      }
    } finally {
      await persistence.releaseExecutionLock(ownerId);
    }
  }

  /// Handles network transitions reported to the authoritative service.
  /// - Network loss pauses the engine immediately.
  /// - Network recovery NEVER auto-restarts trading; requires manual START.
  Future<void> handleNetworkTransition(
    bool isConnected, {
    int? nowOverrideMs,
  }) async {
    final nowMs =
        nowOverrideMs ?? DateTime.now().toUtc().millisecondsSinceEpoch;
    final acquired = await persistence.acquireExecutionLock(
      ownerId: ownerId,
      nowMs: nowMs,
    );
    if (!acquired) return;

    try {
      final snap = await persistence.restoreFullSnapshot(broker);
      if (!isConnected) {
        final nextState = (snap.botState == BotEngineState.running ||
                snap.botState == BotEngineState.lockedDailyLossLimit)
            ? BotEngineState.pausedNetworkLoss
            : snap.botState;
        await persistence.saveFullState(
          broker: broker,
          botState: nextState,
          latestPrices: snap.latestPrices,
          marketDataStatus: MarketDataStatus.disconnected,
          statusBannerMessage:
              'INTERNET DISCONNECTED — BOT PAUSED FOR SAFETY',
          lastMarketDataUpdateMs: snap.lastMarketDataUpdateMs,
          latestEvaluations: snap.latestEvaluations,
        );
        await _notify(
          'Ankit AI Trader — OFFLINE',
          'Internet disconnected. Bot paused for safety.',
        );
      } else {
        final nextState = (snap.botState == BotEngineState.pausedNetworkLoss ||
                snap.botState == BotEngineState.running)
            ? BotEngineState.pausedAfterRecoveryManualStartRequired
            : snap.botState;
        await persistence.saveFullState(
          broker: broker,
          botState: nextState,
          latestPrices: snap.latestPrices,
          marketDataStatus: snap.marketDataStatus,
          statusBannerMessage:
              'INTERNET RECONNECTED — BOT PAUSED (MANUAL START REQUIRED)',
          lastMarketDataUpdateMs: snap.lastMarketDataUpdateMs,
          latestEvaluations: snap.latestEvaluations,
        );
        await _notify(
          'Ankit AI Trader — RECONNECTED (PAUSED)',
          'Internet restored. Manual START required to resume.',
        );
      }
    } finally {
      await persistence.releaseExecutionLock(ownerId);
    }
  }

  /// Executes a single authoritative market-data & strategy cycle protected by
  /// the SQLite execution lock.
  ///
  /// Keep-Alive Rule During Daily Loss Lock:
  /// If `botState == BotEngineState.lockedDailyLossLimit` and `broker.openPositions.isNotEmpty`,
  /// the engine remains alive to manage existing open positions against Stop-Loss and Take-Profit
  /// while blocking any new entries.
  Future<bool> executeAuthoritativeCycle({
    required bool allowTradingExecution,
    bool transitionToRunningOnSuccess = false,
    int? nowOverrideMs,
  }) async {
    if (_isCycleRunning) return false;
    _isCycleRunning = true;

    final nowMs =
        nowOverrideMs ?? DateTime.now().toUtc().millisecondsSinceEpoch;
    final acquired = await persistence.acquireExecutionLock(
      ownerId: ownerId,
      nowMs: nowMs,
    );
    if (!acquired) {
      _isCycleRunning = false;
      return false;
    }

    try {
      final snap = await persistence.restoreFullSnapshot(broker);
      final latestPrices = Map<String, double>.from(snap.latestPrices);
      final latestEvaluations =
          Map<String, StrategyEvaluationResult>.from(snap.latestEvaluations);

      final shouldManageActiveEngine = transitionToRunningOnSuccess ||
          snap.botState == BotEngineState.running ||
          (snap.botState == BotEngineState.lockedDailyLossLimit &&
              broker.openPositions.isNotEmpty);

      if (allowTradingExecution && !shouldManageActiveEngine) {
        return false;
      }

      final pairs = marketService.discoveredPairs.isNotEmpty
          ? marketService.discoveredPairs
          : await marketService.discoverActiveUsdtPairs();

      for (final symbol in ['BTCUSDT', 'ETHUSDT']) {
        final meta = pairs[symbol];
        if (meta == null) continue;

        final closed15m = await marketService.fetchClosedCandles(
          symbol: symbol,
          pair: meta.pair,
          interval: '15m',
          limit: 120,
          nowEpochMs: nowMs,
        );
        final closed1h = await marketService.fetchClosedCandles(
          symbol: symbol,
          pair: meta.pair,
          interval: '1h',
          limit: 120,
          nowEpochMs: nowMs,
        );

        if (closed15m.isEmpty || closed1h.isEmpty) {
          final nextState = shouldManageActiveEngine
              ? BotEngineState.pausedStaleData
              : snap.botState;
          await persistence.saveFullState(
            broker: broker,
            botState: nextState,
            latestPrices: latestPrices,
            marketDataStatus: MarketDataStatus.error,
            statusBannerMessage: 'PAUSED: EMPTY COINDCX CANDLE RESPONSE',
            lastMarketDataUpdateMs: snap.lastMarketDataUpdateMs,
            latestEvaluations: latestEvaluations,
          );
          return false;
        }

        // Validate BOTH 15m and 1h freshness and missing candle gaps
        final stale15m = CoinDcxMarketService.isDataStale(
          closedCandles: closed15m,
          interval: '15m',
          nowMs: nowMs,
        );
        final gap15m = CoinDcxMarketService.hasRecentMissingCandleGap(
          closedCandles: closed15m,
          interval: '15m',
        );
        final stale1h = CoinDcxMarketService.isDataStale(
          closedCandles: closed1h,
          interval: '1h',
          nowMs: nowMs,
        );
        final gap1h = CoinDcxMarketService.hasRecentMissingCandleGap(
          closedCandles: closed1h,
          interval: '1h',
        );

        if (stale15m || gap15m || stale1h || gap1h) {
          final nextState = shouldManageActiveEngine
              ? BotEngineState.pausedStaleData
              : snap.botState;
          await persistence.saveFullState(
            broker: broker,
            botState: nextState,
            latestPrices: latestPrices,
            marketDataStatus: MarketDataStatus.stale,
            statusBannerMessage:
                'PAUSED: STALE OR MISSING MARKET DATA (15M/1H)',
            lastMarketDataUpdateMs: snap.lastMarketDataUpdateMs,
            latestEvaluations: latestEvaluations,
          );
          await _notify(
            'Ankit AI Trader — DATA PAUSE',
            'Stale or missing 15m/1h market data. Trading paused.',
          );
          return false;
        }

        latestPrices[symbol] = closed15m.last.close;
        broker.ensureUtcDayBaseline(nowMs, latestPrices);

        if (allowTradingExecution && shouldManageActiveEngine) {
          final outcome = broker.processClosedCandleStream(
            symbol: symbol,
            closed15m: closed15m,
            closed1h: closed1h,
            latestPrices: latestPrices,
            minNotionalUsdt: meta.minNotional,
            minQuantity: meta.minQuantity,
          );
          if (outcome.evaluations.isNotEmpty) {
            latestEvaluations[symbol] = outcome.evaluations.last;
          }
          if (outcome.pausedOnMissingNextCandle) {
            await persistence.saveFullState(
              broker: broker,
              botState: BotEngineState.pausedStaleData,
              latestPrices: latestPrices,
              marketDataStatus: MarketDataStatus.stale,
              statusBannerMessage: outcome.pauseReason,
              lastMarketDataUpdateMs: nowMs,
              latestEvaluations: latestEvaluations,
            );
            await _notify(
              'Ankit AI Trader — GAP PAUSE',
              outcome.pauseReason,
            );
            return false;
          }
        } else {
          final passiveEval = broker.strategyEngine.evaluateClosedCandles(
            closed15m: closed15m,
            closed1h: closed1h,
            hasOpenPosition: broker.openPositions.containsKey(symbol),
          );
          latestEvaluations[symbol] = passiveEval;
        }
      }

      broker.enforceMaxDrawdownCheck(nowMs, latestPrices);

      BotEngineState nextState = snap.botState;
      String nextBanner = snap.statusBannerMessage;

      if (broker.maxDrawdownLocked) {
        nextState = BotEngineState.stoppedMaxDrawdownReached;
        nextBanner = broker.pendingEmergencyLiquidation
            ? 'MAXIMUM DRAWDOWN REACHED — PENDING EMERGENCY LIQUIDATION'
            : 'MAXIMUM DRAWDOWN REACHED — MANUAL RESET REQUIRED';
      } else if (broker.isDailyLockedAt(nowMs, latestPrices)) {
        nextState = BotEngineState.lockedDailyLossLimit;
        nextBanner = broker.openPositions.isNotEmpty
            ? 'DAILY LOSS LIMIT REACHED — MANAGING OPEN POSITION EXITS ONLY'
            : 'DAILY LOSS LIMIT REACHED';
      } else if (transitionToRunningOnSuccess ||
          snap.botState == BotEngineState.running ||
          snap.botState == BotEngineState.lockedDailyLossLimit) {
        nextState = BotEngineState.running;
        nextBanner =
            'BOT RUNNING — PROCESSING CLOSED 15M/1H COINDCX CANDLES';
      } else {
        nextBanner = 'MARKET QUOTES UPDATED — ENGINE ${nextState.name.toUpperCase()}';
      }

      await persistence.saveFullState(
        broker: broker,
        botState: nextState,
        latestPrices: latestPrices,
        marketDataStatus: MarketDataStatus.connected,
        statusBannerMessage: nextBanner,
        lastMarketDataUpdateMs: nowMs,
        latestEvaluations: latestEvaluations,
      );

      final eq = broker.accountEquity(latestPrices).toStringAsFixed(2);
      final btc = latestPrices['BTCUSDT']?.toStringAsFixed(2) ?? '--';
      await _notify(
        'Ankit AI Trader — Paper Engine',
        'State: ${nextState.name.toUpperCase()} | Eq: \$$eq | BTC: \$$btc',
      );
      return true;
    } catch (e) {
      try {
        final snap = await persistence.restoreFullSnapshot(broker);
        final shouldPause = transitionToRunningOnSuccess ||
            snap.botState == BotEngineState.running;
        final nextState = shouldPause
            ? BotEngineState.pausedAfterRecoveryManualStartRequired
            : snap.botState;
        await persistence.saveFullState(
          broker: broker,
          botState: nextState,
          latestPrices: snap.latestPrices,
          marketDataStatus: MarketDataStatus.error,
          statusBannerMessage:
              'MARKET DATA / NETWORK ERROR — BOT PAUSED (MANUAL START REQUIRED)',
          lastMarketDataUpdateMs: snap.lastMarketDataUpdateMs,
          latestEvaluations: snap.latestEvaluations,
        );
        await _notify(
          'Ankit AI Trader — PAUSED',
          'Market data interrupted. Manual START required.',
        );
      } catch (_) {
        // Never wipe or reset an existing account on DB error
      }
      return false;
    } finally {
      await persistence.releaseExecutionLock(ownerId);
      _isCycleRunning = false;
    }
  }

  Future<void> _notify(String title, String text) async {
    if (onNotificationUpdate != null) {
      await onNotificationUpdate!(title, text);
    }
  }
}

/// Dispatcher interface allowing tests or custom platform bridges to route
/// UI commands to the single `AuthoritativeTradingEngine`.
abstract class EngineCommandBridge {
  Future<bool> ensureServiceStartedAndReady();
  Future<bool> dispatchCommand(String command);
  Future<void> notifyNetworkChanged(bool isConnected);
  Future<bool> isServiceAndEngineReady();
}

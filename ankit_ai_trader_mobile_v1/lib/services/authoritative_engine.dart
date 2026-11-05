import '../models/trading_models.dart';
import 'coindcx_market_service.dart';
import 'paper_broker.dart';
import 'persistence_db.dart';
import 'strategy_engine.dart';
import 'trade_alert_formatter.dart';

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
  final Future<void> Function(TradeAlertPayload alert)? onTradeAlert;

  bool _isCycleRunning = false;

  AuthoritativeTradingEngine({
    required this.marketService,
    required this.persistence,
    PaperBroker? broker,
    this.ownerId = backgroundOwnerId,
    this.onNotificationUpdate,
    this.onTradeAlert,
  }) : broker = broker ?? PaperBroker();

  /// Sends a high-importance dismissible trade alert ONLY if:
  /// 1. `tradeAlertsEnabled` is currently `true` (ON) in SQLite `engine_kv_state`.
  /// 2. `alert.alertId` has never been notified before (persisted in SQLite `notifiedAlertIds`
  ///    and `lastNotifiedOrderId` so service restarts cannot send duplicate alerts).
  Future<bool> dispatchAlertIfEnabledAndNew(TradeAlertPayload alert) async {
    final enabled = await persistence.getTradeAlertsEnabled();
    if (!enabled) {
      return false;
    }
    final isNew = await persistence.markAlertIdNotified(alert.alertId);
    if (!isNew) {
      return false;
    }
    if (onTradeAlert != null) {
      await onTradeAlert!(alert);
    }
    return true;
  }

  /// Inspects any newly created orders/trades after a processing step and dispatches
  /// exactly one ENTRY or EXIT alert per new simulated order ID.
  Future<void> _emitAlertsForNewOrders({
    required Set<String> previousOrderIds,
    required Map<String, double> latestPrices,
  }) async {
    final newOrders = broker.orderHistory
        .where((o) => !previousOrderIds.contains(o.id))
        .toList()
        .reversed
        .toList();

    for (final order in newOrders) {
      if (order.side == 'BUY') {
        PaperPosition? matchedPos = broker.openPositions[order.symbol];
        if (matchedPos == null ||
            matchedPos.openedAtMs != order.executedAtMs) {
          // If position was opened and closed in the same batch, reconstruct from closedTrade
          final closedMatch = broker.closedTrades.where(
            (t) =>
                t.symbol == order.symbol && t.openedAtMs == order.executedAtMs,
          );
          if (closedMatch.isNotEmpty) {
            final ct = closedMatch.first;
            matchedPos = PaperPosition(
              id: 'POS-${order.id}',
              symbol: ct.symbol,
              entryPrice: ct.entryPrice,
              quantity: ct.quantity,
              stopLoss: ct.stopLoss,
              takeProfit: ct.takeProfit,
              entryFeeUsdt: order.feeUsdt,
              signalCandleCloseMs: order.signalCandleCloseMs,
              openedAtMs: ct.openedAtMs,
            );
          }
        }
        if (matchedPos != null) {
          final payload = TradeAlertFormatter.formatEntryAlert(
            buyOrder: order,
            position: matchedPos,
          );
          await dispatchAlertIfEnabledAndNew(payload);
        }
      } else if (order.side == 'SELL') {
        final closedMatches = broker.closedTrades.where(
          (t) =>
              t.symbol == order.symbol && t.closedAtMs == order.executedAtMs,
        );
        if (closedMatches.isNotEmpty) {
          final payload = TradeAlertFormatter.formatExitAlert(
            sellOrder: order,
            closedTrade: closedMatches.first,
            newAccountEquityUsdt: broker.accountEquity(latestPrices),
          );
          await dispatchAlertIfEnabledAndNew(payload);
        }
      }
    }
  }

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
            _formatOngoingNotificationText(
              BotEngineState.pausedAfterRecoveryManualStartRequired,
              prices,
            ),
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
            _formatOngoingNotificationText(BotEngineState.stopped, prices),
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
  /// - Network loss pauses the engine immediately and sends a PAPER TRADE safety lock alert.
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
        final wasActive = snap.botState == BotEngineState.running ||
            snap.botState == BotEngineState.lockedDailyLossLimit;
        final nextState =
            wasActive ? BotEngineState.pausedNetworkLoss : snap.botState;
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
        if (wasActive) {
          final lockAlert = TradeAlertFormatter.formatSafetyLockAlert(
            lockTypeKey: 'INTERNET_LOSS:$nowMs',
            lockTitle: 'INTERNET LOSS PAUSE',
            reasonDetail:
                'Internet disconnected. Paper bot paused for safety; manual START required after recovery.',
            currentEquityUsdt: broker.accountEquity(snap.latestPrices),
          );
          await dispatchAlertIfEnabledAndNew(lockAlert);
        }
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
      final previousOrderIds = broker.orderHistory.map((o) => o.id).toSet();
      final wasMaxDrawdownLocked = broker.maxDrawdownLocked;
      final previousDailyLockDate = broker.lockedDailyLossUtcDate;

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
        nextBanner =
            'MARKET QUOTES UPDATED — ENGINE ${nextState.name.toUpperCase()}';
      }

      // Fetch display-only live ticker prices after closed-candle strategy & SL/TP evaluation
      try {
        final liveTickers = await marketService.fetchLiveTickerPrices();
        for (final entry in liveTickers.entries) {
          if (entry.value > 0 && entry.value.isFinite) {
            latestPrices[entry.key] = entry.value;
          }
        }
      } catch (_) {
        // Fallback to closed-candle close prices if ticker endpoint is unavailable
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

      // Emit trade alerts for any newly opened or closed orders
      await _emitAlertsForNewOrders(
        previousOrderIds: previousOrderIds,
        latestPrices: latestPrices,
      );

      // Emit safety lock alerts if daily loss limit or $90 max drawdown floor just triggered
      final currentEq = broker.accountEquity(latestPrices);
      if (!wasMaxDrawdownLocked && broker.maxDrawdownLocked) {
        final ddAlert = TradeAlertFormatter.formatSafetyLockAlert(
          lockTypeKey: 'MAX_DRAWDOWN_EQUITY_FLOOR',
          lockTitle: 'MAX DRAWDOWN / \$90 EQUITY FLOOR REACHED',
          reasonDetail:
              'Account equity reached or fell below \$90.00 floor. Engine stopped; manual review & reset required.',
          currentEquityUsdt: currentEq,
        );
        await dispatchAlertIfEnabledAndNew(ddAlert);
      } else if (broker.lockedDailyLossUtcDate != null &&
          broker.lockedDailyLossUtcDate != previousDailyLockDate) {
        final dlAlert = TradeAlertFormatter.formatSafetyLockAlert(
          lockTypeKey: 'DAILY_LOSS_LIMIT:${broker.lockedDailyLossUtcDate}',
          lockTitle: 'DAILY LOSS LIMIT (\$2.00) REACHED',
          reasonDetail:
              'New entries locked for UTC day ${broker.lockedDailyLossUtcDate}. Open positions remain managed.',
          currentEquityUsdt: currentEq,
        );
        await dispatchAlertIfEnabledAndNew(dlAlert);
      }

      await _notify(
        'Ankit AI Trader — PAPER BOT ACTIVE',
        _formatOngoingNotificationText(nextState, latestPrices),
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

  String _formatOngoingNotificationText(
    BotEngineState state,
    Map<String, double> displayPrices,
  ) {
    final eq = broker.accountEquity(displayPrices).toStringAsFixed(2);
    final btcVal = displayPrices['BTCUSDT'] ?? 0.0;
    final ethVal = displayPrices['ETHUSDT'] ?? 0.0;
    final btc = btcVal > 0 ? btcVal.toStringAsFixed(2) : '--';
    final eth = ethVal > 0 ? ethVal.toStringAsFixed(2) : '--';
    return 'State: ${state.name.toUpperCase()} | Eq: \$$eq | BTC: \$$btc | ETH: \$$eth';
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

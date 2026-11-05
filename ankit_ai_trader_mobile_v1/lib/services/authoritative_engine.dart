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

  /// Bounded auto-recovery window: 10 minutes (600,000 ms).
  static const int maxAutoRecoveryWindowMs = 10 * 60 * 1000;

  /// Backoff schedule in milliseconds: 30s -> 60s -> 120s.
  static const List<int> recoveryBackoffScheduleMs = <int>[
    30 * 1000,
    60 * 1000,
    120 * 1000,
  ];

  final CoinDcxMarketService marketService;
  final PersistenceDatabase persistence;
  final PaperBroker broker;
  final String ownerId;
  final Future<void> Function(String title, String text)? onNotificationUpdate;
  final Future<void> Function(TradeAlertPayload alert)? onTradeAlert;
  final Future<void> Function(int delayMs, String reason)? onScheduleRetry;
  final Future<void> Function(int delayMs)? delayProvider;

  bool _isCycleRunning = false;
  int? _recoveryStartedAtMs;
  int _recoveryAttemptCount = 0;
  int? _nextRecoveryAllowedAtMs;
  final List<String> _recoveryLogs = <String>[];

  AuthoritativeTradingEngine({
    required this.marketService,
    required this.persistence,
    PaperBroker? broker,
    this.ownerId = backgroundOwnerId,
    this.onNotificationUpdate,
    this.onTradeAlert,
    this.onScheduleRetry,
    this.delayProvider,
  }) : broker = broker ?? PaperBroker();

  List<String> get recoveryLogs => List<String>.unmodifiable(_recoveryLogs);
  int get recoveryAttemptCount => _recoveryAttemptCount;
  int? get recoveryStartedAtMs => _recoveryStartedAtMs;
  int? get nextRecoveryAllowedAtMs => _nextRecoveryAllowedAtMs;

  static int backoffDelayMsForAttempt(int attemptOneBased) {
    if (attemptOneBased <= 1) return recoveryBackoffScheduleMs[0];
    if (attemptOneBased == 2) return recoveryBackoffScheduleMs[1];
    return recoveryBackoffScheduleMs[2];
  }

  /// Fetches closed candles for a single symbol with in-cycle bounded retry
  /// (30s -> 60s -> 120s) when `delayProvider` is configured, and logs each retry
  /// with reason + timestamp.
  Future<List<Candle>> _fetchClosedCandlesWithRetry({
    required String symbol,
    required String pair,
    required String interval,
    required int limit,
    required int nowMs,
  }) async {
    try {
      return await marketService.fetchClosedCandles(
        symbol: symbol,
        pair: pair,
        interval: interval,
        limit: limit,
        nowEpochMs: nowMs,
      );
    } catch (firstErr) {
      if (delayProvider == null) rethrow;
      Object lastError = firstErr;
      for (int attempt = 1;
          attempt <= recoveryBackoffScheduleMs.length;
          attempt++) {
        final delayMs = backoffDelayMsForAttempt(attempt);
        final tsIso =
            DateTime.fromMillisecondsSinceEpoch(nowMs, isUtc: true).toIso8601String();
        final entry =
            '[$tsIso] RETRY #$attempt (${delayMs ~/ 1000}s) $symbol ($interval): $lastError';
        _recoveryLogs.add(entry);
        await delayProvider!(delayMs);
        try {
          return await marketService.fetchClosedCandles(
            symbol: symbol,
            pair: pair,
            interval: interval,
            limit: limit,
            nowEpochMs: nowMs,
          );
        } catch (err) {
          lastError = err;
        }
      }
      throw lastError;
    }
  }

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

  Future<void> _resetRecoveryTracking() async {
    _recoveryStartedAtMs = null;
    _recoveryAttemptCount = 0;
    _nextRecoveryAllowedAtMs = null;
    await persistence.clearRecoveryState();
  }

  /// Handles bounded auto-recovery when a cycle encounters transient stale/gap/network failure.
  /// Retries with backoff 30s -> 60s -> 120s for up to 10 minutes (`maxAutoRecoveryWindowMs`),
  /// logging each retry with reason and UTC timestamp. Only pauses after 10 minutes have elapsed.
  /// Daily-loss and max-drawdown locks are never auto-recovered.
  Future<bool> _handleBoundedRecoveryOrPause({
    required PersistedEngineSnapshot snap,
    required Map<String, double> latestPrices,
    required Map<String, StrategyEvaluationResult> latestEvaluations,
    required MarketDataStatus failureStatus,
    required BotEngineState terminalPauseState,
    required String failureReason,
    required int nowMs,
    required bool shouldManageActiveEngine,
  }) async {
    await persistence.recordHeartbeat(nowMs);

    if (!shouldManageActiveEngine ||
        snap.botState == BotEngineState.stopped ||
        snap.botState == BotEngineState.stoppedMaxDrawdownReached ||
        snap.botState == BotEngineState.lockedDailyLossLimit) {
      await persistence.saveFullState(
        broker: broker,
        botState: snap.botState,
        latestPrices: latestPrices,
        closedCandlePrices: snap.closedCandlePrices,
        liveTickerPrices: snap.liveTickerPrices,
        marketDataStatus: failureStatus,
        statusBannerMessage: failureReason,
        lastMarketDataUpdateMs: snap.lastMarketDataUpdateMs,
        lastHeartbeatMs: nowMs,
        latestEvaluations: latestEvaluations,
        nowOverrideMs: nowMs,
      );
      return false;
    }

    final startedAt =
        _recoveryStartedAtMs ?? snap.recoveryStartedAtMs ?? nowMs;
    _recoveryStartedAtMs = startedAt;
    final elapsedMs = nowMs >= startedAt ? (nowMs - startedAt) : 0;

    if (elapsedMs >= maxAutoRecoveryWindowMs) {
      final tsIso =
          DateTime.fromMillisecondsSinceEpoch(nowMs, isUtc: true).toIso8601String();
      final finalLog =
          '[$tsIso] AUTO-RECOVERY EXHAUSTED (${elapsedMs ~/ 1000}s >= 600s): $failureReason -> PAUSED';
      _recoveryLogs.add(finalLog);

      await _resetRecoveryTracking();
      await persistence.saveFullState(
        broker: broker,
        botState: terminalPauseState,
        latestPrices: latestPrices,
        closedCandlePrices: snap.closedCandlePrices,
        liveTickerPrices: snap.liveTickerPrices,
        marketDataStatus: failureStatus,
        statusBannerMessage: 'PAUSED AFTER 10M AUTO-RECOVERY: $failureReason',
        lastMarketDataUpdateMs: snap.lastMarketDataUpdateMs,
        lastHeartbeatMs: nowMs,
        latestEvaluations: latestEvaluations,
        nowOverrideMs: nowMs,
      );
      await _notify(
        'Ankit AI Trader — PAUSED',
        'Auto-recovery exhausted (10m): $failureReason',
      );
      return false;
    }

    _recoveryAttemptCount =
        (_recoveryAttemptCount > 0 ? _recoveryAttemptCount : snap.recoveryAttemptCount) + 1;
    final delayMs = backoffDelayMsForAttempt(_recoveryAttemptCount);
    _nextRecoveryAllowedAtMs = nowMs + delayMs;

    final tsIso =
        DateTime.fromMillisecondsSinceEpoch(nowMs, isUtc: true).toIso8601String();
    final logEntry =
        '[$tsIso] AUTO-RETRY #$_recoveryAttemptCount in ${delayMs ~/ 1000}s (elapsed ${elapsedMs ~/ 1000}s/600s): $failureReason';
    _recoveryLogs.add(logEntry);

    await persistence.saveRecoveryState(
      recoveryStartedAtMs: _recoveryStartedAtMs,
      recoveryAttemptCount: _recoveryAttemptCount,
      nextRecoveryAllowedAtMs: _nextRecoveryAllowedAtMs,
      recoveryLogs: _recoveryLogs,
    );

    // Keep botState as RUNNING during the 10-minute bounded recovery window
    await persistence.saveFullState(
      broker: broker,
      botState: BotEngineState.running,
      latestPrices: latestPrices,
      closedCandlePrices: snap.closedCandlePrices,
      liveTickerPrices: snap.liveTickerPrices,
      marketDataStatus: failureStatus,
      statusBannerMessage:
          'AUTO-RECOVERY RETRY #$_recoveryAttemptCount (${delayMs ~/ 1000}S BACKOFF) — $failureReason',
      lastMarketDataUpdateMs: snap.lastMarketDataUpdateMs,
      lastHeartbeatMs: nowMs,
      latestEvaluations: latestEvaluations,
      nowOverrideMs: nowMs,
    );

    await _notify(
      'Ankit AI Trader — AUTO-RECOVERY #$_recoveryAttemptCount',
      'Retrying in ${delayMs ~/ 1000}s ($failureReason)',
    );

    if (onScheduleRetry != null) {
      await onScheduleRetry!(delayMs, failureReason);
    }
    return false;
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
      await persistence.recordHeartbeat(nowMs);
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
              closedCandlePrices: snap.closedCandlePrices,
              liveTickerPrices: snap.liveTickerPrices,
              marketDataStatus: snap.marketDataStatus,
              statusBannerMessage:
                  'MAXIMUM DRAWDOWN REACHED — MANUAL RESET REQUIRED',
              lastHeartbeatMs: nowMs,
              nowOverrideMs: nowMs,
            );
            return false;
          }
          await _resetRecoveryTracking();
          await persistence.releaseExecutionLock(ownerId);
          return await executeAuthoritativeCycle(
            allowTradingExecution: true,
            transitionToRunningOnSuccess: true,
            nowOverrideMs: nowOverrideMs,
          );

        case 'PAUSE':
          await _resetRecoveryTracking();
          await persistence.saveFullState(
            broker: broker,
            botState: BotEngineState.pausedAfterRecoveryManualStartRequired,
            latestPrices: prices,
            closedCandlePrices: snap.closedCandlePrices,
            liveTickerPrices: snap.liveTickerPrices,
            marketDataStatus: snap.marketDataStatus,
            statusBannerMessage: 'BOT PAUSED MANUALLY — PRESS START TO RESUME',
            lastMarketDataUpdateMs: snap.lastMarketDataUpdateMs,
            lastHeartbeatMs: nowMs,
            latestEvaluations: snap.latestEvaluations,
            nowOverrideMs: nowMs,
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
          // Explicit STOP must stop the bot and clear any pending auto-recovery so it NEVER auto-restarts.
          await _resetRecoveryTracking();
          await persistence.saveFullState(
            broker: broker,
            botState: BotEngineState.stopped,
            latestPrices: prices,
            closedCandlePrices: snap.closedCandlePrices,
            liveTickerPrices: snap.liveTickerPrices,
            marketDataStatus: snap.marketDataStatus,
            statusBannerMessage: 'ENGINE STOPPED BY USER',
            lastMarketDataUpdateMs: snap.lastMarketDataUpdateMs,
            lastHeartbeatMs: nowMs,
            latestEvaluations: snap.latestEvaluations,
            nowOverrideMs: nowMs,
          );
          await _notify(
            'Ankit AI Trader — STOPPED',
            _formatOngoingNotificationText(BotEngineState.stopped, prices),
          );
          return true;

        case 'RESET':
          await _resetRecoveryTracking();
          broker.manualResetPaperAccount();
          await persistence.clearAllTables();
          await persistence.saveFullState(
            broker: broker,
            botState: BotEngineState.stopped,
            latestPrices: const {'BTCUSDT': 0.0, 'ETHUSDT': 0.0},
            marketDataStatus: MarketDataStatus.disconnected,
            statusBannerMessage: 'PAPER ACCOUNT RESET TO \$100.00 USDT',
            lastHeartbeatMs: nowMs,
            nowOverrideMs: nowMs,
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
  /// - Network recovery NEVER auto-restarts trading if paused; requires manual START.
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
      await persistence.recordHeartbeat(nowMs);
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
          closedCandlePrices: snap.closedCandlePrices,
          liveTickerPrices: snap.liveTickerPrices,
          marketDataStatus: MarketDataStatus.disconnected,
          statusBannerMessage:
              'INTERNET DISCONNECTED — BOT PAUSED FOR SAFETY',
          lastMarketDataUpdateMs: snap.lastMarketDataUpdateMs,
          lastHeartbeatMs: nowMs,
          latestEvaluations: snap.latestEvaluations,
          nowOverrideMs: nowMs,
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
          closedCandlePrices: snap.closedCandlePrices,
          liveTickerPrices: snap.liveTickerPrices,
          marketDataStatus: snap.marketDataStatus,
          statusBannerMessage:
              'INTERNET RECONNECTED — BOT PAUSED (MANUAL START REQUIRED)',
          lastMarketDataUpdateMs: snap.lastMarketDataUpdateMs,
          lastHeartbeatMs: nowMs,
          latestEvaluations: snap.latestEvaluations,
          nowOverrideMs: nowMs,
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
      // Step 1(d): Write heartbeat timestamp to SQLite from the background isolate on every tick
      await persistence.recordHeartbeat(nowMs);

      final snap = await persistence.restoreFullSnapshot(broker);
      _recoveryStartedAtMs ??= snap.recoveryStartedAtMs;
      if (_recoveryAttemptCount == 0 && snap.recoveryAttemptCount > 0) {
        _recoveryAttemptCount = snap.recoveryAttemptCount;
      }
      _nextRecoveryAllowedAtMs ??= snap.nextRecoveryAllowedAtMs;

      final latestPrices = Map<String, double>.from(snap.latestPrices);
      final latestEvaluations =
          Map<String, StrategyEvaluationResult>.from(snap.latestEvaluations);
      final previousOrderIds = broker.orderHistory.map((o) => o.id).toSet();
      final wasMaxDrawdownLocked = broker.maxDrawdownLocked;
      final previousDailyLockDate = broker.lockedDailyLossUtcDate;

      // Step 1(f): Explicit STOP, Max Drawdown lock, or manual PAUSE must NEVER auto-restart on background ticks.
      final shouldManageActiveEngine = transitionToRunningOnSuccess ||
          snap.botState == BotEngineState.running ||
          (snap.botState == BotEngineState.lockedDailyLossLimit &&
              broker.openPositions.isNotEmpty);

      if (allowTradingExecution && !shouldManageActiveEngine) {
        return false;
      }

      // Respect backoff schedule if a retry is pending and this is an unforced tick
      if (!transitionToRunningOnSuccess &&
          _nextRecoveryAllowedAtMs != null &&
          nowMs < _nextRecoveryAllowedAtMs!) {
        return false;
      }

      Map<String, MarketPairMetadata> pairs;
      try {
        pairs = marketService.discoveredPairs.isNotEmpty
            ? marketService.discoveredPairs
            : await marketService.discoverActiveUsdtPairs();
      } catch (e) {
        return await _handleBoundedRecoveryOrPause(
          snap: snap,
          latestPrices: latestPrices,
          latestEvaluations: latestEvaluations,
          failureStatus: MarketDataStatus.error,
          terminalPauseState:
              BotEngineState.pausedAfterRecoveryManualStartRequired,
          failureReason: 'PAIR DISCOVERY FAILED: $e',
          nowMs: nowMs,
          shouldManageActiveEngine: shouldManageActiveEngine,
        );
      }

      const targetSymbols = <String>['BTCUSDT', 'ETHUSDT'];
      final symbolSuccess = <String, bool>{};
      final symbolErrors = <String, String>{};
      final symbolFailureStatus = <String, MarketDataStatus>{};

      // Step 1(c): Per-symbol isolation — separate try/catch per symbol.
      // A BTC failure must not skip ETH, and must not save the whole engine as paused if ETH succeeded.
      for (final symbol in targetSymbols) {
        try {
          final meta = pairs[symbol];
          if (meta == null) {
            symbolSuccess[symbol] = false;
            symbolErrors[symbol] = '$symbol metadata missing';
            symbolFailureStatus[symbol] = MarketDataStatus.error;
            continue;
          }

          final closed15m = await _fetchClosedCandlesWithRetry(
            symbol: symbol,
            pair: meta.pair,
            interval: '15m',
            limit: 120,
            nowMs: nowMs,
          );
          final closed1h = await _fetchClosedCandlesWithRetry(
            symbol: symbol,
            pair: meta.pair,
            interval: '1h',
            limit: 120,
            nowMs: nowMs,
          );

          if (closed15m.isEmpty || closed1h.isEmpty) {
            symbolSuccess[symbol] = false;
            symbolErrors[symbol] = 'EMPTY COINDCX CANDLE RESPONSE ($symbol)';
            symbolFailureStatus[symbol] = MarketDataStatus.error;
            continue;
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
            symbolSuccess[symbol] = false;
            symbolErrors[symbol] =
                'STALE OR MISSING MARKET DATA (15M/1H) FOR $symbol';
            symbolFailureStatus[symbol] = MarketDataStatus.stale;
            continue;
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
              symbolSuccess[symbol] = false;
              symbolErrors[symbol] = outcome.pauseReason;
              symbolFailureStatus[symbol] = MarketDataStatus.stale;
              continue;
            }
          } else {
            final passiveEval = broker.strategyEngine.evaluateClosedCandles(
              closed15m: closed15m,
              closed1h: closed1h,
              hasOpenPosition: broker.openPositions.containsKey(symbol),
            );
            latestEvaluations[symbol] = passiveEval;
          }

          symbolSuccess[symbol] = true;
        } catch (symErr) {
          symbolSuccess[symbol] = false;
          symbolErrors[symbol] = '$symbol ERROR: $symErr';
          symbolFailureStatus[symbol] = MarketDataStatus.error;
        }
      }

      final anySymbolSucceeded =
          symbolSuccess.values.any((succeeded) => succeeded);

      if (!anySymbolSucceeded) {
        final combinedReason = symbolErrors.values.join(' | ');
        final anyStale = symbolFailureStatus.values
            .any((s) => s == MarketDataStatus.stale);
        final status =
            anyStale ? MarketDataStatus.stale : MarketDataStatus.error;
        final terminalPause = anyStale
            ? BotEngineState.pausedStaleData
            : BotEngineState.pausedAfterRecoveryManualStartRequired;

        return await _handleBoundedRecoveryOrPause(
          snap: snap,
          latestPrices: latestPrices,
          latestEvaluations: latestEvaluations,
          failureStatus: status,
          terminalPauseState: terminalPause,
          failureReason: combinedReason.isNotEmpty
              ? combinedReason
              : 'ALL SYMBOLS FAILED MARKET DATA VALIDATION',
          nowMs: nowMs,
          shouldManageActiveEngine: shouldManageActiveEngine,
        );
      }

      // At least one symbol succeeded: reset bounded recovery counters
      await _resetRecoveryTracking();

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
        if (symbolErrors.isNotEmpty) {
          final degradedNote = symbolErrors.entries
              .map((e) => '${e.key} DEGRADED (${e.value})')
              .join('; ');
          nextBanner =
              'BOT RUNNING (PARTIAL FEED: $degradedNote)';
        } else {
          nextBanner =
              'BOT RUNNING — PROCESSING CLOSED 15M/1H COINDCX CANDLES';
        }
      } else {
        nextBanner =
            'MARKET QUOTES UPDATED — ENGINE ${nextState.name.toUpperCase()}';
      }

      final closedCandlePrices = Map<String, double>.from(latestPrices);
      final liveTickerPrices = Map<String, double>.from(snap.liveTickerPrices);

      // Fetch display-only live ticker prices after closed-candle strategy & SL/TP evaluation
      try {
        final liveTickers = await marketService.fetchLiveTickerPrices();
        for (final entry in liveTickers.entries) {
          if (entry.value > 0 && entry.value.isFinite) {
            liveTickerPrices[entry.key] = entry.value;
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
        closedCandlePrices: closedCandlePrices,
        liveTickerPrices: liveTickerPrices,
        marketDataStatus: MarketDataStatus.connected,
        statusBannerMessage: nextBanner,
        lastMarketDataUpdateMs: nowMs,
        lastHeartbeatMs: nowMs,
        latestEvaluations: latestEvaluations,
        nowOverrideMs: nowMs,
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
        final shouldManage = transitionToRunningOnSuccess ||
            snap.botState == BotEngineState.running;
        return await _handleBoundedRecoveryOrPause(
          snap: snap,
          latestPrices: Map<String, double>.from(snap.latestPrices),
          latestEvaluations:
              Map<String, StrategyEvaluationResult>.from(snap.latestEvaluations),
          failureStatus: MarketDataStatus.error,
          terminalPauseState:
              BotEngineState.pausedAfterRecoveryManualStartRequired,
          failureReason: 'CYCLE EXCEPTION: $e',
          nowMs: nowMs,
          shouldManageActiveEngine: shouldManage,
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

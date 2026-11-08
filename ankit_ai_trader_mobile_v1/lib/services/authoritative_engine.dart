import 'dart:async';
import '../models/trading_models.dart';
import 'coindcx_market_service.dart';
import 'paper_broker.dart';
import 'persistence_db.dart';
import 'strategy_engine.dart';
import 'trade_alert_formatter.dart';

class AuthoritativeTradingEngine {
  static const String authoritativeLockName = 'AUTHORITATIVE_ENGINE_LOCK';
  static const List<String> watchedSymbols = ['B-BTC_USDT', 'B-ETH_USDT'];

  final CoinDcxMarketService marketService;
  final PersistenceDatabase persistence;
  final PaperBroker broker;
  final StrategyEngine strategyEngine;
  final int Function() nowMsProvider;
  final Future<void> Function(String title, String text)? onNotificationUpdate;
  final Future<bool> Function(TradeAlertPayload alert)? onTradeAlert;
  final Future<void> Function(int delayMs, String reason)? onSchedulerRetry;
  final Future<void> Function(UserSessionIntention intention)?
      onSyncUserIntention;

  final String _ownerId;
  bool _isCycleExecuting = false;
  Timer? _retryTimer;

  AuthoritativeTradingEngine({
    required this.marketService,
    required this.persistence,
    PaperBroker? broker,
    this.strategyEngine = const StrategyEngine(),
    int Function()? nowMsProvider,
    this.onNotificationUpdate,
    this.onTradeAlert,
    this.onSchedulerRetry,
    this.onSyncUserIntention,
  })  : broker = broker ?? PaperBroker(),
        nowMsProvider =
            nowMsProvider ?? (() => DateTime.now().millisecondsSinceEpoch),
        _ownerId = 'auth_engine_${DateTime.now().microsecondsSinceEpoch}';

  /// Stage 6: Process-death recreation restarts trading ONLY if intention == RUNNING.
  Future<void> restoreSessionIfRunningIntended() async {
    final snap = await persistence.loadFullState();
    _hydrateBrokerFromSnapshot(snap);
    if (snap.userIntention == UserSessionIntention.running &&
        snap.botState != BotEngineState.stoppedMaxDrawdownReached &&
        snap.botState != BotEngineState.lockedDailyLossLimit) {
      await persistence.logDiagnosticEvent(
        'PROCESS_RESTORE',
        'Headless engine initialized; restoring RUNNING session',
      );
      await executeAuthoritativeCycle(
        allowTradingExecution: true,
        transitionToRunningOnSuccess: true,
      );
    }
  }

  void _hydrateBrokerFromSnapshot(PersistedEngineSnapshot snap) {
    broker.availableCashUsdt = snap.availableCashUsdt;
    broker.maxDrawdownLocked = snap.maxDrawdownLocked;
    broker.lockedDailyLossUtcDate = snap.lockedDailyLossUtcDate;
    broker.lastStopLossClosedAtMs = snap.lastStopLossClosedAtMs;
    broker.openPositions
      ..clear()
      ..addAll(snap.openPositions);
    broker.orders
      ..clear()
      ..addAll(snap.orders);
    broker.closedTrades
      ..clear()
      ..addAll(snap.closedTrades);
    broker.processedEntrySignalKeys
      ..clear()
      ..addAll(snap.processedEntrySignalKeys);
  }

  Future<bool> handleCommand(String command) async {
    final cmd = command.trim().toUpperCase();
    final nowMs = nowMsProvider();
    final snap = await persistence.loadFullState();
    _hydrateBrokerFromSnapshot(snap);

    switch (cmd) {
      case 'START':
        if (broker.maxDrawdownLocked ||
            broker.riskManager.isMaxDrawdownReached(snap.accountEquityUsdt)) {
          // Stage 3: Safety lock changes botState ONLY, never userIntention
          await persistence.saveFullState(
            botState: BotEngineState.stoppedMaxDrawdownReached,
            availableCashUsdt: broker.availableCashUsdt,
            accountEquityUsdt: snap.accountEquityUsdt,
            maxDrawdownLocked: true,
            lockedDailyLossUtcDate: broker.lockedDailyLossUtcDate,
            lastStopLossClosedAtMs: broker.lastStopLossClosedAtMs,
            lastHeartbeatMs: nowMs,
            statusBannerMessage:
                'Account equity reached or fell below \$90.00 floor. Engine stopped; manual review & reset required.',
            liveTickerPrices: snap.liveTickerPrices,
            liveTickers: snap.liveTickers,
            closedCandlePrices: snap.closedCandlePrices,
            whyNoTradeForSymbol: snap.whyNoTradeForSymbol,
            openPositions: broker.openPositions,
            orders: broker.orders,
            closedTrades: broker.closedTrades,
            processedEntrySignalKeys: broker.processedEntrySignalKeys,
          );
          return false;
        }
        await persistence.saveUserIntention(UserSessionIntention.running);
        await onSyncUserIntention?.call(UserSessionIntention.running);
        await _resetRecoveryTracking();
        return await executeAuthoritativeCycle(
          allowTradingExecution: true,
          transitionToRunningOnSuccess: true,
        );

      case 'PAUSE':
        _retryTimer?.cancel();
        await _resetRecoveryTracking();
        await persistence.saveFullState(
          botState: BotEngineState.pausedAfterRecoveryManualStartRequired,
          userIntention: UserSessionIntention.paused,
          availableCashUsdt: broker.availableCashUsdt,
          accountEquityUsdt: snap.accountEquityUsdt,
          maxDrawdownLocked: broker.maxDrawdownLocked,
          lockedDailyLossUtcDate: broker.lockedDailyLossUtcDate,
          lastStopLossClosedAtMs: broker.lastStopLossClosedAtMs,
          lastHeartbeatMs: nowMs,
          runningSinceMs: null,
          totalActiveMs: snap.totalActiveMs,
          statusBannerMessage: 'BOT PAUSED MANUALLY – PRESS RESUME TO CONTINUE',
          liveTickerPrices: snap.liveTickerPrices,
          liveTickers: snap.liveTickers,
          closedCandlePrices: snap.closedCandlePrices,
          whyNoTradeForSymbol: snap.whyNoTradeForSymbol,
          openPositions: broker.openPositions,
          orders: broker.orders,
          closedTrades: broker.closedTrades,
          processedEntrySignalKeys: broker.processedEntrySignalKeys,
        );
        await onSyncUserIntention?.call(UserSessionIntention.paused);
        await _notify(
          'Ankit AI Trader — PAUSED',
          _formatOngoingNotificationText(
            snap.accountEquityUsdt,
            snap.liveTickerPrices,
          ),
        );
        return true;

      case 'STOP':
        _retryTimer?.cancel();
        await _resetRecoveryTracking();
        await persistence.saveFullState(
          botState: BotEngineState.stopped,
          userIntention: UserSessionIntention.stopped,
          availableCashUsdt: broker.availableCashUsdt,
          accountEquityUsdt: snap.accountEquityUsdt,
          maxDrawdownLocked: broker.maxDrawdownLocked,
          lockedDailyLossUtcDate: broker.lockedDailyLossUtcDate,
          lastStopLossClosedAtMs: broker.lastStopLossClosedAtMs,
          lastHeartbeatMs: nowMs,
          runningSinceMs: null,
          totalActiveMs: snap.totalActiveMs,
          statusBannerMessage: 'ENGINE STOPPED BY USER',
          liveTickerPrices: snap.liveTickerPrices,
          liveTickers: snap.liveTickers,
          closedCandlePrices: snap.closedCandlePrices,
          whyNoTradeForSymbol: snap.whyNoTradeForSymbol,
          openPositions: broker.openPositions,
          orders: broker.orders,
          closedTrades: broker.closedTrades,
          processedEntrySignalKeys: broker.processedEntrySignalKeys,
        );
        await onSyncUserIntention?.call(UserSessionIntention.stopped);
        return true;

      case 'RESET':
        _retryTimer?.cancel();
        await _resetRecoveryTracking();
        // Stage 8: Preserve notifiedAlertIds across RESET
        final preservedAlerts = await persistence.getNotifiedAlertIds();
        broker.manualResetPaperAccount();
        await persistence.saveFullState(
          botState: BotEngineState.stopped,
          userIntention: UserSessionIntention.stopped,
          availableCashUsdt: broker.availableCashUsdt,
          accountEquityUsdt: broker.availableCashUsdt,
          maxDrawdownLocked: false,
          lockedDailyLossUtcDate: null,
          lastStopLossClosedAtMs: null,
          lastHeartbeatMs: nowMs,
          runningSinceMs: null,
          totalActiveMs: 0,
          statusBannerMessage: 'Paper account reset to \$100.00 USDT.',
          liveTickerPrices: snap.liveTickerPrices,
          liveTickers: snap.liveTickers,
          closedCandlePrices: snap.closedCandlePrices,
          whyNoTradeForSymbol: const {},
          openPositions: const [],
          orders: const [],
          closedTrades: const [],
          processedEntrySignalKeys: const {},
        );
        for (final id in preservedAlerts) {
          await persistence.markAlertIdNotified(id);
        }
        await onSyncUserIntention?.call(UserSessionIntention.stopped);
        return true;

      case 'REFRESH_QUOTES':
        return await executeAuthoritativeCycle(
          allowTradingExecution: false,
          transitionToRunningOnSuccess: false,
        );

      default:
        return false;
    }
  }

  /// Stage 8: Single authoritative engine execution covered by SQLite lease lock.
  Future<bool> executeAuthoritativeCycle({
    required bool allowTradingExecution,
    bool transitionToRunningOnSuccess = false,
  }) async {
    if (_isCycleExecuting) return false;
    _isCycleExecuting = true;
    final nowMs = nowMsProvider();

    try {
      final acquired = await persistence.acquireExecutionLock(
        lockName: authoritativeLockName,
        ownerId: _ownerId,
        nowMs: nowMs,
        ttlMs: 55000,
      );
      if (!acquired) return false;

      await persistence.recordHeartbeat(nowMs);
      final snap = await persistence.loadFullState();
      _hydrateBrokerFromSnapshot(snap);

      // Stage 3 & 6: Never auto-run if userIntention is STOPPED or PAUSED
      final userWantsRunning = transitionToRunningOnSuccess ||
          snap.userIntention == UserSessionIntention.running;

      if (!userWantsRunning && allowTradingExecution) {
        return true;
      }

      if (snap.botState == BotEngineState.stoppedMaxDrawdownReached ||
          snap.botState == BotEngineState.lockedDailyLossLimit) {
        return false;
      }

      // Stage 12 & 14: Fetch live tickers for current price, equity, uPnL & live SL/TP
      Map<String, LiveMarketTicker> liveTickers = {};
      try {
        liveTickers = await marketService.fetchLiveTickers(nowMs: nowMs);
      } catch (e) {
        liveTickers = Map.from(marketService.latestTickers);
      }

      if (liveTickers.isEmpty) {
        if (userWantsRunning) {
          await _handleBoundedRecoveryOrPause(
            snap: snap,
            nowMs: nowMs,
            pauseState: BotEngineState.pausedNetworkLoss,
            reason: 'Live ticker feed unavailable — waiting for network recovery',
          );
        }
        return false;
      }

      final livePrices = {
        for (final e in liveTickers.entries) e.key: e.value.lastPrice,
      };
      final closedPrices = Map<String, double>.from(snap.closedCandlePrices);
      final whyNoTrade = Map<String, String>.from(snap.whyNoTradeForSymbol);
      final canTrade = allowTradingExecution && userWantsRunning;
      int latestCandleMs = snap.lastCandleUpdateMs ?? 0;

      for (final symbol in watchedSymbols) {
        List<Candle> candles15m;
        List<Candle> candles1h;
        try {
          candles15m = await _fetchClosedCandlesWithRetry(symbol, '15m', nowMs);
          candles1h = await _fetchClosedCandlesWithRetry(symbol, '1h', nowMs);
        } catch (e) {
          if (userWantsRunning) {
            await _handleBoundedRecoveryOrPause(
              snap: snap,
              nowMs: nowMs,
              pauseState: BotEngineState.pausedNetworkLoss,
              reason: 'Candle fetch error for $symbol: $e',
            );
          }
          return false;
        }

        if (marketService.isDataStale(
          closedCandles15m: candles15m,
          nowMs: nowMs,
        )) {
          if (userWantsRunning) {
            await _handleBoundedRecoveryOrPause(
              snap: snap,
              nowMs: nowMs,
              pauseState: BotEngineState.pausedStaleData,
              reason: 'Why no trade: Stale data for $symbol',
            );
          }
          return false;
        }

        closedPrices[symbol] = candles15m.last.close;
        if (candles15m.last.closeTimeMs > latestCandleMs) {
          latestCandleMs = candles15m.last.closeTimeMs;
        }

        final pairMeta = MarketPairMetadata(
          symbol: symbol,
          baseCurrency: symbol.contains('BTC') ? 'BTC' : 'ETH',
          quoteCurrency: 'USDT',
        );

        final outcome = broker.processClosedCandleStream(
          symbol: symbol,
          closedCandles15m: candles15m,
          closedCandles1h: candles1h,
          strategyEngine: strategyEngine,
          pairMetadata: pairMeta,
          currentMarkPrices: livePrices,
          liveTicker: liveTickers[symbol],
          allowNewEntries: canTrade,
        );

        if (outcome.whyNoTradeReason != null) {
          whyNoTrade[symbol] = outcome.whyNoTradeReason!;
        }

        await _emitAlertsForNewOrders(outcome);

        if (outcome.triggeredSafetyState != null) {
          final eq = broker.accountEquityUsdt(livePrices);
          await persistence.logDiagnosticEvent(
            'SAFETY_LOCK',
            outcome.safetyMessage ?? outcome.triggeredSafetyState!.name,
            timestampMs: nowMs,
          );
          // Stage 3: Never mutate userIntention on safety lock!
          await persistence.saveFullState(
            botState: outcome.triggeredSafetyState!,
            availableCashUsdt: broker.availableCashUsdt,
            accountEquityUsdt: eq,
            maxDrawdownLocked: broker.maxDrawdownLocked,
            lockedDailyLossUtcDate: broker.lockedDailyLossUtcDate,
            lastStopLossClosedAtMs: broker.lastStopLossClosedAtMs,
            lastHeartbeatMs: nowMs,
            lastMarketDataUpdateMs: nowMs,
            lastCandleUpdateMs: latestCandleMs,
            orderSeq: snap.orderSeq + outcome.newOrders.length,
            statusBannerMessage:
                outcome.safetyMessage ?? 'SAFETY LOCK TRIGGERED',
            liveTickerPrices: livePrices,
            liveTickers: liveTickers,
            closedCandlePrices: closedPrices,
            whyNoTradeForSymbol: whyNoTrade,
            openPositions: broker.openPositions,
            orders: broker.orders,
            closedTrades: broker.closedTrades,
            processedEntrySignalKeys: broker.processedEntrySignalKeys,
          );
          return false;
        }
      }

      await _resetRecoveryTracking();
      final eq = broker.accountEquityUsdt(livePrices);
      final targetState =
          userWantsRunning ? BotEngineState.running : snap.botState;
      final banner = userWantsRunning
          ? 'PAPER BOT RUNNING — Heartbeat ${_formatHhMmSs(nowMs)}'
          : snap.statusBannerMessage;

      await persistence.saveFullState(
        botState: targetState,
        availableCashUsdt: broker.availableCashUsdt,
        accountEquityUsdt: eq,
        maxDrawdownLocked: broker.maxDrawdownLocked,
        lockedDailyLossUtcDate: broker.lockedDailyLossUtcDate,
        lastStopLossClosedAtMs: broker.lastStopLossClosedAtMs,
        lastHeartbeatMs: nowMs,
        lastMarketDataUpdateMs: nowMs,
        lastCandleUpdateMs: latestCandleMs,
        runningSinceMs:
            snap.runningSinceMs ?? (userWantsRunning ? nowMs : null),
        totalActiveMs: snap.totalActiveMs,
        orderSeq: snap.orderSeq + 1,
        statusBannerMessage: banner,
        liveTickerPrices: livePrices,
        liveTickers: liveTickers,
        closedCandlePrices: closedPrices,
        whyNoTradeForSymbol: whyNoTrade,
        openPositions: broker.openPositions,
        orders: broker.orders,
        closedTrades: broker.closedTrades,
        processedEntrySignalKeys: broker.processedEntrySignalKeys,
      );

      if (userWantsRunning) {
        await _notify(
          'Ankit AI Trader — PAPER BOT ACTIVE',
          _formatOngoingNotificationText(eq, livePrices),
        );
      }
      return true;
    } finally {
      await persistence.releaseExecutionLock(
        lockName: authoritativeLockName,
        ownerId: _ownerId,
      );
      _isCycleExecuting = false;
    }
  }

  Future<List<Candle>> _fetchClosedCandlesWithRetry(
    String pair,
    String interval,
    int nowMs,
  ) async {
    Object? lastErr;
    for (int attempt = 0; attempt < 2; attempt++) {
      try {
        return await marketService.fetchClosedCandles(
          pair: pair,
          interval: interval,
          nowMs: nowMs,
        );
      } catch (e) {
        lastErr = e;
        await Future<void>.delayed(const Duration(milliseconds: 500));
      }
    }
    throw lastErr ?? Exception('Failed to fetch candles for $pair');
  }

  Future<void> _handleBoundedRecoveryOrPause({
    required PersistedEngineSnapshot snap,
    required int nowMs,
    required BotEngineState pauseState,
    required String reason,
  }) async {
    final attempt = snap.recoveryAttemptCount + 1;
    final delaySec =
        attempt <= 1 ? 5 : (attempt == 2 ? 15 : (attempt == 3 ? 30 : 60));
    final delayMs = delaySec * 1000;
    final startedAt = snap.recoveryStartedAtMs ?? nowMs;
    final nextAllowed = nowMs + delayMs;
    final logLine =
        '[${_formatHhMmSs(nowMs)}] AUTO-RECOVERY RETRY #$attempt (${delaySec}s): $reason';

    await persistence.saveRecoveryState(
      attemptCount: attempt,
      recoveryStartedAtMs: startedAt,
      nextRecoveryAllowedAtMs: nextAllowed,
      logMessage: logLine,
    );

    // Stage 3: Never mutate userIntention on transient errors/network loss/stale data!
    await persistence.saveFullState(
      botState: pauseState,
      availableCashUsdt: broker.availableCashUsdt,
      accountEquityUsdt: snap.accountEquityUsdt,
      maxDrawdownLocked: broker.maxDrawdownLocked,
      lockedDailyLossUtcDate: broker.lockedDailyLossUtcDate,
      lastStopLossClosedAtMs: broker.lastStopLossClosedAtMs,
      lastHeartbeatMs: nowMs,
      statusBannerMessage:
          'PAUSED (${pauseState.name}): $reason',
      liveTickerPrices: snap.liveTickerPrices,
      liveTickers: snap.liveTickers,
      closedCandlePrices: snap.closedCandlePrices,
      whyNoTradeForSymbol: snap.whyNoTradeForSymbol,
      openPositions: broker.openPositions,
      orders: broker.orders,
      closedTrades: broker.closedTrades,
      processedEntrySignalKeys: broker.processedEntrySignalKeys,
    );

    if (snap.autoResumeEnabled) {
      _retryTimer?.cancel();
      _retryTimer = Timer(Duration(milliseconds: delayMs), () {
        executeAuthoritativeCycle(
          allowTradingExecution: true,
          transitionToRunningOnSuccess: true,
        );
      });
    }
    await onSchedulerRetry?.call(delayMs, reason);
  }

  Future<void> _resetRecoveryTracking() async {
    _retryTimer?.cancel();
    await persistence.clearRecoveryState();
  }

  /// Stage 9: Network transition handler respecting autoResumeEnabled (default OFF).
  /// When ON, resumes ONLY after fresh validated data and ONLY from network/stale-data pauses.
  /// NEVER resumes from user PAUSE/STOP, daily-loss lock, or drawdown lock.
  Future<void> handleNetworkTransition(bool connected) async {
    final nowMs = nowMsProvider();
    final snap = await persistence.loadFullState();
    if (!connected) {
      if (snap.userIntention == UserSessionIntention.running &&
          snap.botState == BotEngineState.running) {
        await _handleBoundedRecoveryOrPause(
          snap: snap,
          nowMs: nowMs,
          pauseState: BotEngineState.pausedNetworkLoss,
          reason: 'Internet disconnected. Bot paused for safety.',
        );
      }
      return;
    }

    // Network returned
    await persistence.logDiagnosticEvent(
      'NETWORK_RESTORED',
      'Internet connection restored (autoResume=${snap.autoResumeEnabled})',
      timestampMs: nowMs,
    );

    if (snap.userIntention == UserSessionIntention.running &&
        (snap.botState == BotEngineState.pausedNetworkLoss ||
            snap.botState == BotEngineState.pausedStaleData)) {
      if (snap.autoResumeEnabled) {
        await executeAuthoritativeCycle(
          allowTradingExecution: true,
          transitionToRunningOnSuccess: true,
        );
      } else {
        await persistence.putKv(
          'statusBannerMessage',
          'Internet restored. Auto-resume is OFF — tap RESUME or enable Auto-Resume in Settings.',
        );
      }
    }
  }

  /// Stage 8: Mark an alert "sent" in SQLite ONLY after it actually posted (`posted == true`).
  Future<void> _emitAlertsForNewOrders(CandleStreamOutcome outcome) async {
    final enabled = await persistence.getTradeAlertsEnabled();
    if (!enabled) return;
    final notified = await persistence.getNotifiedAlertIds();

    for (final ord in outcome.newOrders.where((o) => o.side == 'BUY')) {
      final pos = broker.openPositions
          .where((p) => p.symbol == ord.symbol)
          .firstOrNull;
      final alert = TradeAlertFormatter.formatEntryAlert(
        ord,
        stopLoss: pos?.stopLoss ?? 0.0,
        takeProfit: pos?.takeProfit ?? 0.0,
      );
      if (!notified.contains(alert.alertId)) {
        final posted = (await onTradeAlert?.call(alert)) ?? false;
        if (posted) {
          await persistence.markAlertIdNotified(alert.alertId);
        }
      }
    }

    for (final trd in outcome.newClosedTrades) {
      final alert = TradeAlertFormatter.formatExitAlert(trd);
      if (!notified.contains(alert.alertId)) {
        final posted = (await onTradeAlert?.call(alert)) ?? false;
        if (posted) {
          await persistence.markAlertIdNotified(alert.alertId);
        }
      }
    }

    if (outcome.triggeredSafetyState != null && outcome.safetyMessage != null) {
      final alert = TradeAlertFormatter.formatSafetyLockAlert(
        lockType: outcome.triggeredSafetyState!.name,
        message: outcome.safetyMessage!,
        timestampMs: nowMsProvider(),
      );
      if (!notified.contains(alert.alertId)) {
        final posted = (await onTradeAlert?.call(alert)) ?? false;
        if (posted) {
          await persistence.markAlertIdNotified(alert.alertId);
        }
      }
    }
  }

  String _formatOngoingNotificationText(
    double equity,
    Map<String, double> prices,
  ) {
    final btc = prices['B-BTC_USDT'];
    final eth = prices['B-ETH_USDT'];
    final btcStr = btc != null ? '\$${btc.toStringAsFixed(1)}' : '--';
    final ethStr = eth != null ? '\$${eth.toStringAsFixed(1)}' : '--';
    return 'Eq: \$${equity.toStringAsFixed(2)} | BTC: $btcStr | ETH: $ethStr';
  }

  String _formatHhMmSs(int epochMs) {
    final dt = DateTime.fromMillisecondsSinceEpoch(epochMs, isUtc: true);
    final h = dt.hour.toString().padLeft(2, '0');
    final m = dt.minute.toString().padLeft(2, '0');
    final s = dt.second.toString().padLeft(2, '0');
    return '$h:$m:$s UTC';
  }

  Future<void> _notify(String title, String text) async {
    await onNotificationUpdate?.call(title, text);
  }

  void dispose() {
    _retryTimer?.cancel();
  }
}

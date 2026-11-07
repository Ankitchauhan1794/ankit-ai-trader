import 'dart:async';
import '../models/trading_models.dart';
import 'coindcx_market_service.dart';
import 'paper_broker.dart';
import 'persistence_db.dart';
import 'risk_manager.dart';
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
  final Future<void> Function(TradeAlertPayload alert)? onTradeAlert;
  final Future<void> Function(int delayMs, String reason)? onSchedulerRetry;
  final Future<void> Function(UserSessionIntention intention)?
      onSyncUserIntention;

  final String _ownerId;
  bool _isCycleExecuting = false;
  Timer? _retryTimer;
  StreamSubscription<Map<String, LiveMarketTicker>>? _wsSubscription;

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
        _ownerId = 'auth_engine_${DateTime.now().microsecondsSinceEpoch}' {
    _wsSubscription = marketService.tickerStream.listen((tickers) async {
      if (tickers.isEmpty) return;
      final prices = {
        for (final e in tickers.entries) e.key: e.value.lastPrice,
      };
      await persistence.putKv(
        'liveTickerPrices',
        _encodeNumMap(prices),
      );
    });
  }

  String _encodeNumMap(Map<String, double> m) {
    final entries =
        m.entries.map((e) => '"${e.key}":${e.value}').join(',');
    return '{$entries}';
  }

  /// Stage 6: Restore session automatically when background service starts if userIntention == running.
  Future<void> restoreSessionIfRunningIntended() async {
    await marketService.connectWebSocketFeed();
    final snap = await persistence.loadFullState();
    _hydrateBrokerFromSnapshot(snap);
    if (snap.userIntention == UserSessionIntention.running &&
        snap.botState != BotEngineState.stoppedMaxDrawdownReached &&
        snap.botState != BotEngineState.lockedDailyLossLimit) {
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
          await persistence.saveFullState(
            botState: BotEngineState.stoppedMaxDrawdownReached,
            userIntention: UserSessionIntention.stopped,
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
          await onSyncUserIntention?.call(UserSessionIntention.stopped);
          return false;
        }
        await persistence.saveUserIntention(UserSessionIntention.running);
        await onSyncUserIntention?.call(UserSessionIntention.running);
        await _resetRecoveryTracking();
        await marketService.connectWebSocketFeed();
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
          statusBannerMessage: 'BOT PAUSED MANUALLY – PRESS START TO RESUME',
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

  /// Stage 7 & 8: Single authoritative trading cycle with SQLite execution lock & unbounded auto-recovery.
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

      final userWantsRunning =
          transitionToRunningOnSuccess ||
          snap.userIntention == UserSessionIntention.running ||
          snap.botState == BotEngineState.running;

      if (!userWantsRunning && allowTradingExecution) {
        return true;
      }

      if (snap.botState == BotEngineState.stoppedMaxDrawdownReached) {
        return false;
      }

      // 1. Fetch live ticker prices (Stages 10, 11, 13)
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
          final targetIntention = outcome.triggeredSafetyState ==
                  BotEngineState.stoppedMaxDrawdownReached
              ? UserSessionIntention.stopped
              : snap.userIntention;
          await persistence.saveFullState(
            botState: outcome.triggeredSafetyState!,
            userIntention: targetIntention,
            availableCashUsdt: broker.availableCashUsdt,
            accountEquityUsdt: eq,
            maxDrawdownLocked: broker.maxDrawdownLocked,
            lockedDailyLossUtcDate: broker.lockedDailyLossUtcDate,
            lastStopLossClosedAtMs: broker.lastStopLossClosedAtMs,
            lastHeartbeatMs: nowMs,
            lastMarketDataUpdateMs: nowMs,
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

      // Stage 8: Fresh data validated -> automatically resume running if userIntention == running!
      await _resetRecoveryTracking();
      final eq = broker.accountEquityUsdt(livePrices);
      final targetState = userWantsRunning
          ? BotEngineState.running
          : snap.botState;
      final banner = userWantsRunning
          ? 'PAPER BOT RUNNING — Heartbeat ${_formatHhMmSs(nowMs)}'
          : snap.statusBannerMessage;

      await persistence.saveFullState(
        botState: targetState,
        userIntention: userWantsRunning
            ? UserSessionIntention.running
            : snap.userIntention,
        availableCashUsdt: broker.availableCashUsdt,
        accountEquityUsdt: eq,
        maxDrawdownLocked: broker.maxDrawdownLocked,
        lockedDailyLossUtcDate: broker.lockedDailyLossUtcDate,
        lastStopLossClosedAtMs: broker.lastStopLossClosedAtMs,
        lastHeartbeatMs: nowMs,
        lastMarketDataUpdateMs: nowMs,
        runningSinceMs: snap.runningSinceMs ?? (userWantsRunning ? nowMs : null),
        totalActiveMs: snap.totalActiveMs,
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

  /// Stage 8: Unbounded auto-recovery with exponential backoff (never permanently halts when userIntention == running).
  Future<void> _handleBoundedRecoveryOrPause({
    required PersistedEngineSnapshot snap,
    required int nowMs,
    required BotEngineState pauseState,
    required String reason,
  }) async {
    final attempt = snap.recoveryAttemptCount + 1;
    final delaySec = attempt <= 1
        ? 5
        : (attempt == 2 ? 15 : (attempt == 3 ? 30 : 60));
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

    await persistence.saveFullState(
      botState: pauseState,
      userIntention: snap.userIntention,
      availableCashUsdt: broker.availableCashUsdt,
      accountEquityUsdt: snap.accountEquityUsdt,
      maxDrawdownLocked: broker.maxDrawdownLocked,
      lockedDailyLossUtcDate: broker.lockedDailyLossUtcDate,
      lastStopLossClosedAtMs: broker.lastStopLossClosedAtMs,
      lastHeartbeatMs: nowMs,
      statusBannerMessage:
          'AUTO-RECOVERING (#$attempt, retry in ${delaySec}s): $reason',
      liveTickerPrices: snap.liveTickerPrices,
      liveTickers: snap.liveTickers,
      closedCandlePrices: snap.closedCandlePrices,
      whyNoTradeForSymbol: snap.whyNoTradeForSymbol,
      openPositions: broker.openPositions,
      orders: broker.orders,
      closedTrades: broker.closedTrades,
      processedEntrySignalKeys: broker.processedEntrySignalKeys,
    );

    _retryTimer?.cancel();
    _retryTimer = Timer(Duration(milliseconds: delayMs), () {
      executeAuthoritativeCycle(
        allowTradingExecution: true,
        transitionToRunningOnSuccess: true,
      );
    });
    await onSchedulerRetry?.call(delayMs, reason);
  }

  Future<void> _resetRecoveryTracking() async {
    _retryTimer?.cancel();
    await persistence.clearRecoveryState();
  }

  /// Stage 8: Network transition handler that immediately validates & resumes when internet returns.
  Future<void> handleNetworkTransition(bool connected) async {
    final nowMs = nowMsProvider();
    final snap = await persistence.loadFullState();
    if (!connected) {
      if (snap.userIntention == UserSessionIntention.running ||
          snap.botState == BotEngineState.running) {
        await _handleBoundedRecoveryOrPause(
          snap: snap,
          nowMs: nowMs,
          pauseState: BotEngineState.pausedNetworkLoss,
          reason: 'Internet disconnected. Bot paused for safety; will auto-resume when internet returns.',
        );
      }
      return;
    }

    await marketService.connectWebSocketFeed();
    if (snap.userIntention == UserSessionIntention.running &&
        snap.botState != BotEngineState.stoppedMaxDrawdownReached &&
        snap.botState != BotEngineState.lockedDailyLossLimit) {
      await executeAuthoritativeCycle(
        allowTradingExecution: true,
        transitionToRunningOnSuccess: true,
      );
    }
  }

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
        await persistence.markAlertIdNotified(alert.alertId);
        await onTradeAlert?.call(alert);
      }
    }

    for (final trd in outcome.newClosedTrades) {
      final alert = TradeAlertFormatter.formatExitAlert(trd);
      if (!notified.contains(alert.alertId)) {
        await persistence.markAlertIdNotified(alert.alertId);
        await onTradeAlert?.call(alert);
      }
    }

    if (outcome.triggeredSafetyState != null && outcome.safetyMessage != null) {
      final alert = TradeAlertFormatter.formatSafetyLockAlert(
        lockType: outcome.triggeredSafetyState!.name,
        message: outcome.safetyMessage!,
        timestampMs: nowMsProvider(),
      );
      if (!notified.contains(alert.alertId)) {
        await persistence.markAlertIdNotified(alert.alertId);
        await onTradeAlert?.call(alert);
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
    _wsSubscription?.cancel();
  }
}

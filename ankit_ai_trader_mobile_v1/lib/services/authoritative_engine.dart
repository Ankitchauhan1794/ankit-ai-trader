import 'dart:async';
import 'dart:math' as math;
import '../models/dual_portfolio_models.dart';
import '../models/trading_models.dart';
import 'coindcx_market_service.dart';
import 'dual_portfolio_service.dart';
import 'execution_and_risk_hub.dart';
import 'paper_broker.dart';
import 'persistence_db.dart';
import 'risk_manager.dart';
import 'strategy_engine.dart';
import 'trade_alert_formatter.dart';

class AuthoritativeTradingEngine {
  static const String lockName = 'authoritative_paper_engine_lock';

  final CoinDcxMarketService marketService;
  final PersistenceDatabase persistence;
  final StrategyEngine strategyEngine;
  final RiskManager riskManager;
  final PaperBroker paperBroker;
  final IndependentRiskSupervisor riskSupervisor;
  late final DualPortfolioManager dualPortfolioManager;
  final String ownerId;
  final int Function() _nowMs;
  final bool verifyReachabilityBeforeNetworkPause;
  final int maxCandleEvaluationPairsPerCycle;
  final Future<void> Function(String title, String text)? onNotificationUpdate;
  final Future<void> Function(TradeAlertPayload alert)? onTradeAlert;

  BotEngineState state = BotEngineState.stopped;
  UserSessionIntention userIntention = UserSessionIntention.stopped;
  double availableCashUsdt = 100.0;
  double accountEquityUsdt = 100.0;
  double startOfDayEquityUsdt = 100.0;
  bool maxDrawdownLocked = false;
  String? lockedDailyLossUtcDate;
  int? lastStopLossClosedAtMs;
  int? lastHeartbeatMs;
  int? lastMarketDataUpdateMs;
  int? lastCandleUpdateMs;
  int? runningSinceMs;
  int totalActiveMs = 0;
  int orderSeq = 0;
  int? lastStartupAttemptMs;
  String? lastStartupError;
  String? lastShutdownReason;
  String? lastBackgroundCycleError;
  String statusBannerMessage = 'PAPER BOT STOPPED — PRESS START';
  Map<String, double> liveTickerPrices = {};
  Map<String, LiveMarketTicker> liveTickers = {};
  Map<String, double> closedCandlePrices = {};
  Map<String, String> whyNoTradeForSymbol = {};
  List<PaperPosition> openPositions = [];
  List<SimulatedOrder> orders = [];
  List<ClosedPaperTrade> closedTrades = [];
  Set<String> processedEntrySignalKeys = {};
  ScanCycleDiagnosticsSnapshot scanDiagnostics =
      const ScanCycleDiagnosticsSnapshot();

  Timer? _cycleTimer;
  bool _isCycleInFlight = false;
  bool _disposed = false;
  bool _hasLoadedPersistedState = false;
  Future<bool>? _activeStartFuture;
  int _candleScanCursor = 0;

  AuthoritativeTradingEngine({
    required this.marketService,
    required this.persistence,
    this.strategyEngine = const StrategyEngine(),
    this.riskManager = const RiskManager(),
    this.paperBroker = const PaperBroker(),
    IndependentRiskSupervisor? riskSupervisor,
    DualPortfolioManager? dualPortfolioManager,
    this.ownerId = 'bg_service_engine_1',
    int Function()? nowMsProvider,
    this.verifyReachabilityBeforeNetworkPause = false,
    this.maxCandleEvaluationPairsPerCycle = 12,
    this.onNotificationUpdate,
    this.onTradeAlert,
  })  : riskSupervisor = riskSupervisor ?? IndependentRiskSupervisor(),
        _nowMs =
            nowMsProvider ?? (() => DateTime.now().millisecondsSinceEpoch) {
    this.dualPortfolioManager =
        dualPortfolioManager ?? DualPortfolioManager(persistence: persistence);
  }

  Future<void> loadPersistedStateIntoMemory() async {
    final snap = await persistence.loadFullState();
    state = snap.botState;
    userIntention = snap.userIntention;
    availableCashUsdt = snap.availableCashUsdt;
    accountEquityUsdt = snap.accountEquityUsdt;
    startOfDayEquityUsdt = snap.startOfDayEquityUsdt;
    maxDrawdownLocked = snap.maxDrawdownLocked;
    lockedDailyLossUtcDate = snap.lockedDailyLossUtcDate;
    lastStopLossClosedAtMs = snap.lastStopLossClosedAtMs;
    lastHeartbeatMs = snap.lastHeartbeatMs;
    lastMarketDataUpdateMs = snap.lastMarketDataUpdateMs;
    lastCandleUpdateMs = snap.lastCandleUpdateMs;
    runningSinceMs = snap.runningSinceMs;
    totalActiveMs = snap.totalActiveMs;
    orderSeq = snap.orderSeq;
    lastStartupAttemptMs = snap.lastStartupAttemptMs;
    lastStartupError = snap.lastStartupError;
    lastShutdownReason = snap.lastShutdownReason;
    lastBackgroundCycleError = snap.lastBackgroundCycleError;
    statusBannerMessage = snap.statusBannerMessage;
    liveTickerPrices = Map.from(snap.liveTickerPrices);
    liveTickers = Map.from(snap.liveTickers);
    closedCandlePrices = Map.from(snap.closedCandlePrices);
    whyNoTradeForSymbol = Map.from(snap.whyNoTradeForSymbol);
    openPositions = List.from(snap.openPositions);
    orders = List.from(snap.orders);
    closedTrades = List.from(snap.closedTrades);
    processedEntrySignalKeys = Set.from(snap.processedEntrySignalKeys);
    scanDiagnostics = snap.scanDiagnostics;

    // Self-heal Spot accounting if cash and equity diverged while 0 positions are open
    if (openPositions.isEmpty &&
        (accountEquityUsdt - availableCashUsdt).abs() > 0.01) {
      final realizedSum = closedTrades.fold<double>(
        0.0,
        (acc, t) => acc + t.realizedPnlUsdt,
      );
      availableCashUsdt = 100.0 + realizedSum;
      accountEquityUsdt = availableCashUsdt;
    }
    _hasLoadedPersistedState = true;
  }

  Future<void> restoreSessionIfRunningIntended() async {
    await loadPersistedStateIntoMemory();
    if (userIntention == UserSessionIntention.running &&
        !maxDrawdownLocked &&
        lockedDailyLossUtcDate == null) {
      await startEngine();
    }
  }

  Future<bool> startEngine() {
    if (_activeStartFuture != null) {
      return _activeStartFuture!;
    }
    final fut = _startEngineInternal();
    _activeStartFuture = fut;
    fut.whenComplete(() {
      if (identical(_activeStartFuture, fut)) {
        _activeStartFuture = null;
      }
    });
    return fut;
  }

  Future<bool> _startEngineInternal() async {
    if (!_hasLoadedPersistedState) {
      await loadPersistedStateIntoMemory();
    }
    final now = _nowMs();
    lastStartupAttemptMs = now;
    lastStartupError = null;

    if (state == BotEngineState.running &&
        userIntention == UserSessionIntention.running &&
        _cycleTimer != null) {
      lastHeartbeatMs = now;
      await persistence.recordHeartbeat(now);
      return true;
    }

    if (maxDrawdownLocked ||
        riskManager.shouldStopForMaxDrawdown(accountEquityUsdt)) {
      maxDrawdownLocked = true;
      riskSupervisor.portfolioLossLockoutActive = true;
      state = BotEngineState.stoppedMaxDrawdownReached;
      final floorStr =
          riskManager.config.equityFloorUsdt.toStringAsFixed(2);
      lastStartupError =
          'Cannot start: 15% Portfolio Loss Limit (\$$floorStr floor) reached — authorized reset required.';
      lastShutdownReason = lastStartupError;
      statusBannerMessage =
          'PAUSED_BY_RISK: 15% Portfolio Loss Limit (\$$floorStr floor) reached.';
      await _persistCurrentState(now);
      return false;
    }

    final todayUtc = RiskManager.currentUtcDateString(now);
    if (lockedDailyLossUtcDate == todayUtc ||
        riskManager.shouldLockDailyLoss(
          startOfDayEquityUsdt: startOfDayEquityUsdt,
          currentEquityUsdt: accountEquityUsdt,
        )) {
      lockedDailyLossUtcDate = todayUtc;
      state = BotEngineState.lockedDailyLossLimit;
      lastStartupError =
          'Cannot start: Daily loss limit (\$2.00) reached for $todayUtc.';
      lastShutdownReason = lastStartupError;
      statusBannerMessage =
          'PAUSED_BY_RISK: Daily loss limit (\$2.00) reached.';
      await _persistCurrentState(now);
      return false;
    }

    final locked = await persistence.acquireExecutionLock(
      lockName: lockName,
      ownerId: ownerId,
      nowMs: now,
      forceTakeover: true,
    );
    if (!locked) {
      lastStartupError =
          'Another authoritative engine instance holds the execution lock.';
      statusBannerMessage = 'CANNOT START: $lastStartupError';
      await persistence.saveStartupDiagnostics(
        lastStartupAttemptMs: now,
        lastStartupError: lastStartupError,
        statusBannerMessage: statusBannerMessage,
      );
      return false;
    }

    userIntention = UserSessionIntention.running;
    await persistence.saveUserIntention(UserSessionIntention.running);
    state = BotEngineState.running;
    runningSinceMs ??= now;
    lastHeartbeatMs = now;
    lastShutdownReason = null;
    statusBannerMessage =
        'PAPER BOT RUNNING — Multi-Pair CoinDCX Scanner Active';
    await persistence.clearRecoveryState();
    await persistence.saveStartupDiagnostics(
      botState: BotEngineState.running,
      userIntention: UserSessionIntention.running,
      lastStartupAttemptMs: now,
      clearStartupError: true,
      clearShutdownReason: true,
      statusBannerMessage: statusBannerMessage,
    );
    await _persistCurrentState(now);
    await executeTradingCycle(allowTradingExecution: true);
    _startPeriodicTimer();
    return true;
  }

  Future<void> pauseEngine({String reason = 'Paused by user'}) async {
    userIntention = UserSessionIntention.paused;
    await persistence.saveUserIntention(UserSessionIntention.paused);
    state = BotEngineState.pausedAfterRecoveryManualStartRequired;
    lastShutdownReason = reason;
    statusBannerMessage = 'PAUSED (PAUSED_BY_USER): $reason';
    await _persistCurrentState(_nowMs());
  }

  Future<void> stopEngine({String reason = 'Stopped by user'}) async {
    _cycleTimer?.cancel();
    userIntention = UserSessionIntention.stopped;
    await persistence.saveUserIntention(UserSessionIntention.stopped);
    state = BotEngineState.stopped;
    runningSinceMs = null;
    lastShutdownReason = reason;
    statusBannerMessage = 'PAPER BOT STOPPED — $reason';
    await _persistCurrentState(_nowMs());
    await persistence.releaseExecutionLock(lockName: lockName, ownerId: ownerId);
  }

  Future<void> resetAccountTo100() async {
    _cycleTimer?.cancel();
    userIntention = UserSessionIntention.stopped;
    state = BotEngineState.stopped;
    availableCashUsdt = 100.0;
    accountEquityUsdt = 100.0;
    startOfDayEquityUsdt = 100.0;
    maxDrawdownLocked = false;
    lockedDailyLossUtcDate = null;
    lastStopLossClosedAtMs = null;
    lastStartupError = null;
    lastBackgroundCycleError = null;
    lastShutdownReason = 'Manual account reset to \$100.00 USDT';
    openPositions.clear();
    orders.clear();
    closedTrades.clear();
    processedEntrySignalKeys.clear();
    whyNoTradeForSymbol.clear();
    statusBannerMessage = 'Paper account reset to \$100.00 USDT.';
    await persistence.clearRecoveryState();
    await persistence.saveStartupDiagnostics(
      botState: BotEngineState.stopped,
      userIntention: UserSessionIntention.stopped,
      clearStartupError: true,
      clearBackgroundCycleError: true,
      lastShutdownReason: lastShutdownReason,
      statusBannerMessage: statusBannerMessage,
    );
    await _persistCurrentState(_nowMs());
  }

  Future<void> handleNetworkTransition(bool connected) async {
    final now = _nowMs();
    if (!connected) {
      if (verifyReachabilityBeforeNetworkPause) {
        final probe = await marketService.fetchLiveTickers(nowMs: now);
        if (probe.isNotEmpty) {
          return; // False OS disconnect event; CoinDCX REST is still reachable!
        }
      }
      if (state == BotEngineState.running ||
          state == BotEngineState.waitingForFreshData) {
        state = BotEngineState.pausedNetworkLoss;
        statusBannerMessage =
            'PAUSED (PAUSED_BY_NETWORK): Internet disconnected. Bot paused for safety.';
        await persistence.saveRecoveryState(
          attemptCount: 1,
          recoveryStartedAtMs: now,
          nextRecoveryAllowedAtMs: now + 5000,
          logMessage:
              'AUTO-RECOVERY RETRY #1 (5s): Internet disconnected. Bot paused for safety.',
        );
        await _persistCurrentState(now);
      }
    } else {
      final autoResume = await persistence.getAutoResumeEnabled();
      if (state == BotEngineState.pausedNetworkLoss) {
        if (autoResume && userIntention == UserSessionIntention.running) {
          state = BotEngineState.running;
          statusBannerMessage = 'PAPER BOT RUNNING — Network Restored';
          await persistence.clearRecoveryState();
          await _persistCurrentState(now);
          await executeTradingCycle(allowTradingExecution: true);
        } else {
          state = BotEngineState.pausedAfterRecoveryManualStartRequired;
          statusBannerMessage =
              'Network restored. Auto-resume is OFF — tap START to resume.';
          await _persistCurrentState(now);
        }
      }
    }
  }

  void _startPeriodicTimer() {
    _cycleTimer?.cancel();
    _cycleTimer = Timer.periodic(const Duration(seconds: 15), (_) {
      final shouldPoll = !_disposed &&
          userIntention == UserSessionIntention.running &&
          (state == BotEngineState.running ||
              state == BotEngineState.waitingForFreshData ||
              state == BotEngineState.pausedStaleData ||
              state == BotEngineState.reconnecting);
      if (shouldPoll) {
        executeTradingCycle(allowTradingExecution: true);
      }
    });
  }

  static double _scoreSignalOpportunity({
    required CoinDcxMarketRecord market,
    required StrategyEvaluationResult eval,
    required LiveMarketTicker ticker,
  }) {
    final volScore = ticker.volume24h > 0
        ? math.min(35.0, math.log(ticker.volume24h + 1) * 2.8)
        : 0.0;
    final spreadScore = (35.0 - ticker.spreadBps).clamp(0.0, 35.0);
    final trendStrength = eval.ema50_15m > 0
        ? (((eval.ema20_15m - eval.ema50_15m) / eval.ema50_15m) * 1000.0)
            .clamp(0.0, 20.0)
        : 0.0;
    final rsiSweetSpot = (10.0 - (eval.rsi14_15m - 58.0).abs()).clamp(0.0, 10.0);
    return volScore + spreadScore + trendStrength + rsiSweetSpot;
  }

  Future<void> executeTradingCycle({bool allowTradingExecution = true}) async {
    if (_isCycleInFlight || _disposed) return;
    _isCycleInFlight = true;
    try {
      final now = _nowMs();
      final locked = await persistence.acquireExecutionLock(
        lockName: lockName,
        ownerId: ownerId,
        nowMs: now,
      );
      if (!locked) return;

      lastHeartbeatMs = now;
      await persistence.recordHeartbeat(now);

      // 1. Refresh or load complete CoinDCX market catalogue
      final catalogue = await marketService.refreshMarketCatalogue(
        force: false,
        nowMs: now,
      );
      final fetchedTickers = await marketService.fetchLiveTickers(nowMs: now);
      if (fetchedTickers.isNotEmpty) {
        liveTickers = Map.from(fetchedTickers);
        for (final e in fetchedTickers.entries) {
          liveTickerPrices[e.key] = e.value.lastPrice;
        }
        lastMarketDataUpdateMs = now;
      }

      if (catalogue.allMarkets.isEmpty && liveTickers.isEmpty) {
        if (state == BotEngineState.running ||
            state == BotEngineState.starting) {
          state = BotEngineState.waitingForFreshData;
          statusBannerMessage =
              'WAITING_FOR_FRESH_DATA: CoinDCX market feed unavailable — retrying automatically';
        }
        await _persistCurrentState(now);
        return;
      }

      // Clear any stale network/data wait once data is flowing and userIntention is running
      if (userIntention == UserSessionIntention.running &&
          (state == BotEngineState.waitingForFreshData ||
              state == BotEngineState.pausedStaleData ||
              state == BotEngineState.reconnecting ||
              state == BotEngineState.starting)) {
        state = BotEngineState.running;
        await persistence.clearRecoveryState();
      }

      // 2. Determine all eligible pairs (USDT spot pairs for $100 USDT paper account)
      final eligibleMarkets = catalogue.allMarkets
          .where((m) =>
              m.isEligibleForPaperTrading &&
              m.quoteCurrency.toUpperCase() == 'USDT' &&
              m.pair.isNotEmpty)
          .toList();

      int evaluatedCount = 0;
      int skippedCount = 0;
      final skippedReasons = <String, String>{};
      int totalSignals = 0;
      int buySignals = 0;
      int sellSignals = 0;
      int rejectedSignals = 0;
      final rejectionReasons = <String, String>{};
      int submittedOrders = 0;
      int acceptedOrders = 0;
      int rejectedOrders = 0;

      // 3. First evaluate any open positions for SL / TP / Exit on closed candles
      for (final pos in List<PaperPosition>.from(openPositions)) {
        try {
          final candles15m = await marketService.fetchClosedCandles(
            pair: pos.symbol,
            interval: '15m',
            nowMs: now,
            limit: 80,
          );
          final candles1h = await marketService.fetchClosedCandles(
            pair: pos.symbol,
            interval: '1h',
            nowMs: now,
            limit: 65,
          );
          if (candles15m.isNotEmpty) {
            lastCandleUpdateMs = now;
            final latestClosed = candles15m.last;
            closedCandlePrices[pos.symbol] = latestClosed.close;
            final eval = strategyEngine.evaluate(
              symbol: pos.symbol,
              closedCandles15m: candles15m,
              closedCandles1h: candles1h,
              nowMs: now,
            );
            final exitCheck = paperBroker.evaluateOpenPositionOnClosedCandle(
              position: pos,
              closedCandle: latestClosed,
              nextOrderId: 'ORD_${++orderSeq}',
              nextTradeId: 'TRD_$orderSeq',
              strategySignal: eval.signal,
            );
            if (exitCheck.closedTrade != null && exitCheck.exitOrder != null) {
              availableCashUsdt += exitCheck.cashDeltaUsdt;
              openPositions.removeWhere((p) => p.id == pos.id);
              orders.insert(0, exitCheck.exitOrder!);
              closedTrades.insert(0, exitCheck.closedTrade!);
              riskSupervisor.recordClosedTradeOutcome(
                exitCheck.closedTrade!.realizedPnlUsdt,
              );
              if (exitCheck.outcome == CandleStreamOutcome.stopLossTriggered) {
                lastStopLossClosedAtMs = now;
              }
              if (onTradeAlert != null) {
                await onTradeAlert!(
                  TradeAlertFormatter.formatExitAlert(exitCheck.closedTrade!),
                );
              }
            }
          }
        } catch (e) {
          skippedReasons[pos.symbol] = 'OPEN_POS_CANDLE_ERR: $e';
        }
      }

      // Update mark-to-market account equity
      double openMarketVal = 0.0;
      for (final p in openPositions) {
        final mark = liveTickerPrices[p.symbol] ??
            closedCandlePrices[p.symbol] ??
            p.entryPrice;
        openMarketVal += (p.quantity * mark) - (p.quantity * mark * 0.001);
      }
      accountEquityUsdt = availableCashUsdt + openMarketVal;

      // Check global risk locks
      if (riskManager.shouldStopForMaxDrawdown(accountEquityUsdt)) {
        maxDrawdownLocked = true;
        state = BotEngineState.stoppedMaxDrawdownReached;
        riskSupervisor.portfolioLossLockoutActive = true;
        lastShutdownReason = '15% Portfolio Loss Limit (\$85.00 floor) reached';
        statusBannerMessage =
            'PAUSED_BY_RISK: 15% Portfolio Loss Limit (\$85.00 floor) reached.';
        await _persistCurrentState(now);
        return;
      }
      if (riskManager.shouldLockDailyLoss(
        startOfDayEquityUsdt: startOfDayEquityUsdt,
        currentEquityUsdt: accountEquityUsdt,
      )) {
        lockedDailyLossUtcDate = RiskManager.currentUtcDateString(now);
        state = BotEngineState.lockedDailyLossLimit;
        lastShutdownReason = 'Daily loss limit (\$2.00) reached';
        statusBannerMessage =
            'PAUSED_BY_RISK: Daily loss limit (\$2.00) reached.';
        await _persistCurrentState(now);
        return;
      }

      // 4. Select candidate batch for closed-candle evaluation so large catalogues (e.g. 472 pairs)
      // complete each cycle in ~1.5s without blocking startup or heartbeats.
      List<CoinDcxMarketRecord> marketsToEvaluate;
      if (eligibleMarkets.length <= maxCandleEvaluationPairsPerCycle) {
        marketsToEvaluate = eligibleMarkets;
      } else {
        final sortedByLiquidity = List<CoinDcxMarketRecord>.from(eligibleMarkets)
          ..sort((a, b) {
            final volA = a.latestTicker?.volume24h ?? 0.0;
            final volB = b.latestTicker?.volume24h ?? 0.0;
            return volB.compareTo(volA);
          });
        final topCore = sortedByLiquidity.take(6).toList();
        final remaining = sortedByLiquidity.skip(6).toList();
        final rotatingBatch = <CoinDcxMarketRecord>[];
        final rotatingQuota = math.max(1, maxCandleEvaluationPairsPerCycle - topCore.length);
        if (remaining.isNotEmpty) {
          for (int i = 0; i < math.min(rotatingQuota, remaining.length); i++) {
            final idx = (_candleScanCursor + i) % remaining.length;
            rotatingBatch.add(remaining[idx]);
          }
          _candleScanCursor = (_candleScanCursor + rotatingBatch.length) % remaining.length;
        }
        marketsToEvaluate = [...topCore, ...rotatingBatch];
        final evaluatedKeys = marketsToEvaluate.map((m) => m.pair).toSet();
        for (final m in eligibleMarkets) {
          if (!evaluatedKeys.contains(m.pair)) {
            skippedCount++;
            skippedReasons[m.pair] = 'QUEUED_FOR_NEXT_ROTATION_BATCH';
          }
        }
      }

      final buyOpportunities = <RankedSignalOpportunity>[];
      final cycleCandles15mByPair = <String, List<Candle>>{};
      final cycleCandles1hByPair = <String, List<Candle>>{};
      final cycleEvalByPair = <String, StrategyEvaluationResult>{};

      for (final market in marketsToEvaluate) {
        final pairKey = market.pair;
        final ticker = market.latestTicker ??
            CoinDcxMarketService.matchTickerForMarket(
              symbol: market.symbol,
              coindcxName: market.coindcxName,
              pair: market.pair,
              tickersByKey: liveTickers,
            );
        if (ticker == null) {
          skippedCount++;
          skippedReasons[pairKey] = 'MISSING_LIVE_TICKER';
          whyNoTradeForSymbol[pairKey] = 'SKIPPED: Missing live ticker';
          continue;
        }
        if (!ticker.isFresh(now, maxAgeMs: 300000)) {
          skippedCount++;
          skippedReasons[pairKey] = 'STALE_LIVE_TICKER';
          whyNoTradeForSymbol[pairKey] = 'SKIPPED: Stale live ticker data';
          continue;
        }
        liveTickerPrices[pairKey] = ticker.lastPrice;
        liveTickerPrices[market.symbol] = ticker.lastPrice;

        List<Candle> candles15m = const [];
        List<Candle> candles1h = const [];
        try {
          candles15m = await marketService.fetchClosedCandles(
            pair: pairKey,
            interval: '15m',
            nowMs: now,
            limit: 80,
          );
          candles1h = await marketService.fetchClosedCandles(
            pair: pairKey,
            interval: '1h',
            nowMs: now,
            limit: 65,
          );
        } catch (e) {
          skippedCount++;
          skippedReasons[pairKey] = 'CANDLE_FETCH_ERROR';
          whyNoTradeForSymbol[pairKey] = 'SKIPPED: Candle fetch error';
          continue;
        }

        if (candles15m.length < 52 || candles1h.length < 50) {
          skippedCount++;
          skippedReasons[pairKey] =
              'INSUFFICIENT_CANDLES (15m=${candles15m.length}, 1h=${candles1h.length})';
          whyNoTradeForSymbol[pairKey] =
              'SKIPPED: Insufficient closed candles (15m=${candles15m.length}/52, 1h=${candles1h.length}/50)';
          continue;
        }

        lastCandleUpdateMs = now;
        closedCandlePrices[pairKey] = candles15m.last.close;
        closedCandlePrices[market.symbol] = candles15m.last.close;
        evaluatedCount++;

        cycleCandles15mByPair[pairKey] = candles15m;
        cycleCandles1hByPair[pairKey] = candles1h;
        final eval = strategyEngine.evaluate(
          symbol: pairKey,
          closedCandles15m: candles15m,
          closedCandles1h: candles1h,
          nowMs: now,
        );
        cycleEvalByPair[pairKey] = eval;
        whyNoTradeForSymbol[pairKey] = eval.reason;
        whyNoTradeForSymbol[market.symbol] = eval.reason;

        if (eval.signal == StrategySignalType.buy) {
          totalSignals++;
          buySignals++;
          final sigKey = '${pairKey}_${eval.evaluatedCandleCloseMs}';
          if (processedEntrySignalKeys.contains(sigKey)) {
            rejectedSignals++;
            rejectionReasons[pairKey] = 'DUPLICATE_CANDLE_SIGNAL';
            whyNoTradeForSymbol[pairKey] = 'REJECTED: Duplicate candle signal';
            continue;
          }
          final score = _scoreSignalOpportunity(
            market: market,
            eval: eval,
            ticker: ticker,
          );
          buyOpportunities.add(
            RankedSignalOpportunity(
              market: market,
              evaluation: eval,
              closedCandles15m: candles15m,
              closedCandles1h: candles1h,
              ticker: ticker,
              rankingScore: score,
            ),
          );
        } else if (eval.signal == StrategySignalType.sell) {
          totalSignals++;
          sellSignals++;
        }
      }

      // Sort BUY opportunities highest score first
      buyOpportunities.sort((a, b) => b.rankingScore.compareTo(a.rankingScore));

      // 5. Execute top-ranked valid BUY opportunity if portfolio capacity allows
      if (allowTradingExecution &&
          state == BotEngineState.running &&
          buyOpportunities.isNotEmpty) {
        for (final opp in buyOpportunities) {
          final pairKey = opp.market.pair;
          if (openPositions.length >=
              riskManager.config.maxConcurrentOpenPositions) {
            rejectedSignals++;
            rejectionReasons[pairKey] = 'MAX_OPEN_POSITIONS_LIMIT_REACHED';
            whyNoTradeForSymbol[pairKey] =
                'REJECTED: Max open positions (${riskManager.config.maxConcurrentOpenPositions}) already active';
            continue;
          }

          final refAsk = opp.ticker.ask > 0
              ? opp.ticker.ask
              : opp.evaluation.closePrice;
          final estFill = paperBroker.computeBuyFillPrice(refAsk);
          final sizing = riskManager.evaluateEntry(
            symbol: pairKey,
            entryFillPrice: estFill,
            atr14: opp.evaluation.atr14_15m,
            currentEquityUsdt: accountEquityUsdt,
            startOfDayEquityUsdt: startOfDayEquityUsdt,
            availableCashUsdt: availableCashUsdt,
            openPositions: openPositions,
            metadata: opp.market.toMarketPairMetadata(),
            lastStopLossClosedAtMs: lastStopLossClosedAtMs,
            nowMs: now,
          );

          if (!sizing.approved) {
            rejectedSignals++;
            rejectionReasons[pairKey] =
                sizing.rejectionReason ?? 'RISK_SIZING_REJECTED';
            whyNoTradeForSymbol[pairKey] =
                'REJECTED: ${sizing.rejectionReason}';
            continue;
          }

          if (sizing.stopLossPrice <= 0 || sizing.stopLossPrice >= estFill) {
            rejectedSignals++;
            rejectionReasons[pairKey] = 'MANDATORY_VALID_STOP_LOSS_MISSING';
            whyNoTradeForSymbol[pairKey] =
                'REJECTED: Mandatory valid stop-loss missing or invalid';
            continue;
          }

          final orderValid = opp.market.validateOrder(
            quantity: sizing.quantity,
            price: estFill,
          );
          if (!orderValid.valid) {
            rejectedSignals++;
            rejectionReasons[pairKey] =
                orderValid.reason ?? 'EXCHANGE_RULE_REJECTED';
            whyNoTradeForSymbol[pairKey] = 'REJECTED: ${orderValid.reason}';
            continue;
          }

          final supVet = riskSupervisor.vetOrderRequest(
            symbol: pairKey,
            currentEquityUsdt: accountEquityUsdt,
            startOfDayEquityUsdt: startOfDayEquityUsdt,
            availableCashUsdt: availableCashUsdt,
            entryPrice: estFill,
            stopLossPrice: sizing.stopLossPrice,
            quantity: sizing.quantity,
            feeRate: paperBroker.feeRate,
            slippageRate: paperBroker.slippageRate,
            spreadPct: opp.ticker.spreadPct,
            atr14: opp.evaluation.atr14_15m,
            isDataFresh: opp.ticker.isFresh(now, maxAgeMs: 300000),
            openPositions: openPositions,
            activeOrders: const [],
            lastStopLossClosedAtMs: lastStopLossClosedAtMs,
            nowMs: now,
          );

          submittedOrders++;
          if (!supVet.approved) {
            rejectedSignals++;
            rejectedOrders++;
            rejectionReasons[pairKey] =
                supVet.reason ?? 'SUPERVISOR_REJECTED';
            whyNoTradeForSymbol[pairKey] = 'REJECTED: ${supVet.reason}';
            continue;
          }

          final executed = paperBroker.executeEntry(
            positionId: 'POS_${++orderSeq}',
            orderId: 'ORD_$orderSeq',
            symbol: pairKey,
            rawReferencePrice: refAsk,
            sizing: sizing,
            signalCandleCloseMs: opp.evaluation.evaluatedCandleCloseMs,
            executedAtMs: now,
            reason: opp.evaluation.reason,
          );

          availableCashUsdt += executed.cashDeltaUsdt;
          openPositions.insert(0, executed.position);
          orders.insert(0, executed.order);
          processedEntrySignalKeys
              .add('${pairKey}_${opp.evaluation.evaluatedCandleCloseMs}');
          acceptedOrders++;
          whyNoTradeForSymbol[pairKey] =
              'EXECUTED PAPER BUY: Qty ${executed.position.quantity} @ \$${executed.position.entryPrice.toStringAsFixed(2)}';
          whyNoTradeForSymbol[opp.market.symbol] =
              whyNoTradeForSymbol[pairKey]!;

          if (onTradeAlert != null) {
            await onTradeAlert!(
              TradeAlertFormatter.formatEntryAlert(
                executed.position,
                executed.order,
              ),
            );
          }
        }
      }

      // Recompute equity after any entries
      double finalOpenVal = 0.0;
      for (final p in openPositions) {
        final mark = liveTickerPrices[p.symbol] ??
            closedCandlePrices[p.symbol] ??
            p.entryPrice;
        finalOpenVal += (p.quantity * mark) - (p.quantity * mark * 0.001);
      }
      accountEquityUsdt = availableCashUsdt + finalOpenVal;

      scanDiagnostics = ScanCycleDiagnosticsSnapshot(
        lastCycleTimestampMs: now,
        lastSuccessfulScanMs: now,
        totalPairsDiscovered: catalogue.totalDiscoveredCount,
        activePairsCount: catalogue.activeMarketsCount,
        eligiblePairsCount: eligibleMarkets.length,
        rejectedPairsCount:
            catalogue.totalDiscoveredCount - eligibleMarkets.length,
        lastCatalogueRefreshMs: catalogue.lastSuccessfulRefreshMs,
        totalPairsEvaluated: evaluatedCount,
        pairsSkippedCount: skippedCount,
        skippedPairsReasons: skippedReasons,
        signalsGeneratedCount: totalSignals,
        buySignalsCount: buySignals,
        sellSignalsCount: sellSignals,
        rejectedSignalsCount: rejectedSignals,
        signalRejectionReasons: rejectionReasons,
        paperOrdersSubmittedCount: submittedOrders,
        acceptedOrdersCount: acceptedOrders,
        rejectedOrdersCount: rejectedOrders,
        coindcxRestStatus: 'HEALTHY_200_OK',
        webSocketStatus: 'REST_POLLING_ACTIVE',
        recoveryStateLabel: 'NORMAL',
      );

      lastBackgroundCycleError = null;
      if (state == BotEngineState.running) {
        if (acceptedOrders > 0) {
          statusBannerMessage =
              'PAPER BOT RUNNING • Executed $acceptedOrders Order(s) • Open: ${openPositions.length}/${riskManager.config.maxConcurrentOpenPositions}';
        } else {
          statusBannerMessage =
              'PAPER BOT RUNNING • Scanned $evaluatedCount/${eligibleMarkets.length} Eligible Pairs (No valid entry signal) • Open: ${openPositions.length}/${riskManager.config.maxConcurrentOpenPositions}';
        }
      }

      await _executeHighVolatilityCryptoCycle(
        catalogue: catalogue,
        now: now,
        allowTradingExecution: allowTradingExecution,
        cycleCandles15mByPair: cycleCandles15mByPair,
        cycleCandles1hByPair: cycleCandles1hByPair,
        cycleEvalByPair: cycleEvalByPair,
      );

      await _persistCurrentState(now);
      if (onNotificationUpdate != null) {
        await onNotificationUpdate!(
          'Ankit AI Trader (${state.dashboardLabel})',
          'Equity: \$${accountEquityUsdt.toStringAsFixed(2)} | Open: ${openPositions.length}/${riskManager.config.maxConcurrentOpenPositions} | Eligible Pairs: ${eligibleMarkets.length}',
        );
      }
    } catch (e) {
      lastBackgroundCycleError = e.toString();
      await persistence.saveStartupDiagnostics(
        lastBackgroundCycleError: lastBackgroundCycleError,
      );
      await persistence.logDiagnosticEvent(
        'CYCLE_ERROR',
        'Non-fatal background cycle error isolated: $e',
      );
    } finally {
      _isCycleInFlight = false;
    }
  }


  Future<void> _executeHighVolatilityCryptoCycle({
    required MarketCatalogueSnapshot catalogue,
    required int now,
    required bool allowTradingExecution,
    required Map<String, List<Candle>> cycleCandles15mByPair,
    required Map<String, List<Candle>> cycleCandles1hByPair,
    required Map<String, StrategyEvaluationResult> cycleEvalByPair,
  }) async {
    try {
      final persistedHv = await persistence.loadPortfolioAccountSnapshot(
        PortfolioId.highVolatility,
      );
      if (persistedHv != null) {
        await dualPortfolioManager.syncHighVolatilitySnapshot(persistedHv);
      }

      var hvSnap = dualPortfolioManager.snapshotFor(PortfolioId.highVolatility);
      if (!hvSnap.executionEnabled || hvSnap.isResearchOnlyMode) {
        return;
      }

      // 1. Evaluate open High-Volatility positions on closed candles via PaperBroker
      for (final pos in List<PaperPosition>.from(hvSnap.openPositions)) {
        if (CoinDcxPortfolioProvider.isPreciousMetalSymbol(pos.symbol)) {
          continue;
        }
        try {
          final c15 = cycleCandles15mByPair[pos.symbol] ??
              await marketService.fetchClosedCandles(
                pair: pos.symbol,
                interval: '15m',
                nowMs: now,
                limit: 80,
              );
          final c1h = cycleCandles1hByPair[pos.symbol] ??
              await marketService.fetchClosedCandles(
                pair: pos.symbol,
                interval: '1h',
                nowMs: now,
                limit: 65,
              );
          if (c15.isNotEmpty) {
            final latestClosed = c15.last;
            closedCandlePrices[pos.symbol] = latestClosed.close;
            final eval = cycleEvalByPair[pos.symbol] ??
                strategyEngine.evaluate(
                  symbol: pos.symbol,
                  closedCandles15m: c15,
                  closedCandles1h: c1h,
                  nowMs: now,
                );
            final exitCheck = paperBroker.evaluateOpenPositionOnClosedCandle(
              position: pos,
              closedCandle: latestClosed,
              nextOrderId: 'HV_ORD_${++orderSeq}',
              nextTradeId: 'HV_TRD_$orderSeq',
              strategySignal: eval.signal,
            );
            if (exitCheck.closedTrade != null && exitCheck.exitOrder != null) {
              await dualPortfolioManager.closeIsolatedPaperPosition(
                portfolioId: PortfolioId.highVolatility,
                positionId: pos.id,
                exitPrice: exitCheck.exitOrder!.executedPrice,
                nowMs: now,
                exitReason: exitCheck.closedTrade!.exitReason,
              );
            }
          }
        } catch (_) {}
      }

      hvSnap = dualPortfolioManager.snapshotFor(PortfolioId.highVolatility);

      // 2. Mark-to-market equity & enforce 15% portfolio loss lockout independently
      double hvOpenVal = 0.0;
      for (final p in hvSnap.openPositions) {
        final mark = liveTickerPrices[p.symbol] ??
            closedCandlePrices[p.symbol] ??
            p.entryPrice;
        hvOpenVal += (p.quantity * mark) - (p.quantity * mark * 0.001);
      }
      final hvEquity = hvSnap.availableCashUsdt + hvOpenVal;
      final hvLossLocked =
          await dualPortfolioManager.evaluateAndEnforcePortfolioLossLimit(
        portfolioId: PortfolioId.highVolatility,
        currentEquityUsdt: hvEquity,
        nowMs: now,
      );
      hvSnap = dualPortfolioManager.snapshotFor(PortfolioId.highVolatility);
      final todayUtc = RiskManager.currentUtcDateString(now);
      final hvDailyLocked = hvSnap.lockedDailyLossUtcDate == todayUtc ||
          riskManager.shouldLockDailyLoss(
            startOfDayEquityUsdt: hvSnap.startOfDayEquityUsdt,
            currentEquityUsdt: hvEquity,
          );
      if (!allowTradingExecution ||
          state != BotEngineState.running ||
          hvLossLocked ||
          hvDailyLocked) {
        return;
      }

      // 3. Evaluate eligible CoinDCX USDT crypto pairs (Gold/Silver XAUUSD/XAGUSD remain RESEARCH-ONLY)
      final eligibleCrypto = catalogue.allMarkets
          .where((m) =>
              m.isEligibleForPaperTrading &&
              m.quoteCurrency.toUpperCase() == 'USDT' &&
              m.pair.isNotEmpty &&
              !CoinDcxPortfolioProvider.isPreciousMetalSymbol(m.symbol))
          .toList();

      for (final market in eligibleCrypto) {
        hvSnap = dualPortfolioManager.snapshotFor(PortfolioId.highVolatility);
        if (hvSnap.openPositions.length >= hvSnap.configuredMaxOpenPositions) {
          break;
        }
        final pairKey = market.pair;
        final c15 = cycleCandles15mByPair[pairKey];
        final eval = cycleEvalByPair[pairKey];
        if (c15 == null || eval == null) continue;

        final ticker = market.latestTicker ??
            CoinDcxMarketService.matchTickerForMarket(
              symbol: market.symbol,
              coindcxName: market.coindcxName,
              pair: market.pair,
              tickersByKey: liveTickers,
            );
        if (ticker == null || !ticker.isFresh(now, maxAgeMs: 300000)) {
          continue;
        }

        final hvClass = dualPortfolioManager.classifier.classifyCryptoMarket(
          market: market,
          closedCandles: c15,
          nowMs: now,
          portfolioExecutionApproved: hvSnap.executionEnabled,
        );
        if (!hvClass.isExecutionAuthorized || !hvClass.qualifiesAsHighVolatility) {
          continue;
        }

        if (eval.signal != StrategySignalType.buy) {
          continue;
        }

        final spec = dualPortfolioManager.highVolProvider
            .getInstrumentSpecification(market.symbol, discoveredRecord: market);
        final refAsk = ticker.ask > 0 ? ticker.ask : eval.closePrice;
        final estFill = paperBroker.computeBuyFillPrice(refAsk);
        final slPrice = estFill - (eval.atr14_15m * riskManager.config.stopLossAtrMultiplier);
        final tpPrice = estFill + (eval.atr14_15m * riskManager.config.takeProfitAtrMultiplier);

        final vet = dualPortfolioManager.vetAndSizePortfolioOrder(
          portfolioId: PortfolioId.highVolatility,
          instrumentSpec: spec,
          entryPrice: estFill,
          stopLossPrice: slPrice,
          spreadPct: ticker.spreadPct,
          atr14: eval.atr14_15m,
          isDataFresh: ticker.isFresh(now, maxAgeMs: 300000),
          nowMs: now,
        );
        if (!vet.approved || vet.approvedQuantity <= 0) {
          continue;
        }

        await dualPortfolioManager.openIsolatedPaperPosition(
          portfolioId: PortfolioId.highVolatility,
          instrumentSpec: spec,
          entryPrice: estFill,
          stopLossPrice: vet.stopLossPrice,
          takeProfitPrice: tpPrice,
          quantity: vet.approvedQuantity,
          nowMs: now,
        );
      }
    } catch (_) {
      // High-Volatility cycle errors are isolated and never crash the Crypto engine
    }
  }

  Future<void> _persistCurrentState(int nowMs) async {
    await persistence.saveFullState(
      botState: state,
      userIntention: userIntention,
      availableCashUsdt: availableCashUsdt,
      accountEquityUsdt: accountEquityUsdt,
      maxDrawdownLocked: maxDrawdownLocked,
      lockedDailyLossUtcDate: lockedDailyLossUtcDate,
      lastStopLossClosedAtMs: lastStopLossClosedAtMs,
      lastHeartbeatMs: lastHeartbeatMs ?? nowMs,
      lastMarketDataUpdateMs: lastMarketDataUpdateMs,
      lastCandleUpdateMs: lastCandleUpdateMs,
      runningSinceMs: runningSinceMs,
      totalActiveMs: totalActiveMs,
      orderSeq: orderSeq,
      statusBannerMessage: statusBannerMessage,
      liveTickerPrices: liveTickerPrices,
      liveTickers: liveTickers,
      closedCandlePrices: closedCandlePrices,
      whyNoTradeForSymbol: whyNoTradeForSymbol,
      openPositions: openPositions,
      orders: orders,
      closedTrades: closedTrades,
      processedEntrySignalKeys: processedEntrySignalKeys,
      scanDiagnostics: scanDiagnostics,
      lastStartupAttemptMs: lastStartupAttemptMs,
      lastStartupError: lastStartupError,
      lastShutdownReason: lastShutdownReason,
      lastBackgroundCycleError: lastBackgroundCycleError,
    );
  }

  void dispose() {
    _disposed = true;
    _cycleTimer?.cancel();
  }
}

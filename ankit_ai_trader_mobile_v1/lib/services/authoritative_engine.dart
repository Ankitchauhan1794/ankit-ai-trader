import 'dart:async';
import 'dart:math' as math;
import '../models/trading_models.dart';
import 'coindcx_market_service.dart';
import 'execution_and_risk_hub.dart';
import 'paper_broker.dart';
import 'persistence_db.dart';
import 'strategy_engine.dart';
import 'trade_alert_formatter.dart';

class AuthoritativeTradingEngine {
  static const String authoritativeLockName = 'AUTHORITATIVE_ENGINE_LOCK';
  static const List<String> watchedSymbols = ['B-BTC_USDT', 'B-ETH_USDT'];
  static const int maxEligiblePairsPerScanCycle = 25;

  final CoinDcxMarketService marketService;
  final PersistenceDatabase persistence;
  final PaperBroker broker;
  final StrategyEngine strategyEngine;
  final IndependentRiskSupervisor riskSupervisor;
  final int Function() nowMsProvider;
  final Future<void> Function(String title, String text)? onNotificationUpdate;
  final Future<bool> Function(TradeAlertPayload alert)? onTradeAlert;
  final Future<void> Function(int delayMs, String reason)? onSchedulerRetry;
  final Future<void> Function(UserSessionIntention intention)?
      onSyncUserIntention;
  final bool verifyReachabilityBeforeNetworkPause;

  final String _ownerId;
  bool _isCycleExecuting = false;
  Timer? _retryTimer;

  AuthoritativeTradingEngine({
    required this.marketService,
    required this.persistence,
    PaperBroker? broker,
    this.strategyEngine = const StrategyEngine(),
    IndependentRiskSupervisor? riskSupervisor,
    int Function()? nowMsProvider,
    this.onNotificationUpdate,
    this.onTradeAlert,
    this.onSchedulerRetry,
    this.onSyncUserIntention,
    this.verifyReachabilityBeforeNetworkPause = false,
  })  : broker = broker ?? PaperBroker(),
        riskSupervisor = riskSupervisor ?? IndependentRiskSupervisor(),
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
            scanDiagnostics: snap.scanDiagnostics,
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
          scanDiagnostics: snap.scanDiagnostics,
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
          scanDiagnostics: snap.scanDiagnostics,
        );
        await onSyncUserIntention?.call(UserSessionIntention.stopped);
        return true;

      case 'RESET':
        _retryTimer?.cancel();
        await _resetRecoveryTracking();
        // Stage 8: Preserve notifiedAlertIds across RESET
        final preservedAlerts = await persistence.getNotifiedAlertIds();
        broker.manualResetPaperAccount();
        riskSupervisor.consecutiveLosses = 0;
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
          scanDiagnostics: const ScanCycleDiagnosticsSnapshot(),
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

  /// Compute ranking score for valid BUY signals across multiple eligible pairs (Part 4 & Part 5).
  static double computeOpportunityRankingScore({
    required StrategyEvaluationResult evaluation,
    required LiveMarketTicker? ticker,
  }) {
    final px = evaluation.closePrice > 0 ? evaluation.closePrice : 1.0;
    final ema15mSpreadBps =
        ((evaluation.ema20_15m - evaluation.ema50_15m) / px) * 10000.0;
    final ema1hSpreadBps =
        ((evaluation.ema20_1h - evaluation.ema50_1h) / px) * 10000.0;
    // Prefer RSI near middle of 50-65 band (57.5)
    final rsiScore =
        (15.0 - (evaluation.rsi14_15m - 57.5).abs()).clamp(0.0, 15.0) * 2.0;
    final spreadBps = ticker?.spreadBps ?? 10.0;
    final tightSpreadScore = (25.0 - spreadBps).clamp(0.0, 25.0) * 1.2;
    final volScore = ticker != null && ticker.volume24h > 0
        ? (math.log(ticker.volume24h + 1.0) / math.log(1000000.0))
                .clamp(0.0, 1.0) *
            20.0
        : 5.0;

    return (ema15mSpreadBps.clamp(0.0, 50.0) * 0.6) +
        (ema1hSpreadBps.clamp(0.0, 80.0) * 0.3) +
        rsiScore +
        tightSpreadScore +
        volScore;
  }

  /// Stage 8, Part 4, Part 5 & Part 6: Single authoritative engine execution covered by SQLite lease lock.
  /// Dynamically discovers all CoinDCX markets, evaluates every eligible pair, ranks valid BUY opportunities,
  /// and executes within the $100 / 1-max-open-position portfolio risk controls.
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

      // Part 2: If paused due to network/stale data and Auto Resume is OFF, do NOT silently resume on background ticks!
      // Only resume when transitionToRunningOnSuccess == true (explicit START/RESUME) or snap.autoResumeEnabled == true.
      if (snap.botState.isNetworkOrStalePause &&
          !snap.autoResumeEnabled &&
          !transitionToRunningOnSuccess) {
        return false;
      }

      // Part 3 & Part 4: Refresh dynamic CoinDCX market catalogue so newly listed & eligible pairs enter the pipeline automatically.
      try {
        await marketService.refreshMarketCatalogue(force: false, nowMs: nowMs);
      } catch (_) {}

      // Stage 12 & 14: Fetch live tickers for current price, equity, uPnL & live SL/TP
      Map<String, LiveMarketTicker> liveTickers = {};
      String restStatus = 'OK';
      try {
        liveTickers = await marketService.fetchLiveTickers(nowMs: nowMs);
      } catch (e) {
        restStatus = 'ERROR: $e';
        liveTickers = Map.from(marketService.latestTickers);
      }

      if (liveTickers.isEmpty) {
        if (userWantsRunning) {
          await _handleBoundedRecoveryOrPause(
            snap: snap,
            nowMs: nowMs,
            pauseState: BotEngineState.pausedNetworkLoss,
            reason:
                'Live ticker feed unavailable — waiting for network recovery',
          );
        }
        return false;
      }

      final catSnap = marketService.latestCatalogueSnapshot;
      final livePrices = {
        for (final e in liveTickers.entries) e.key: e.value.lastPrice,
      };
      final closedPrices = Map<String, double>.from(snap.closedCandlePrices);
      final whyNoTrade = Map<String, String>.from(snap.whyNoTradeForSymbol);
      final canTrade = allowTradingExecution && userWantsRunning;
      int latestCandleMs = snap.lastCandleUpdateMs ?? 0;

      // Build dynamic list of eligible pairs (sorted by volume/tight spread, capped at maxEligiblePairsPerScanCycle)
      final eligibleRecords = List<CoinDcxMarketRecord>.from(
        catSnap.eligibleMarkets,
      )..sort((a, b) {
          final volA = a.latestTicker?.volume24h ?? 0.0;
          final volB = b.latestTicker?.volume24h ?? 0.0;
          return volB.compareTo(volA);
        });

      final dynamicEligiblePairs = eligibleRecords
          .take(maxEligiblePairsPerScanCycle)
          .map((m) => m.pair)
          .where((p) => p.isNotEmpty)
          .toList();

      final openPositionSymbols =
          broker.openPositions.map((p) => p.symbol).toSet();

      final activeSymbolsToEvaluate = <String>{
        ...openPositionSymbols,
        ...(dynamicEligiblePairs.isNotEmpty
            ? dynamicEligiblePairs
            : watchedSymbols),
      };

      final skippedPairsReasons = <String, String>{};
      final signalRejectionReasons = <String, String>{};
      final rankedBuyOpportunities = <RankedSignalOpportunity>[];

      int pairsEvaluatedCount = 0;
      int signalsGeneratedCount = 0;
      int buySignalsCount = 0;
      int sellSignalsCount = 0;
      int rejectedSignalsCount = 0;
      int paperOrdersSubmittedCount = 0;
      int acceptedOrdersCount = 0;
      int rejectedOrdersCount = 0;
      int newOrderSeqDelta = 0;
      bool anyNetworkError = false;
      String? lastSymbolFetchError;

      // Record catalogue-level rejections in skippedPairsReasons for visibility
      for (final m in catSnap.allMarkets) {
        if (!m.isEligibleForPaperTrading && m.pair.isNotEmpty) {
          skippedPairsReasons[m.pair] =
              '${m.eligibilityStatus.categoryLabel}: ${m.eligibilityReason}';
        }
      }

      // Phase 1: Fetch candles, evaluate SL/TP & SELL exits for open positions, and collect BUY signals across all eligible pairs
      for (final symbol in activeSymbolsToEvaluate) {
        List<Candle> candles15m;
        List<Candle> candles1h;
        try {
          candles15m = await _fetchClosedCandlesWithRetry(symbol, '15m', nowMs);
          candles1h = await _fetchClosedCandlesWithRetry(symbol, '1h', nowMs);
        } catch (e) {
          anyNetworkError = true;
          lastSymbolFetchError = 'Candle fetch error for $symbol: $e';
          skippedPairsReasons[symbol] = 'SKIPPED: Candle fetch failed ($e)';
          whyNoTrade[symbol] = 'Why no trade: Candle fetch failed';
          continue;
        }

        if (marketService.isDataStale(
          closedCandles15m: candles15m,
          nowMs: nowMs,
        )) {
          skippedPairsReasons[symbol] =
              'SKIPPED: Stale or incomplete 15m candle history (${candles15m.length} bars)';
          whyNoTrade[symbol] = 'Why no trade: Stale data for $symbol';
          continue;
        }

        pairsEvaluatedCount++;
        final latestCandle = candles15m.last;
        closedPrices[symbol] = latestCandle.close;
        if (latestCandle.closeTimeMs > latestCandleMs) {
          latestCandleMs = latestCandle.closeTimeMs;
        }

        final discoveredRecord = marketService.catalogueByPair[symbol];
        final pairMeta = discoveredRecord != null
            ? discoveredRecord.toMarketPairMetadata()
            : MarketPairMetadata(
                symbol: symbol,
                baseCurrency: symbol.contains('BTC') ? 'BTC' : 'ETH',
                quoteCurrency: 'USDT',
              );

        // 1A. If we hold an open position on this symbol, process SL/TP & bearish EMA crossover exits immediately
        final holdsPositionOnSymbol =
            broker.openPositions.any((p) => p.symbol == symbol);
        if (holdsPositionOnSymbol) {
          final exitOutcome = broker.processClosedCandleStream(
            symbol: symbol,
            closedCandles15m: candles15m,
            closedCandles1h: candles1h,
            strategyEngine: strategyEngine,
            pairMetadata: pairMeta,
            currentMarkPrices: livePrices,
            liveTicker: liveTickers[symbol],
            allowNewEntries: false,
          );
          if (exitOutcome.whyNoTradeReason != null) {
            whyNoTrade[symbol] = exitOutcome.whyNoTradeReason!;
          }
          if (exitOutcome.newOrders.isNotEmpty) {
            newOrderSeqDelta += exitOutcome.newOrders.length;
            paperOrdersSubmittedCount += exitOutcome.newOrders.length;
            acceptedOrdersCount += exitOutcome.newOrders.length;
          }
          for (final closedTrd in exitOutcome.newClosedTrades) {
            riskSupervisor.recordClosedTradeOutcome(closedTrd.realizedPnlUsdt);
          }
          await _emitAlertsForNewOrders(exitOutcome);

          if (exitOutcome.triggeredSafetyState != null) {
            final eq = broker.accountEquityUsdt(livePrices);
            await persistence.logDiagnosticEvent(
              'SAFETY_LOCK',
              exitOutcome.safetyMessage ??
                  exitOutcome.triggeredSafetyState!.name,
              timestampMs: nowMs,
            );
            await persistence.saveFullState(
              botState: exitOutcome.triggeredSafetyState!,
              availableCashUsdt: broker.availableCashUsdt,
              accountEquityUsdt: eq,
              maxDrawdownLocked: broker.maxDrawdownLocked,
              lockedDailyLossUtcDate: broker.lockedDailyLossUtcDate,
              lastStopLossClosedAtMs: broker.lastStopLossClosedAtMs,
              lastHeartbeatMs: nowMs,
              lastMarketDataUpdateMs: nowMs,
              lastCandleUpdateMs: latestCandleMs,
              orderSeq: snap.orderSeq + newOrderSeqDelta,
              statusBannerMessage:
                  exitOutcome.safetyMessage ?? 'SAFETY LOCK TRIGGERED',
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

        // 1B. Evaluate strategy on closed 15m and 1h candles
        final eval = strategyEngine.evaluateClosedCandles(
          symbol: symbol,
          closedCandles15m: candles15m,
          closedCandles1h: candles1h,
        );
        whyNoTrade[symbol] = eval.reason;

        if (eval.signal == StrategySignalType.sell) {
          signalsGeneratedCount++;
          sellSignalsCount++;
        } else if (eval.signal == StrategySignalType.buy) {
          signalsGeneratedCount++;
          buySignalsCount++;

          final allowEntryForMarket = canTrade &&
              (discoveredRecord == null ||
                  discoveredRecord.isEligibleForPaperTrading);
          if (!allowEntryForMarket) {
            rejectedSignalsCount++;
            final rejReason = discoveredRecord != null &&
                    !discoveredRecord.isEligibleForPaperTrading
                ? 'Rejected: Market ${discoveredRecord.pair} is not eligible (${discoveredRecord.eligibilityReason})'
                : 'Rejected: Trading execution not active in current mode';
            signalRejectionReasons[symbol] = rejReason;
            whyNoTrade[symbol] = rejReason;
            continue;
          }

          final ticker = liveTickers[symbol] ??
              discoveredRecord?.latestTicker ??
              LiveMarketTicker(
                symbol: symbol,
                lastPrice: latestCandle.close,
                bid: latestCandle.close,
                ask: latestCandle.close,
                high24h: latestCandle.high,
                low24h: latestCandle.low,
                volume24h: latestCandle.volume,
                change24hPct: 0.0,
                timestampMs: latestCandle.closeTimeMs,
              );

          final recordForOpportunity = discoveredRecord ??
              CoinDcxMarketRecord(
                coindcxName: symbol,
                symbol: symbol,
                pair: symbol,
                ecode: 'B',
                baseCurrencyShortName: 'USDT',
                targetCurrencyShortName:
                    symbol.contains('BTC') ? 'BTC' : 'ETH',
                status: 'active',
                baseCurrencyPrecision: 2,
                targetCurrencyPrecision: 5,
                minQuantity: 0.00001,
                maxQuantity: 90000000.0,
                maxQuantityMarket: 100000.0,
                step: 0.00001,
                minNotional: 5.0,
                minPrice: 0.01,
                maxPrice: 1000000.0,
                orderTypes: const ['limit_order', 'market_order'],
                latestTicker: ticker,
                lastMetadataRefreshMs: nowMs,
                eligibilityStatus:
                    MarketEligibilityStatus.eligibleForPaperTrading,
              );

          final score = computeOpportunityRankingScore(
            evaluation: eval,
            ticker: ticker,
          );

          rankedBuyOpportunities.add(
            RankedSignalOpportunity(
              market: recordForOpportunity,
              evaluation: eval,
              closedCandles15m: candles15m,
              closedCandles1h: candles1h,
              ticker: ticker,
              rankingScore: score,
            ),
          );
        }
      }

      // If zero pairs could be evaluated, pause safely for network or stale data
      if (pairsEvaluatedCount == 0 && activeSymbolsToEvaluate.isNotEmpty) {
        if (userWantsRunning) {
          final pauseTarget = anyNetworkError
              ? BotEngineState.pausedNetworkLoss
              : BotEngineState.pausedStaleData;
          final pauseReason = anyNetworkError
              ? (lastSymbolFetchError ?? 'All candle requests failed')
              : 'Why no trade: Stale data across all evaluated pairs';
          await _handleBoundedRecoveryOrPause(
            snap: snap,
            nowMs: nowMs,
            pauseState: pauseTarget,
            reason: pauseReason,
          );
        }
        return false;
      }

      // Phase 2: Sort all valid BUY opportunities by descending rankingScore and execute within portfolio risk limits
      rankedBuyOpportunities
          .sort((a, b) => b.rankingScore.compareTo(a.rankingScore));

      for (final opp in rankedBuyOpportunities) {
        final symbol = opp.market.pair;
        final pairMeta = opp.market.toMarketPairMetadata();

        // Check portfolio max concurrent open positions (1) before submitting
        if (broker.openPositions.length >=
            broker.riskManager.config.maxConcurrentOpenPositions) {
          rejectedSignalsCount++;
          rejectedOrdersCount++;
          const reason =
              'Why no trade: Max concurrent open positions (1/1) reached after higher-ranked opportunity';
          signalRejectionReasons[symbol] = reason;
          whyNoTrade[symbol] = reason;
          continue;
        }

        paperOrdersSubmittedCount++;
        final outcome = broker.processClosedCandleStream(
          symbol: symbol,
          closedCandles15m: opp.closedCandles15m,
          closedCandles1h: opp.closedCandles1h,
          strategyEngine: strategyEngine,
          pairMetadata: pairMeta,
          currentMarkPrices: livePrices,
          liveTicker: opp.ticker,
          allowNewEntries: true,
        );

        if (outcome.whyNoTradeReason != null) {
          whyNoTrade[symbol] = outcome.whyNoTradeReason!;
        }

        if (outcome.newOrders.isNotEmpty) {
          acceptedOrdersCount += outcome.newOrders.length;
          newOrderSeqDelta += outcome.newOrders.length;
          await _emitAlertsForNewOrders(outcome);
        } else {
          rejectedSignalsCount++;
          rejectedOrdersCount++;
          signalRejectionReasons[symbol] =
              outcome.whyNoTradeReason ?? 'Rejected by RiskManager / PaperBroker';
        }

        if (outcome.triggeredSafetyState != null) {
          final eq = broker.accountEquityUsdt(livePrices);
          await persistence.logDiagnosticEvent(
            'SAFETY_LOCK',
            outcome.safetyMessage ?? outcome.triggeredSafetyState!.name,
            timestampMs: nowMs,
          );
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
            orderSeq: snap.orderSeq + newOrderSeqDelta,
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

      // Check drawdown / daily loss even when no BUY signals occurred
      if (broker.enforceMaxDrawdownCheck(livePrices)) {
        final eq = broker.accountEquityUsdt(livePrices);
        await persistence.saveFullState(
          botState: BotEngineState.stoppedMaxDrawdownReached,
          availableCashUsdt: broker.availableCashUsdt,
          accountEquityUsdt: eq,
          maxDrawdownLocked: true,
          lockedDailyLossUtcDate: broker.lockedDailyLossUtcDate,
          lastStopLossClosedAtMs: broker.lastStopLossClosedAtMs,
          lastHeartbeatMs: nowMs,
          lastMarketDataUpdateMs: nowMs,
          lastCandleUpdateMs: latestCandleMs,
          orderSeq: snap.orderSeq + newOrderSeqDelta,
          statusBannerMessage:
              'Account equity reached or fell below \$90.00 floor. Engine stopped; manual review & reset required.',
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

      // Cycle succeeded with fresh validated data -> clear recovery tracking & lastError!
      await _resetRecoveryTracking();
      final eq = broker.accountEquityUsdt(livePrices);
      final targetState =
          userWantsRunning ? BotEngineState.running : snap.botState;
      final banner = userWantsRunning
          ? 'PAPER BOT RUNNING — Scanned $pairsEvaluatedCount pair(s) • Heartbeat ${_formatHhMmSs(nowMs)}'
          : snap.statusBannerMessage;

      final scanDiag = ScanCycleDiagnosticsSnapshot(
        lastCycleTimestampMs: nowMs,
        lastSuccessfulScanMs: nowMs,
        totalPairsDiscovered: catSnap.totalDiscoveredCount > 0
            ? catSnap.totalDiscoveredCount
            : activeSymbolsToEvaluate.length,
        activePairsCount: catSnap.activeMarketsCount > 0
            ? catSnap.activeMarketsCount
            : activeSymbolsToEvaluate.length,
        eligiblePairsCount: catSnap.eligibleMarketsCount > 0
            ? catSnap.eligibleMarketsCount
            : activeSymbolsToEvaluate.length,
        rejectedPairsCount: catSnap.rejectedMarketsCount,
        lastCatalogueRefreshMs: catSnap.lastSuccessfulRefreshMs ?? nowMs,
        totalPairsEvaluated: pairsEvaluatedCount,
        pairsSkippedCount: skippedPairsReasons.length,
        skippedPairsReasons: skippedPairsReasons,
        signalsGeneratedCount: signalsGeneratedCount,
        buySignalsCount: buySignalsCount,
        sellSignalsCount: sellSignalsCount,
        rejectedSignalsCount: rejectedSignalsCount,
        signalRejectionReasons: signalRejectionReasons,
        paperOrdersSubmittedCount: paperOrdersSubmittedCount,
        acceptedOrdersCount: acceptedOrdersCount,
        rejectedOrdersCount: rejectedOrdersCount,
        coindcxRestStatus: restStatus,
        webSocketStatus: 'REST_AUTHORITATIVE_4S_POLL',
        recoveryStateLabel: 'NORMAL (0 RETRIES)',
      );

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
        orderSeq: snap.orderSeq + newOrderSeqDelta + 1,
        statusBannerMessage: banner,
        liveTickerPrices: livePrices,
        liveTickers: liveTickers,
        closedCandlePrices: closedPrices,
        whyNoTradeForSymbol: whyNoTrade,
        openPositions: broker.openPositions,
        orders: broker.orders,
        closedTrades: broker.closedTrades,
        processedEntrySignalKeys: broker.processedEntrySignalKeys,
        scanDiagnostics: scanDiag,
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
        await Future<void>.delayed(const Duration(milliseconds: 200));
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

    final updatedDiag = ScanCycleDiagnosticsSnapshot(
      lastCycleTimestampMs: nowMs,
      lastSuccessfulScanMs: snap.scanDiagnostics.lastSuccessfulScanMs,
      totalPairsDiscovered: snap.scanDiagnostics.totalPairsDiscovered,
      activePairsCount: snap.scanDiagnostics.activePairsCount,
      eligiblePairsCount: snap.scanDiagnostics.eligiblePairsCount,
      rejectedPairsCount: snap.scanDiagnostics.rejectedPairsCount,
      lastCatalogueRefreshMs: snap.scanDiagnostics.lastCatalogueRefreshMs,
      totalPairsEvaluated: 0,
      pairsSkippedCount: snap.scanDiagnostics.pairsSkippedCount,
      skippedPairsReasons: snap.scanDiagnostics.skippedPairsReasons,
      signalsGeneratedCount: 0,
      buySignalsCount: 0,
      sellSignalsCount: 0,
      rejectedSignalsCount: 0,
      signalRejectionReasons: snap.scanDiagnostics.signalRejectionReasons,
      paperOrdersSubmittedCount: 0,
      acceptedOrdersCount: 0,
      rejectedOrdersCount: 0,
      coindcxRestStatus: 'DEGRADED: $reason',
      webSocketStatus: 'DISCONNECTED_OR_WAITING',
      recoveryStateLabel:
          '${pauseState.dashboardLabel} (RETRY #$attempt • AutoResume=${snap.autoResumeEnabled ? "ON" : "OFF"})',
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
      statusBannerMessage: 'PAUSED (${pauseState.dashboardLabel}): $reason',
      liveTickerPrices: snap.liveTickerPrices,
      liveTickers: snap.liveTickers,
      closedCandlePrices: snap.closedCandlePrices,
      whyNoTradeForSymbol: snap.whyNoTradeForSymbol,
      openPositions: broker.openPositions,
      orders: broker.orders,
      closedTrades: broker.closedTrades,
      processedEntrySignalKeys: broker.processedEntrySignalKeys,
      scanDiagnostics: updatedDiag,
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

  /// Stage 9 & Part 2: Network transition handler respecting autoResumeEnabled (default OFF).
  /// When ON, resumes ONLY after fresh validated data and ONLY from network/stale-data pauses.
  /// NEVER resumes from user PAUSE/STOP, daily-loss lock, or drawdown lock.
  Future<void> handleNetworkTransition(bool connected) async {
    final nowMs = nowMsProvider();
    final snap = await persistence.loadFullState();
    if (!connected) {
      if (snap.userIntention == UserSessionIntention.running &&
          snap.botState == BotEngineState.running) {
        if (verifyReachabilityBeforeNetworkPause) {
          try {
            final probe = await marketService.fetchLiveTickers(nowMs: nowMs);
            if (probe.isNotEmpty) {
              await persistence.logDiagnosticEvent(
                'NETWORK_FLICKER_IGNORED',
                'OS NetworkCallback reported loss, but CoinDCX REST probe succeeded',
                timestampMs: nowMs,
              );
              return;
            }
          } catch (_) {}
        }
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
        snap.botState.isNetworkOrStalePause) {
      if (snap.autoResumeEnabled) {
        await persistence.putKv(
          'botState',
          BotEngineState.reconnecting.name,
        );
        await persistence.putKv(
          'statusBannerMessage',
          'RECONNECTING — Validating fresh market data...',
        );
        await executeAuthoritativeCycle(
          allowTradingExecution: true,
          transitionToRunningOnSuccess: true,
        );
      } else {
        await persistence.putKv(
          'statusBannerMessage',
          'PAUSED_BY_NETWORK: Internet restored, but Auto-Resume is OFF — tap RESUME to continue.',
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

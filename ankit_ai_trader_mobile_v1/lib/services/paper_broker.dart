import '../models/trading_models.dart';
import 'coindcx_market_service.dart';
import 'risk_manager.dart';
import 'strategy_engine.dart';

class CandleStreamProcessOutcome {
  final List<StrategyEvaluationResult> evaluations;
  final bool pausedOnMissingNextCandle;
  final String pauseReason;

  const CandleStreamProcessOutcome({
    required this.evaluations,
    this.pausedOnMissingNextCandle = false,
    this.pauseReason = '',
  });
}

class PaperBroker {
  StrategyConfig strategyConfig;
  RiskConfig riskConfig;

  double availableCashUsdt;
  double realizedPnlUsdt;
  final Map<String, PaperPosition> openPositions = {};
  final List<ClosedPaperTrade> closedTrades = [];
  final List<SimulatedOrder> orderHistory = [];
  final Map<String, double> dailyRealizedPnlByUtcDate = {};
  final Map<String, double> dailyStartEquityByUtcDate = {};
  final Map<String, int> lastProcessedCandleCloseMs = {};
  final Set<String> processedEntrySignalKeys = {};
  final Map<String, PendingEntrySignal> pendingSignalsBySymbol = {};

  String currentUtcDateKey = '';
  double startOfDayEquityUsdt;
  bool maxDrawdownLocked = false;
  bool pendingEmergencyLiquidation = false;
  String? lockedDailyLossUtcDate;
  int _orderSeq = 0;

  PaperBroker({
    this.strategyConfig = const StrategyConfig(),
    this.riskConfig = const RiskConfig(),
    double? initialCashUsdt,
    this.realizedPnlUsdt = 0.0,
  })  : availableCashUsdt = initialCashUsdt ?? riskConfig.initialCapitalUsdt,
        startOfDayEquityUsdt = initialCashUsdt ?? riskConfig.initialCapitalUsdt;

  RiskManager get riskManager => RiskManager(config: riskConfig);
  StrategyEngine get strategyEngine => StrategyEngine(config: strategyConfig);

  String _nextId(String prefix, int timestampMs) {
    _orderSeq += 1;
    return '$prefix-$timestampMs-$_orderSeq';
  }

  double unrealizedPnl(Map<String, double> latestPrices) {
    double sum = 0.0;
    for (final pos in openPositions.values) {
      final mark = latestPrices[pos.symbol];
      if (mark != null && mark > 0 && mark.isFinite) {
        sum += pos.unrealizedPnl(mark, riskConfig.feeRate);
      } else {
        sum += pos.unrealizedPnl(pos.entryPrice, riskConfig.feeRate);
      }
    }
    return sum;
  }

  double accountEquity(Map<String, double> latestPrices) {
    double openLiquidationValue = 0.0;
    for (final pos in openPositions.values) {
      final rawMark = latestPrices[pos.symbol];
      final mark =
          (rawMark != null && rawMark > 0 && rawMark.isFinite)
              ? rawMark
              : pos.entryPrice;
      final gross = mark * pos.quantity;
      final exitFee = gross * riskConfig.feeRate;
      openLiquidationValue += (gross - exitFee);
    }
    return availableCashUsdt + openLiquidationValue;
  }

  double currentDrawdownUsdt(Map<String, double> latestPrices) {
    final eq = accountEquity(latestPrices);
    final dd = riskConfig.initialCapitalUsdt - eq;
    return dd > 0 ? dd : 0.0;
  }

  double todayRealizedPnl(int nowEpochMs) {
    final key = RiskManager.utcDayKey(nowEpochMs);
    return dailyRealizedPnlByUtcDate[key] ?? 0.0;
  }

  double todayUnrealizedPnl(Map<String, double> latestPrices) {
    return unrealizedPnl(latestPrices);
  }

  /// Establishes or updates the persistent UTC-day baseline at the first valid market valuation
  /// of a new UTC day, without resetting the $100 account or closing open positions.
  void ensureUtcDayBaseline(int nowEpochMs, Map<String, double> latestPrices) {
    final dayKey = RiskManager.utcDayKey(nowEpochMs);
    final currentEq = accountEquity(latestPrices);
    if (currentUtcDateKey != dayKey) {
      currentUtcDateKey = dayKey;
      if (dailyStartEquityByUtcDate.containsKey(dayKey)) {
        startOfDayEquityUsdt = dailyStartEquityByUtcDate[dayKey]!;
      } else {
        startOfDayEquityUsdt = currentEq;
        dailyStartEquityByUtcDate[dayKey] = currentEq;
      }
      if (lockedDailyLossUtcDate != null && lockedDailyLossUtcDate != dayKey) {
        lockedDailyLossUtcDate = null;
      }
    } else if (!dailyStartEquityByUtcDate.containsKey(dayKey)) {
      startOfDayEquityUsdt = currentEq;
      dailyStartEquityByUtcDate[dayKey] = currentEq;
    }
  }

  double currentUtcDayTotalPnl(
    int nowEpochMs,
    Map<String, double> latestPrices,
  ) {
    ensureUtcDayBaseline(nowEpochMs, latestPrices);
    return accountEquity(latestPrices) - startOfDayEquityUsdt;
  }

  bool isDailyLockedAt(int nowEpochMs, Map<String, double> latestPrices) {
    ensureUtcDayBaseline(nowEpochMs, latestPrices);
    final todayKey = RiskManager.utcDayKey(nowEpochMs);
    final currentEq = accountEquity(latestPrices);

    if (riskManager.isDailyLossLimitReachedAgainstBaseline(
          currentEquityUsdt: currentEq,
          startOfDayEquityUsdt: startOfDayEquityUsdt,
        )) {
      lockedDailyLossUtcDate = todayKey;
      return true;
    }
    return lockedDailyLossUtcDate == todayKey;
  }

  /// Sequential, warm-up-safe, gap-safe candle stream processor.
  ///
  /// FIRST-START WARM-UP RULE:
  /// If `lastProcessedCandleCloseMs[symbol]` is null (fresh account or first time seeing symbol),
  /// historical candles are used ONLY to warm up EMA 20, EMA 50, RSI 14, and ATR 14, and a
  /// checkpoint is established at `closed15m.last.closeTimeMs` WITHOUT generating historical trades
  /// or scheduling historical signals. Signal evaluation for trade entry begins strictly on candles
  /// closing AFTER the user's manual START checkpoint.
  ///
  /// SUBSEQUENT RUNS (OR BACKTEST MODE `allowHistoricalWarmupTrades: true`):
  /// Processes all newly closed 15m candles sequentially in chronological order.
  /// - Never processes the same candle twice.
  /// - Never skips intermediate candles: if a gap between consecutive candles is detected or if
  ///   a pending signal's immediate next candle C+1 is missing, the pending signal is discarded
  ///   and the stream returns `pausedOnMissingNextCandle = true`.
  CandleStreamProcessOutcome processClosedCandleStream({
    required String symbol,
    required List<Candle> closed15m,
    required List<Candle> closed1h,
    required Map<String, double> latestPrices,
    double minNotionalUsdt = 1.0,
    double minQuantity = 0.00001,
    bool allowHistoricalWarmupTrades = false,
  }) {
    if (closed15m.isEmpty) {
      return const CandleStreamProcessOutcome(evaluations: []);
    }

    final interval15mMs = CoinDcxMarketService.intervalDurationMs('15m');
    final lastProcessed = lastProcessedCandleCloseMs[symbol];

    // Fresh account first-start warm-up protection:
    if (lastProcessed == null && !allowHistoricalWarmupTrades) {
      final latestCandle = closed15m.last;
      latestPrices[symbol] = latestCandle.close;
      ensureUtcDayBaseline(latestCandle.closeTimeMs, latestPrices);
      lastProcessedCandleCloseMs[symbol] = latestCandle.closeTimeMs;

      final slice1h = closed1h
          .where((c) => c.closeTimeMs <= latestCandle.closeTimeMs)
          .toList();
      final warmupEval = strategyEngine.evaluateClosedCandles(
        closed15m: closed15m,
        closed1h: slice1h,
        hasOpenPosition: openPositions.containsKey(symbol),
      );
      return CandleStreamProcessOutcome(
        evaluations: [
          StrategyEvaluationResult(
            signalType: StrategySignalType.none,
            description:
                'WARM-UP COMPLETE AT ${latestCandle.closeTimeMs} — AWAITING NEXT CLOSED CANDLE',
            evaluatedCandleCloseMs: latestCandle.closeTimeMs,
            ema20_15m: warmupEval.ema20_15m,
            ema50_15m: warmupEval.ema50_15m,
            rsi14_15m: warmupEval.rsi14_15m,
            atr14_15m: warmupEval.atr14_15m,
            ema20_1h: warmupEval.ema20_1h,
            ema50_1h: warmupEval.ema50_1h,
            higherTimeframeBullish: warmupEval.higherTimeframeBullish,
          ),
        ],
      );
    }

    final unprocessed = lastProcessed == null
        ? closed15m
        : closed15m.where((c) => c.closeTimeMs > lastProcessed).toList();

    if (unprocessed.isEmpty) {
      return CandleStreamProcessOutcome(
        evaluations: [
          StrategyEvaluationResult(
            signalType: StrategySignalType.none,
            description: 'NO NEW CLOSED 15M CANDLES',
            evaluatedCandleCloseMs: closed15m.last.closeTimeMs,
          ),
        ],
      );
    }

    final results = <StrategyEvaluationResult>[];

    for (int i = 0; i < unprocessed.length; i++) {
      final currentCandle = unprocessed[i];
      final prevCloseCheckpoint = lastProcessedCandleCloseMs[symbol];

      // Check for missing candle gap relative to last committed checkpoint
      if (prevCloseCheckpoint != null &&
          currentCandle.openTimeMs != prevCloseCheckpoint) {
        // Genuine candle gap or missed immediate next candle C+1
        final stalePending = pendingSignalsBySymbol.remove(symbol);
        final reason = stalePending != null
            ? 'PAUSED: MISSED IMMEDIATE NEXT CANDLE C+1 FOR PENDING SIGNAL (${stalePending.symbol})'
            : 'PAUSED: MISSING 15M CANDLE GAP DETECTED BETWEEN $prevCloseCheckpoint AND ${currentCandle.openTimeMs}';
        return CandleStreamProcessOutcome(
          evaluations: results,
          pausedOnMissingNextCandle: true,
          pauseReason: reason,
        );
      }

      final currentIdxInFull = closed15m
          .indexWhere((c) => c.closeTimeMs == currentCandle.closeTimeMs);
      final subSlice15m = closed15m.sublist(0, currentIdxInFull + 1);

      latestPrices[symbol] = currentCandle.close;
      ensureUtcDayBaseline(currentCandle.closeTimeMs, latestPrices);

      // If emergency liquidation was waiting for valid market data, execute it now
      if (pendingEmergencyLiquidation && openPositions.isNotEmpty) {
        _triggerMaxDrawdownStop(
          currentCandle.openTimeMs,
          {...latestPrices, symbol: currentCandle.open},
        );
      }

      // Step 1: Execute pending entry signal ONLY if currentCandle is the immediate C+1
      final pending = pendingSignalsBySymbol.remove(symbol);
      if (pending != null) {
        if (currentCandle.openTimeMs == pending.signalCandleCloseMs &&
            !openPositions.containsKey(symbol)) {
          _tryExecutePendingBuyAtOpen(
            pending: pending,
            executionCandle: currentCandle,
            latestPrices: latestPrices,
            minNotionalUsdt: minNotionalUsdt,
            minQuantity: minQuantity,
          );
        } else {
          return CandleStreamProcessOutcome(
            evaluations: results,
            pausedOnMissingNextCandle: true,
            pauseReason:
                'PAUSED: STALE PENDING SIGNAL DISCARDED (EXPECTED OPEN ${pending.signalCandleCloseMs}, GOT ${currentCandle.openTimeMs})',
          );
        }
      }

      // Step 2: Check intrabar SL / TP on existing open position.
      // CRITICAL: Even when Daily Loss Limit is locked, existing positions MUST continue
      // to be managed against Stop-Loss and Take-Profit.
      final activePos = openPositions[symbol];
      if (activePos != null) {
        final exitCheck = strategyEngine.checkStopLossOrTakeProfit(
          position: activePos,
          candle: currentCandle,
        );
        if (exitCheck.shouldExit && exitCheck.exitReferencePrice != null) {
          closePosition(
            symbol: symbol,
            rawExitPrice: exitCheck.exitReferencePrice!,
            executedAtMs: currentCandle.closeTimeMs,
            reason: exitCheck.reason,
            latestPrices: latestPrices,
          );
        }
      }

      // Step 3: Check $90 Maximum Drawdown lock
      if (riskManager.isMaxDrawdownReached(accountEquity(latestPrices))) {
        _triggerMaxDrawdownStop(currentCandle.closeTimeMs, latestPrices);
        lastProcessedCandleCloseMs[symbol] = currentCandle.closeTimeMs;
        results.add(
          StrategyEvaluationResult(
            signalType: StrategySignalType.blockedByRisk,
            description: 'MAXIMUM DRAWDOWN REACHED',
            evaluatedCandleCloseMs: currentCandle.closeTimeMs,
          ),
        );
        continue;
      }

      // Step 4: Check Daily Loss Limit (realized + unrealized against start-of-day baseline)
      final dailyLockedNow =
          isDailyLockedAt(currentCandle.closeTimeMs, latestPrices);

      final slice1h = closed1h
          .where((c) => c.closeTimeMs <= currentCandle.closeTimeMs)
          .toList();

      final eval = strategyEngine.evaluateClosedCandles(
        closed15m: subSlice15m,
        closed1h: slice1h,
        hasOpenPosition: openPositions.containsKey(symbol),
      );

      // Confirmed bearish EMA crossover exit is still executed to protect open positions
      if (eval.signalType == StrategySignalType.exitBearishCross &&
          openPositions.containsKey(symbol)) {
        closePosition(
          symbol: symbol,
          rawExitPrice: currentCandle.close,
          executedAtMs: currentCandle.closeTimeMs,
          reason: 'BEARISH_EMA_CROSSOVER',
          latestPrices: latestPrices,
        );
      } else if (eval.signalType == StrategySignalType.buySignal &&
          openPositions.isEmpty) {
        if (dailyLockedNow) {
          lastProcessedCandleCloseMs[symbol] = currentCandle.closeTimeMs;
          results.add(
            StrategyEvaluationResult(
              signalType: StrategySignalType.blockedByRisk,
              description: 'DAILY LOSS LIMIT REACHED',
              evaluatedCandleCloseMs: currentCandle.closeTimeMs,
              ema20_15m: eval.ema20_15m,
              ema50_15m: eval.ema50_15m,
              rsi14_15m: eval.rsi14_15m,
              atr14_15m: eval.atr14_15m,
              ema20_1h: eval.ema20_1h,
              ema50_1h: eval.ema50_1h,
              higherTimeframeBullish: eval.higherTimeframeBullish,
            ),
          );
          continue;
        }

        final signalKey = '$symbol-${currentCandle.closeTimeMs}';
        if (!processedEntrySignalKeys.contains(signalKey) &&
            eval.atr14_15m != null) {
          pendingSignalsBySymbol[symbol] = PendingEntrySignal(
            symbol: symbol,
            signalCandleCloseMs: currentCandle.closeTimeMs,
            atr14: eval.atr14_15m!,
            rsi14: eval.rsi14_15m ?? 55.0,
            ema20: eval.ema20_15m ?? 0.0,
            ema50: eval.ema50_15m ?? 0.0,
          );
        }
      }

      lastProcessedCandleCloseMs[symbol] =
          (currentCandle.openTimeMs + interval15mMs);
      results.add(eval);
    }

    return CandleStreamProcessOutcome(evaluations: results);
  }

  bool _tryExecutePendingBuyAtOpen({
    required PendingEntrySignal pending,
    required Candle executionCandle,
    required Map<String, double> latestPrices,
    required double minNotionalUsdt,
    required double minQuantity,
  }) {
    final signalKey = '${pending.symbol}-${pending.signalCandleCloseMs}';
    if (processedEntrySignalKeys.contains(signalKey)) {
      return false;
    }
    if (maxDrawdownLocked ||
        isDailyLockedAt(executionCandle.openTimeMs, latestPrices)) {
      return false;
    }

    ensureUtcDayBaseline(executionCandle.openTimeMs, latestPrices);

    final sizing = riskManager.evaluateEntryAndSize(
      rawNextOpenPrice: executionCandle.open,
      atr14: pending.atr14,
      strategyConfig: strategyConfig,
      availableCashUsdt: availableCashUsdt,
      currentEquityUsdt: accountEquity(latestPrices),
      startOfDayEquityUsdt: startOfDayEquityUsdt,
      todayRealizedPnlUsdt: todayRealizedPnl(executionCandle.openTimeMs),
      todayUnrealizedPnlUsdt: todayUnrealizedPnl(latestPrices),
      currentOpenPositionsCount: openPositions.length,
      minNotionalUsdt: minNotionalUsdt,
      minQuantity: minQuantity,
    );

    if (!sizing.approved) {
      return false;
    }

    final orderId = _nextId('ORD-BUY', executionCandle.openTimeMs);
    final posId = _nextId('POS', executionCandle.openTimeMs);

    final buyOrder = SimulatedOrder(
      id: orderId,
      symbol: pending.symbol,
      side: 'BUY',
      requestedPrice: executionCandle.open,
      executedPrice: sizing.executedEntryPrice,
      quantity: sizing.quantity,
      notionalUsdt: sizing.estimatedNotionalUsdt,
      feeUsdt: sizing.estimatedEntryFeeUsdt,
      signalCandleCloseMs: pending.signalCandleCloseMs,
      executedAtMs: executionCandle.openTimeMs,
      reason: 'SIGNAL_NEXT_OPEN_ENTRY',
    );

    final position = PaperPosition(
      id: posId,
      symbol: pending.symbol,
      entryPrice: sizing.executedEntryPrice,
      quantity: sizing.quantity,
      stopLoss: sizing.stopLossPrice,
      takeProfit: sizing.takeProfitPrice,
      entryFeeUsdt: sizing.estimatedEntryFeeUsdt,
      signalCandleCloseMs: pending.signalCandleCloseMs,
      openedAtMs: executionCandle.openTimeMs,
    );

    availableCashUsdt -=
        (sizing.estimatedNotionalUsdt + sizing.estimatedEntryFeeUsdt);
    openPositions[pending.symbol] = position;
    orderHistory.insert(0, buyOrder);
    processedEntrySignalKeys.add(signalKey);
    return true;
  }

  ClosedPaperTrade? closePosition({
    required String symbol,
    required double rawExitPrice,
    required int executedAtMs,
    required String reason,
    required Map<String, double> latestPrices,
  }) {
    final pos = openPositions.remove(symbol);
    if (pos == null) return null;

    final executedExitPrice = rawExitPrice * (1.0 - riskConfig.slippageRate);
    final grossProceeds = executedExitPrice * pos.quantity;
    final exitFee = grossProceeds * riskConfig.feeRate;
    final netProceeds = grossProceeds - exitFee;
    final pnl = netProceeds - pos.costBasisUsdt;

    availableCashUsdt += netProceeds;
    realizedPnlUsdt += pnl;

    ensureUtcDayBaseline(executedAtMs, latestPrices);
    final dayKey = RiskManager.utcDayKey(executedAtMs);
    dailyRealizedPnlByUtcDate[dayKey] =
        (dailyRealizedPnlByUtcDate[dayKey] ?? 0.0) + pnl;

    final sellOrder = SimulatedOrder(
      id: _nextId('ORD-SELL', executedAtMs),
      symbol: symbol,
      side: 'SELL',
      requestedPrice: rawExitPrice,
      executedPrice: executedExitPrice,
      quantity: pos.quantity,
      notionalUsdt: grossProceeds,
      feeUsdt: exitFee,
      signalCandleCloseMs: pos.signalCandleCloseMs,
      executedAtMs: executedAtMs,
      reason: reason,
    );
    orderHistory.insert(0, sellOrder);

    final closedTrade = ClosedPaperTrade(
      id: _nextId('TRD', executedAtMs),
      symbol: symbol,
      entryPrice: pos.entryPrice,
      exitPrice: executedExitPrice,
      quantity: pos.quantity,
      stopLoss: pos.stopLoss,
      takeProfit: pos.takeProfit,
      totalFeesUsdt: pos.entryFeeUsdt + exitFee,
      realizedPnlUsdt: pnl,
      openedAtMs: pos.openedAtMs,
      closedAtMs: executedAtMs,
      exitReason: reason,
    );
    closedTrades.insert(0, closedTrade);

    if (isDailyLockedAt(executedAtMs, latestPrices)) {
      lockedDailyLossUtcDate = dayKey;
    }
    if (riskManager.isMaxDrawdownReached(accountEquity(latestPrices))) {
      _triggerMaxDrawdownStop(executedAtMs, latestPrices);
    }

    return closedTrade;
  }

  /// Enforces $90 equity floor protection:
  /// - Blocks all new entries immediately (`maxDrawdownLocked = true`).
  /// - Clears pending entry signals.
  /// - Safely liquidates open simulated exposure using valid market data (`latestPrices`).
  /// - If valid market data is unavailable for an open position (`price == null || price <= 0`),
  ///   NEVER invents an execution price; keeps the account locked and sets
  ///   `pendingEmergencyLiquidation = true` until a valid market quote arrives.
  void enforceMaxDrawdownCheck(
    int timestampMs,
    Map<String, double> latestPrices,
  ) {
    if (riskManager.isMaxDrawdownReached(accountEquity(latestPrices))) {
      _triggerMaxDrawdownStop(timestampMs, latestPrices);
    }
  }

  void _triggerMaxDrawdownStop(
    int timestampMs,
    Map<String, double> latestPrices,
  ) {
    maxDrawdownLocked = true;
    pendingSignalsBySymbol.clear();
    final symbols = openPositions.keys.toList();
    bool anyUnliquidated = false;

    for (final sym in symbols) {
      final validMark = latestPrices[sym];
      if (validMark != null && validMark > 0 && validMark.isFinite) {
        closePosition(
          symbol: sym,
          rawExitPrice: validMark,
          executedAtMs: timestampMs,
          reason: 'MAX_DRAWDOWN_EMERGENCY_LIQUIDATION',
          latestPrices: latestPrices,
        );
      } else {
        anyUnliquidated = true;
      }
    }
    pendingEmergencyLiquidation = anyUnliquidated;
  }

  void manualResetPaperAccount() {
    availableCashUsdt = riskConfig.initialCapitalUsdt;
    startOfDayEquityUsdt = riskConfig.initialCapitalUsdt;
    currentUtcDateKey = '';
    realizedPnlUsdt = 0.0;
    openPositions.clear();
    closedTrades.clear();
    orderHistory.clear();
    dailyRealizedPnlByUtcDate.clear();
    dailyStartEquityByUtcDate.clear();
    lastProcessedCandleCloseMs.clear();
    processedEntrySignalKeys.clear();
    pendingSignalsBySymbol.clear();
    maxDrawdownLocked = false;
    pendingEmergencyLiquidation = false;
    lockedDailyLossUtcDate = null;
  }

  static BacktestReport runHistoricalBacktest({
    required String symbol,
    required List<Candle> candles15m,
    required List<Candle> candles1h,
    StrategyConfig strategyConfig = const StrategyConfig(),
    RiskConfig riskConfig = const RiskConfig(),
  }) {
    final broker = PaperBroker(
      strategyConfig: strategyConfig,
      riskConfig: riskConfig,
    );
    final latestPrices = <String, double>{};
    double peakEquity = riskConfig.initialCapitalUsdt;
    double maxDrawdown = 0.0;

    for (int i = 0; i < candles15m.length; i++) {
      final slice15m = candles15m.sublist(0, i + 1);
      final currentCloseMs = slice15m.last.closeTimeMs;
      final slice1h =
          candles1h.where((c) => c.closeTimeMs <= currentCloseMs).toList();

      broker.processClosedCandleStream(
        symbol: symbol,
        closed15m: slice15m,
        closed1h: slice1h,
        latestPrices: latestPrices,
        allowHistoricalWarmupTrades: true,
      );

      final eq = broker.accountEquity(latestPrices);
      if (eq > peakEquity) peakEquity = eq;
      final dd = peakEquity - eq;
      if (dd > maxDrawdown) maxDrawdown = dd;

      if (broker.maxDrawdownLocked) break;
    }

    final trades = broker.closedTrades.reversed.toList();
    final wins = trades.where((t) => t.realizedPnlUsdt > 0).toList();
    final losses = trades.where((t) => t.realizedPnlUsdt <= 0).toList();

    final grossProfit =
        wins.fold<double>(0.0, (sum, t) => sum + t.realizedPnlUsdt);
    final grossLossAbs =
        losses.fold<double>(0.0, (sum, t) => sum + t.realizedPnlUsdt.abs());
    final totalFees =
        trades.fold<double>(0.0, (sum, t) => sum + t.totalFeesUsdt);
    final avgR = trades.isEmpty
        ? 0.0
        : trades.fold<double>(0.0, (sum, t) => sum + t.realizedRMultiple) /
            trades.length;
    final avgDurationMs = trades.isEmpty
        ? 0
        : (trades.fold<int>(0, (sum, t) => sum + t.durationMs) ~/
            trades.length);

    final endingEquity = broker.accountEquity(latestPrices);

    return BacktestReport(
      totalTrades: trades.length,
      winningTrades: wins.length,
      losingTrades: losses.length,
      winRatePercent:
          trades.isEmpty ? 0.0 : (wins.length / trades.length) * 100.0,
      netPnlUsdt: endingEquity - riskConfig.initialCapitalUsdt,
      totalFeesUsdt: totalFees,
      profitFactor: grossLossAbs <= 1e-9
          ? (grossProfit > 0 ? 99.9 : 0.0)
          : grossProfit / grossLossAbs,
      maxDrawdownUsdt: maxDrawdown,
      averageRewardToRisk: avgR,
      averageTradeDuration: Duration(milliseconds: avgDurationMs),
      endingEquityUsdt: endingEquity,
    );
  }
}

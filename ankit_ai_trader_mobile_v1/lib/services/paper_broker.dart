import '../models/trading_models.dart';
import 'risk_manager.dart';
import 'strategy_engine.dart';

class PaperBroker {
  StrategyConfig strategyConfig;
  RiskConfig riskConfig;

  double availableCashUsdt;
  double realizedPnlUsdt;
  final Map<String, PaperPosition> openPositions = {};
  final List<ClosedPaperTrade> closedTrades = [];
  final List<SimulatedOrder> orderHistory = [];
  final Map<String, double> dailyRealizedPnlByUtcDate = {};
  final Map<String, int> lastProcessedCandleCloseMs = {};
  final Set<String> processedEntrySignalKeys = {};
  final Map<String, PendingEntrySignal> pendingSignalsBySymbol = {};

  bool maxDrawdownLocked = false;
  String? lockedDailyLossUtcDate;
  int _orderSeq = 0;

  PaperBroker({
    this.strategyConfig = const StrategyConfig(),
    this.riskConfig = const RiskConfig(),
    double? initialCashUsdt,
    this.realizedPnlUsdt = 0.0,
  }) : availableCashUsdt = initialCashUsdt ?? riskConfig.initialCapitalUsdt;

  RiskManager get riskManager => RiskManager(config: riskConfig);
  StrategyEngine get strategyEngine => StrategyEngine(config: strategyConfig);

  String _nextId(String prefix, int timestampMs) {
    _orderSeq += 1;
    return '$prefix-$timestampMs-$_orderSeq';
  }

  double unrealizedPnl(Map<String, double> latestPrices) {
    double sum = 0.0;
    for (final pos in openPositions.values) {
      final mark = latestPrices[pos.symbol] ?? pos.entryPrice;
      sum += pos.unrealizedPnl(mark, riskConfig.feeRate);
    }
    return sum;
  }

  double accountEquity(Map<String, double> latestPrices) {
    double openLiquidationValue = 0.0;
    for (final pos in openPositions.values) {
      final mark = latestPrices[pos.symbol] ?? pos.entryPrice;
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

  bool isDailyLockedAt(int nowEpochMs) {
    final todayKey = RiskManager.utcDayKey(nowEpochMs);
    if (lockedDailyLossUtcDate != null && lockedDailyLossUtcDate != todayKey) {
      lockedDailyLossUtcDate = null;
    }
    if (riskManager.isDailyLossLimitReached(todayRealizedPnl(nowEpochMs))) {
      lockedDailyLossUtcDate = todayKey;
      return true;
    }
    return lockedDailyLossUtcDate == todayKey;
  }

  /// Processes a newly closed 15m candle and 1h context for `symbol`.
  /// Avoids look-ahead bias:
  /// 1. Any pending entry signal from the PREVIOUS closed candle executes at THIS candle's open.
  /// 2. Stop-loss / take-profit are checked against THIS candle's range (stop-loss wins ties).
  /// 3. Indicator evaluation on THIS candle's close may schedule a pending entry for the NEXT candle open,
  ///    or trigger an immediate close on confirmed bearish crossover.
  StrategyEvaluationResult processClosedCandleStep({
    required String symbol,
    required List<Candle> closed15m,
    required List<Candle> closed1h,
    required Map<String, double> latestPrices,
    double minNotionalUsdt = 1.0,
    double minQuantity = 0.00001,
  }) {
    if (closed15m.isEmpty) {
      return const StrategyEvaluationResult(
        signalType: StrategySignalType.none,
        description: 'NO CLOSED 15M CANDLES',
        evaluatedCandleCloseMs: 0,
      );
    }

    final currentCandle = closed15m.last;
    latestPrices[symbol] = currentCandle.close;

    final lastProcessed = lastProcessedCandleCloseMs[symbol];
    if (lastProcessed != null && currentCandle.closeTimeMs <= lastProcessed) {
      return StrategyEvaluationResult(
        signalType: StrategySignalType.none,
        description: 'DUPLICATE CANDLE IGNORED',
        evaluatedCandleCloseMs: currentCandle.closeTimeMs,
      );
    }

    // Step 1: Execute pending entry signal scheduled on prior candle close at current candle OPEN
    final pending = pendingSignalsBySymbol.remove(symbol);
    if (pending != null &&
        pending.signalCandleCloseMs < currentCandle.openTimeMs + 1 &&
        !openPositions.containsKey(symbol)) {
      _tryExecutePendingBuyAtOpen(
        pending: pending,
        executionCandle: currentCandle,
        latestPrices: latestPrices,
        minNotionalUsdt: minNotionalUsdt,
        minQuantity: minQuantity,
      );
    }

    // Step 2: Check intrabar SL / TP on any open position for this symbol
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

    // Step 3: Check equity drawdown lock after intrabar execution
    if (riskManager.isMaxDrawdownReached(accountEquity(latestPrices))) {
      _triggerMaxDrawdownStop(currentCandle.closeTimeMs, latestPrices);
      lastProcessedCandleCloseMs[symbol] = currentCandle.closeTimeMs;
      return StrategyEvaluationResult(
        signalType: StrategySignalType.blockedByRisk,
        description: 'MAXIMUM DRAWDOWN REACHED',
        evaluatedCandleCloseMs: currentCandle.closeTimeMs,
      );
    }

    // Step 4: Evaluate indicators at current candle close
    final eval = strategyEngine.evaluateClosedCandles(
      closed15m: closed15m,
      closed1h: closed1h,
      hasOpenPosition: openPositions.containsKey(symbol),
    );

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
      if (isDailyLockedAt(currentCandle.closeTimeMs)) {
        lastProcessedCandleCloseMs[symbol] = currentCandle.closeTimeMs;
        return StrategyEvaluationResult(
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
        );
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

    lastProcessedCandleCloseMs[symbol] = currentCandle.closeTimeMs;
    return eval;
  }

  /// Executes a pending BUY signal at `executionCandle.open` (next available open price).
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
    if (maxDrawdownLocked || isDailyLockedAt(executionCandle.openTimeMs)) {
      return false;
    }

    final sizing = riskManager.evaluateEntryAndSize(
      rawNextOpenPrice: executionCandle.open,
      atr14: pending.atr14,
      strategyConfig: strategyConfig,
      availableCashUsdt: availableCashUsdt,
      currentEquityUsdt: accountEquity(latestPrices),
      todayRealizedPnlUsdt: todayRealizedPnl(executionCandle.openTimeMs),
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

    if (riskManager.isDailyLossLimitReached(todayRealizedPnl(executedAtMs))) {
      lockedDailyLossUtcDate = dayKey;
    }
    if (riskManager.isMaxDrawdownReached(accountEquity(latestPrices))) {
      _triggerMaxDrawdownStop(executedAtMs, latestPrices);
    }

    return closedTrade;
  }

  void _triggerMaxDrawdownStop(
    int timestampMs,
    Map<String, double> latestPrices,
  ) {
    maxDrawdownLocked = true;
    pendingSignalsBySymbol.clear();
    final symbols = openPositions.keys.toList();
    for (final sym in symbols) {
      final pos = openPositions[sym]!;
      final mark = latestPrices[sym] ?? pos.entryPrice;
      closePosition(
        symbol: sym,
        rawExitPrice: mark,
        executedAtMs: timestampMs,
        reason: 'MAX_DRAWDOWN_EMERGENCY_LIQUIDATION',
        latestPrices: latestPrices,
      );
    }
  }

  void manualResetPaperAccount() {
    availableCashUsdt = riskConfig.initialCapitalUsdt;
    realizedPnlUsdt = 0.0;
    openPositions.clear();
    closedTrades.clear();
    orderHistory.clear();
    dailyRealizedPnlByUtcDate.clear();
    lastProcessedCandleCloseMs.clear();
    processedEntrySignalKeys.clear();
    pendingSignalsBySymbol.clear();
    maxDrawdownLocked = false;
    lockedDailyLossUtcDate = null;
  }

  /// Runs a deterministic historical backtest over chronological 15m and 1h candles
  /// using the exact same strategy, paper broker, fees, slippage, and risk manager.
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

      broker.processClosedCandleStep(
        symbol: symbol,
        closed15m: slice15m,
        closed1h: slice1h,
        latestPrices: latestPrices,
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
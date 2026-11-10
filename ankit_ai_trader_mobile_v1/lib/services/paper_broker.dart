import '../models/trading_models.dart';
import 'risk_manager.dart';
import 'strategy_engine.dart';

class CandleStreamOutcome {
  final bool blockedByRisk;
  final BotEngineState? triggeredSafetyState;
  final String? safetyMessage;
  final List<SimulatedOrder> newOrders;
  final List<ClosedPaperTrade> newClosedTrades;
  final String? whyNoTradeReason;

  const CandleStreamOutcome({
    this.blockedByRisk = false,
    this.triggeredSafetyState,
    this.safetyMessage,
    this.newOrders = const [],
    this.newClosedTrades = const [],
    this.whyNoTradeReason,
  });
}

class PaperBroker {
  final RiskManager riskManager;
  final double feeRate;
  final double slippageRate;

  double availableCashUsdt;
  bool maxDrawdownLocked;
  String? lockedDailyLossUtcDate;
  int? lastStopLossClosedAtMs;

  final List<PaperPosition> openPositions = [];
  final List<SimulatedOrder> orders = [];
  final List<ClosedPaperTrade> closedTrades = [];
  final Map<String, PendingEntrySignal> pendingSignalsBySymbol = {};
  final Set<String> processedEntrySignalKeys = {};
  final Map<String, double> dailyStartEquityByUtcDate = {};
  final Map<String, int> lastProcessedCandleCloseMs = {};

  PaperBroker({
    this.riskManager = const RiskManager(),
    this.feeRate = 0.001,
    this.slippageRate = 0.0005,
    double? initialCashUsdt,
    this.maxDrawdownLocked = false,
    this.lockedDailyLossUtcDate,
    this.lastStopLossClosedAtMs,
  }) : availableCashUsdt =
            initialCashUsdt ?? riskManager.config.initialCapitalUsdt;

  double accountEquityUsdt(Map<String, double> markPrices) {
    double unrealizedVal = 0.0;
    for (final pos in openPositions) {
      final mark = markPrices[pos.symbol] ?? pos.entryPrice;
      final gross = mark * pos.quantity;
      final exitFee = gross * feeRate;
      unrealizedVal += (gross - exitFee);
    }
    return availableCashUsdt + unrealizedVal;
  }

  double startOfDayEquityUsdt(int nowMs, Map<String, double> markPrices) {
    final utcDay = RiskManager.utcDateString(nowMs);
    return dailyStartEquityByUtcDate.putIfAbsent(
      utcDay,
      () => accountEquityUsdt(markPrices),
    );
  }

  bool isDailyLockedAt(int nowMs) {
    final utcDay = RiskManager.utcDateString(nowMs);
    return lockedDailyLossUtcDate == utcDay;
  }

  bool enforceMaxDrawdownCheck(Map<String, double> markPrices) {
    final eq = accountEquityUsdt(markPrices);
    if (riskManager.isMaxDrawdownReached(eq)) {
      maxDrawdownLocked = true;
      return true;
    }
    return maxDrawdownLocked;
  }

  void manualResetPaperAccount() {
    availableCashUsdt = riskManager.config.initialCapitalUsdt;
    maxDrawdownLocked = false;
    lockedDailyLossUtcDate = null;
    lastStopLossClosedAtMs = null;
    openPositions.clear();
    orders.clear();
    closedTrades.clear();
    pendingSignalsBySymbol.clear();
    processedEntrySignalKeys.clear();
    dailyStartEquityByUtcDate.clear();
    lastProcessedCandleCloseMs.clear();
  }

  ClosedPaperTrade _closePositionInternal({
    required PaperPosition position,
    required double triggerPrice,
    required int closedAtMs,
    required String exitReason,
    required List<SimulatedOrder> newOrdersOut,
  }) {
    final executedExitPrice = triggerPrice * (1.0 - slippageRate);
    final exitNotional = executedExitPrice * position.quantity;
    final exitFee = exitNotional * feeRate;
    final netProceeds = exitNotional - exitFee;
    availableCashUsdt += netProceeds;

    final totalFees = position.entryFeeUsdt + exitFee;
    final realizedPnl =
        (exitNotional - position.investedNotionalUsdt) - totalFees;

    final sellOrder = SimulatedOrder(
      id: 'ORD_SELL_${position.symbol}_$closedAtMs',
      symbol: position.symbol,
      side: 'SELL',
      requestedPrice: triggerPrice,
      executedPrice: executedExitPrice,
      quantity: position.quantity,
      notionalUsdt: exitNotional,
      feeUsdt: exitFee,
      signalCandleCloseMs: position.signalCandleCloseMs,
      executedAtMs: closedAtMs,
      reason: exitReason,
    );
    orders.insert(0, sellOrder);
    newOrdersOut.add(sellOrder);

    final closedTrade = ClosedPaperTrade(
      id: 'TRD_${position.id}_$closedAtMs',
      symbol: position.symbol,
      entryPrice: position.entryPrice,
      exitPrice: executedExitPrice,
      quantity: position.quantity,
      stopLoss: position.stopLoss,
      takeProfit: position.takeProfit,
      totalFeesUsdt: totalFees,
      realizedPnlUsdt: realizedPnl,
      openedAtMs: position.openedAtMs,
      closedAtMs: closedAtMs,
      exitReason: exitReason,
    );
    closedTrades.insert(0, closedTrade);
    openPositions.removeWhere((p) => p.id == position.id);

    if (exitReason.startsWith('STOP_LOSS')) {
      lastStopLossClosedAtMs = closedAtMs;
    }
    return closedTrade;
  }

  List<ClosedPaperTrade> checkStopLossOrTakeProfit({
    required String symbol,
    required Candle candle,
    required List<SimulatedOrder> newOrdersOut,
  }) {
    final matching = openPositions.where((p) => p.symbol == symbol).toList();
    if (matching.isEmpty) return const [];

    final closedNow = <ClosedPaperTrade>[];
    for (final pos in matching) {
      final hitSl = candle.low <= pos.stopLoss;
      final hitTp = candle.high >= pos.takeProfit;
      if (hitSl && hitTp) {
        closedNow.add(_closePositionInternal(
          position: pos,
          triggerPrice: pos.stopLoss,
          closedAtMs: candle.closeTimeMs,
          exitReason: 'STOP_LOSS_CONSERVATIVE_BOTH_TOUCHED',
          newOrdersOut: newOrdersOut,
        ));
      } else if (hitSl) {
        closedNow.add(_closePositionInternal(
          position: pos,
          triggerPrice: pos.stopLoss,
          closedAtMs: candle.closeTimeMs,
          exitReason: 'STOP_LOSS',
          newOrdersOut: newOrdersOut,
        ));
      } else if (hitTp) {
        closedNow.add(_closePositionInternal(
          position: pos,
          triggerPrice: pos.takeProfit,
          closedAtMs: candle.closeTimeMs,
          exitReason: 'TAKE_PROFIT',
          newOrdersOut: newOrdersOut,
        ));
      }
    }
    return closedNow;
  }

  CandleStreamOutcome processClosedCandleStream({
    required String symbol,
    required List<Candle> closedCandles15m,
    required List<Candle> closedCandles1h,
    required StrategyEngine strategyEngine,
    required MarketPairMetadata pairMetadata,
    required Map<String, double> currentMarkPrices,
    LiveMarketTicker? liveTicker,
    bool allowNewEntries = true,
  }) {
    if (closedCandles15m.isEmpty) {
      return const CandleStreamOutcome(
        whyNoTradeReason: 'Why no trade: Stale data',
      );
    }

    final latestCandle = closedCandles15m.last;
    final marks = Map<String, double>.from(currentMarkPrices);
    marks[symbol] = liveTicker?.lastPrice ?? latestCandle.close;

    final newOrders = <SimulatedOrder>[];
    final newClosed = <ClosedPaperTrade>[];

    // 1. Always evaluate SL/TP exits on the newly closed candle first
    final slTpClosed = checkStopLossOrTakeProfit(
      symbol: symbol,
      candle: latestCandle,
      newOrdersOut: newOrders,
    );
    newClosed.addAll(slTpClosed);

    // 2. Re-evaluate equity & safety locks after any exits
    final equityNow = accountEquityUsdt(marks);
    if (enforceMaxDrawdownCheck(marks)) {
      return CandleStreamOutcome(
        blockedByRisk: true,
        triggeredSafetyState: BotEngineState.stoppedMaxDrawdownReached,
        safetyMessage:
            'Account equity reached or fell below \$90.00 floor. Engine stopped; manual review & reset required.',
        newOrders: newOrders,
        newClosedTrades: newClosed,
        whyNoTradeReason: 'Why no trade: Locked/paused (Max Drawdown)',
      );
    }

    final sodEquity = startOfDayEquityUsdt(latestCandle.closeTimeMs, marks);
    if (isDailyLockedAt(latestCandle.closeTimeMs) ||
        riskManager.isDailyLossLimitReached(
          startOfDayEquityUsdt: sodEquity,
          currentEquityUsdt: equityNow,
        )) {
      lockedDailyLossUtcDate =
          RiskManager.utcDateString(latestCandle.closeTimeMs);
      return CandleStreamOutcome(
        blockedByRisk: true,
        triggeredSafetyState: BotEngineState.lockedDailyLossLimit,
        safetyMessage: 'DAILY LOSS LIMIT (\$2.00) REACHED',
        newOrders: newOrders,
        newClosedTrades: newClosed,
        whyNoTradeReason: 'Why no trade: Locked/paused (Daily Loss Limit)',
      );
    }

    // 3. Evaluate strategy on closed candles
    final eval = strategyEngine.evaluateClosedCandles(
      symbol: symbol,
      closedCandles15m: closedCandles15m,
      closedCandles1h: closedCandles1h,
    );

    // 4. If bearish crossover occurs while holding a position, close at market
    if (eval.signal == StrategySignalType.sell) {
      final openForSym =
          openPositions.where((p) => p.symbol == symbol).toList();
      for (final pos in openForSym) {
        newClosed.add(_closePositionInternal(
          position: pos,
          triggerPrice: liveTicker?.bid ?? latestCandle.close,
          closedAtMs: latestCandle.closeTimeMs,
          exitReason: 'BEARISH_EMA_CROSS_EXIT',
          newOrdersOut: newOrders,
        ));
      }
    }

    lastProcessedCandleCloseMs[symbol] = latestCandle.closeTimeMs;

    if (!allowNewEntries) {
      return CandleStreamOutcome(
        newOrders: newOrders,
        newClosedTrades: newClosed,
        whyNoTradeReason: eval.reason,
      );
    }

    if (eval.signal == StrategySignalType.buy) {
      final signalKey = '${symbol}_${eval.evaluatedCandleCloseMs}';
      if (processedEntrySignalKeys.contains(signalKey)) {
        return CandleStreamOutcome(
          newOrders: newOrders,
          newClosedTrades: newClosed,
          whyNoTradeReason:
              'Why no trade: Duplicate candle signal already processed ($signalKey)',
        );
      }

      // Use live ask price if fresh, otherwise closed candle price, plus slippage
      final baseAsk = (liveTicker != null &&
              liveTicker.ask > 0 &&
              (latestCandle.closeTimeMs - liveTicker.timestampMs).abs() <=
                  15 * 60 * 1000)
          ? liveTicker.ask
          : latestCandle.close;
      final executedBuyPrice = baseAsk * (1.0 + slippageRate);

      final sizing = riskManager.evaluateEntrySizing(
        symbol: symbol,
        entryFillPrice: executedBuyPrice,
        atr14: eval.atr14_15m,
        currentEquityUsdt: accountEquityUsdt(marks),
        availableCashUsdt: availableCashUsdt,
        startOfDayEquityUsdt: sodEquity,
        openPositions: openPositions,
        pairMetadata: pairMetadata,
        feeRate: feeRate,
        lastStopLossClosedAtMs: lastStopLossClosedAtMs,
        nowMs: latestCandle.closeTimeMs,
      );

      if (!sizing.approved) {
        return CandleStreamOutcome(
          newOrders: newOrders,
          newClosedTrades: newClosed,
          whyNoTradeReason:
              sizing.rejectionReason ?? 'Why no trade: Risk rejected',
        );
      }

      final entryFee = sizing.notionalUsdt * feeRate;
      final totalDebit = sizing.notionalUsdt + entryFee;
      availableCashUsdt -= totalDebit;
      processedEntrySignalKeys.add(signalKey);

      final buyOrder = SimulatedOrder(
        id: 'ORD_BUY_${symbol}_${latestCandle.closeTimeMs}',
        symbol: symbol,
        side: 'BUY',
        requestedPrice: baseAsk,
        executedPrice: executedBuyPrice,
        quantity: sizing.quantity,
        notionalUsdt: sizing.notionalUsdt,
        feeUsdt: entryFee,
        signalCandleCloseMs: eval.evaluatedCandleCloseMs,
        executedAtMs: latestCandle.closeTimeMs,
        reason: eval.reason,
      );
      orders.insert(0, buyOrder);
      newOrders.add(buyOrder);

      final newPos = PaperPosition(
        id: 'POS_${symbol}_${latestCandle.closeTimeMs}',
        symbol: symbol,
        entryPrice: executedBuyPrice,
        quantity: sizing.quantity,
        stopLoss: sizing.stopLossPrice,
        takeProfit: sizing.takeProfitPrice,
        entryFeeUsdt: entryFee,
        signalCandleCloseMs: eval.evaluatedCandleCloseMs,
        openedAtMs: latestCandle.closeTimeMs,
      );
      openPositions.add(newPos);

      return CandleStreamOutcome(
        newOrders: newOrders,
        newClosedTrades: newClosed,
        whyNoTradeReason: eval.reason,
      );
    }

    return CandleStreamOutcome(
      newOrders: newOrders,
      newClosedTrades: newClosed,
      whyNoTradeReason: eval.reason,
    );
  }

  static BacktestReport runHistoricalBacktest({
    required String symbol,
    required List<Candle> candles15m,
    required List<Candle> candles1h,
    MarketPairMetadata? pairMetadata,
  }) {
    final broker = PaperBroker();
    const strategy = StrategyEngine();
    final meta = pairMetadata ??
        MarketPairMetadata(
          symbol: symbol,
          baseCurrency: symbol.contains('BTC') ? 'BTC' : 'ETH',
          quoteCurrency: 'USDT',
        );

    double peakEquity = broker.availableCashUsdt;
    double maxDrawdown = 0.0;

    for (int i = 55; i < candles15m.length; i++) {
      final slice15m = candles15m.sublist(0, i + 1);
      final curCloseMs = slice15m.last.closeTimeMs;
      final slice1h =
          candles1h.where((c) => c.closeTimeMs <= curCloseMs).toList();
      if (slice1h.length < 52) continue;

      broker.processClosedCandleStream(
        symbol: symbol,
        closedCandles15m: slice15m,
        closedCandles1h: slice1h,
        strategyEngine: strategy,
        pairMetadata: meta,
        currentMarkPrices: {symbol: slice15m.last.close},
      );

      final eq = broker.accountEquityUsdt({symbol: slice15m.last.close});
      if (eq > peakEquity) peakEquity = eq;
      final dd = peakEquity - eq;
      if (dd > maxDrawdown) maxDrawdown = dd;
    }

    final lastPrice = candles15m.isNotEmpty ? candles15m.last.close : 0.0;
    final endingEq = broker.accountEquityUsdt({symbol: lastPrice});
    final total = broker.closedTrades.length;
    final wins =
        broker.closedTrades.where((t) => t.realizedPnlUsdt > 0).length;
    final losses = total - wins;
    final winRate = total > 0 ? (wins / total) * 100.0 : 0.0;

    return BacktestReport(
      symbol: symbol,
      totalCandlesEvaluated: candles15m.length,
      totalTrades: total,
      winningTrades: wins,
      losingTrades: losses,
      winRatePct: winRate,
      netPnlUsdt: endingEq - broker.riskManager.config.initialCapitalUsdt,
      endingEquityUsdt: endingEq,
      maxDrawdownUsdt: maxDrawdown,
    );
  }
}

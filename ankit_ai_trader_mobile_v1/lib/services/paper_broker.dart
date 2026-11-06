import 'dart:math' as math;
import '../models/trading_models.dart';
import 'risk_manager.dart';
import 'strategy_engine.dart';

class CandleStreamOutcome {
  final List<StrategyEvaluationResult> evaluations;
  final bool pausedOnMissingNextCandle;
  final String pauseReason;

  const CandleStreamOutcome({
    required this.evaluations,
    this.pausedOnMissingNextCandle = false,
    this.pauseReason = '',
  });
}

class PaperBroker {
  StrategyConfig strategyConfig;
  RiskConfig riskConfig;

  late double availableCashUsdt;
  double realizedPnlUsdt = 0.0;
  String currentUtcDateKey = '';
  late double startOfDayEquityUsdt;
  final Map<String, double> dailyStartEquityByUtcDate = {};
  final Map<String, double> dailyRealizedPnlByUtcDate = {};

  bool maxDrawdownLocked = false;
  bool pendingEmergencyLiquidation = false;
  String? lockedDailyLossUtcDate;

  final Map<String, PaperPosition> openPositions = {};
  final List<ClosedPaperTrade> closedTrades = [];
  final List<SimulatedOrder> orderHistory = [];
  final Map<String, int> lastProcessedCandleCloseMs = {};
  final Set<String> processedEntrySignalKeys = {};
  final Map<String, PendingEntrySignal> pendingSignalsBySymbol = {};

  PaperBroker({
    this.strategyConfig = const StrategyConfig(),
    this.riskConfig = const RiskConfig(),
  }) {
    availableCashUsdt = riskConfig.initialCapitalUsdt;
    startOfDayEquityUsdt = riskConfig.initialCapitalUsdt;
  }

  RiskManager get riskManager => RiskManager(config: riskConfig);
  StrategyEngine get strategyEngine => StrategyEngine(config: strategyConfig);

  void manualResetPaperAccount() {
    availableCashUsdt = riskConfig.initialCapitalUsdt;
    realizedPnlUsdt = 0.0;
    currentUtcDateKey = '';
    startOfDayEquityUsdt = riskConfig.initialCapitalUsdt;
    dailyStartEquityByUtcDate.clear();
    dailyRealizedPnlByUtcDate.clear();
    maxDrawdownLocked = false;
    pendingEmergencyLiquidation = false;
    lockedDailyLossUtcDate = null;
    openPositions.clear();
    closedTrades.clear();
    orderHistory.clear();
    lastProcessedCandleCloseMs.clear();
    processedEntrySignalKeys.clear();
    pendingSignalsBySymbol.clear();
  }

  double unrealizedPnl(Map<String, double> latestPrices) {
    double total = 0.0;
    for (final pos in openPositions.values) {
      final rawMark = latestPrices[pos.symbol];
      final mark = (rawMark != null && rawMark > 0) ? rawMark : pos.entryPrice;
      final exitExec = mark * (1.0 - riskConfig.slippageRate);
      final grossProceeds = exitExec * pos.quantity;
      final exitFee = grossProceeds * riskConfig.feeRate;
      final costBasis = pos.entryPrice * pos.quantity;
      total += (grossProceeds - exitFee - costBasis);
    }
    return total;
  }

  double accountEquity(Map<String, double> latestPrices) {
    double openValueAfterExitFee = 0.0;
    for (final pos in openPositions.values) {
      final rawMark = latestPrices[pos.symbol];
      final mark = (rawMark != null && rawMark > 0) ? rawMark : pos.entryPrice;
      final exitExec = mark * (1.0 - riskConfig.slippageRate);
      final grossProceeds = exitExec * pos.quantity;
      final exitFee = grossProceeds * riskConfig.feeRate;
      openValueAfterExitFee += (grossProceeds - exitFee);
    }
    return availableCashUsdt + openValueAfterExitFee;
  }

  double currentDrawdownUsdt(Map<String, double> latestPrices) {
    final eq = accountEquity(latestPrices);
    return math.max(0.0, riskConfig.initialCapitalUsdt - eq);
  }

  void ensureUtcDayBaseline(int nowMs, Map<String, double> latestPrices) {
    final dayKey = RiskManager.utcDayKey(nowMs);
    if (currentUtcDateKey != dayKey) {
      currentUtcDateKey = dayKey;
      final eq = accountEquity(latestPrices);
      final base = dailyStartEquityByUtcDate[dayKey] ?? eq;
      dailyStartEquityByUtcDate[dayKey] = base;
      startOfDayEquityUsdt = base;
      dailyRealizedPnlByUtcDate.putIfAbsent(dayKey, () => 0.0);
      if (lockedDailyLossUtcDate != null && lockedDailyLossUtcDate != dayKey) {
        lockedDailyLossUtcDate = null;
      }
    }
  }

  double currentUtcDayTotalPnl(int nowMs, Map<String, double> latestPrices) {
    ensureUtcDayBaseline(nowMs, latestPrices);
    return accountEquity(latestPrices) - startOfDayEquityUsdt;
  }

  bool isDailyLockedAt(int nowMs, Map<String, double> latestPrices) {
    ensureUtcDayBaseline(nowMs, latestPrices);
    final dayKey = currentUtcDateKey;
    if (lockedDailyLossUtcDate == dayKey) {
      return true;
    }
    final eq = accountEquity(latestPrices);
    if (riskManager.isDailyLossLimitReached(
      currentEquityUsdt: eq,
      startOfDayEquityUsdt: startOfDayEquityUsdt,
    )) {
      lockedDailyLossUtcDate = dayKey;
      return true;
    }
    return false;
  }

  void enforceMaxDrawdownCheck(int nowMs, Map<String, double> latestPrices) {
    final eq = accountEquity(latestPrices);
    if (!maxDrawdownLocked && !riskManager.isMaxDrawdownReached(eq)) {
      return;
    }
    maxDrawdownLocked = true;
    pendingSignalsBySymbol.clear();

    if (openPositions.isEmpty) {
      pendingEmergencyLiquidation = false;
      return;
    }

    final symbols = openPositions.keys.toList();
    bool anyMissingQuote = false;
    for (final sym in symbols) {
      final quote = latestPrices[sym];
      if (quote != null && quote > 0) {
        final pos = openPositions[sym]!;
        _closePositionInternal(
          position: pos,
          rawExitReferencePrice: quote,
          closedAtMs: nowMs,
          signalCandleCloseMs: pos.signalCandleCloseMs,
          exitReason: 'MAX_DRAWDOWN_EMERGENCY_LIQUIDATION',
        );
      } else {
        anyMissingQuote = true;
      }
    }
    pendingEmergencyLiquidation = anyMissingQuote;
  }

  void _closePositionInternal({
    required PaperPosition position,
    required double rawExitReferencePrice,
    required int closedAtMs,
    required int signalCandleCloseMs,
    required String exitReason,
  }) {
    final exitExecPrice =
        rawExitReferencePrice * (1.0 - riskConfig.slippageRate);
    final grossProceeds = exitExecPrice * position.quantity;
    final exitFeeUsdt = grossProceeds * riskConfig.feeRate;
    final netProceeds = grossProceeds - exitFeeUsdt;

    final costBasis = position.entryPrice * position.quantity;
    final totalFees = position.entryFeeUsdt + exitFeeUsdt;
    final netPnl = netProceeds - costBasis - position.entryFeeUsdt;

    availableCashUsdt += netProceeds;
    realizedPnlUsdt += netPnl;

    final dayKey = RiskManager.utcDayKey(closedAtMs);
    dailyRealizedPnlByUtcDate[dayKey] =
        (dailyRealizedPnlByUtcDate[dayKey] ?? 0.0) + netPnl;

    openPositions.remove(position.symbol);

    final orderId = 'ORD-SELL-${position.symbol}-$closedAtMs';
    orderHistory.insert(
      0,
      SimulatedOrder(
        id: orderId,
        symbol: position.symbol,
        side: 'SELL',
        requestedPrice: rawExitReferencePrice,
        executedPrice: exitExecPrice,
        quantity: position.quantity,
        notionalUsdt: grossProceeds,
        feeUsdt: exitFeeUsdt,
        signalCandleCloseMs: signalCandleCloseMs,
        executedAtMs: closedAtMs,
        reason: exitReason,
      ),
    );

    closedTrades.insert(
      0,
      ClosedPaperTrade(
        id: 'TRD-${position.symbol}-$closedAtMs',
        symbol: position.symbol,
        entryPrice: position.entryPrice,
        exitPrice: exitExecPrice,
        quantity: position.quantity,
        stopLoss: position.stopLoss,
        takeProfit: position.takeProfit,
        totalFeesUsdt: totalFees,
        realizedPnlUsdt: netPnl,
        openedAtMs: position.openedAtMs,
        closedAtMs: closedAtMs,
        exitReason: exitReason,
      ),
    );
  }

  CandleStreamOutcome processClosedCandleStream({
    required String symbol,
    required List<Candle> closed15m,
    required List<Candle> closed1h,
    required Map<String, double> latestPrices,
    double minNotionalUsdt = 1.0,
    double minQuantity = 0.000001,
    bool allowHistoricalWarmupTrades = false,
  }) {
    if (closed15m.isEmpty) {
      return const CandleStreamOutcome(evaluations: []);
    }

    final evaluations = <StrategyEvaluationResult>[];
    final lastCheckpointMs = lastProcessedCandleCloseMs[symbol];

    // Fresh account historical warm-up: establish checkpoint on latest bar without historical trades
    if (lastCheckpointMs == null && !allowHistoricalWarmupTrades) {
      final latestCandle = closed15m.last;
      lastProcessedCandleCloseMs[symbol] = latestCandle.closeTimeMs;
      final eval = strategyEngine.evaluateClosedCandles(
        closed15m: closed15m,
        closed1h: closed1h,
        hasOpenPosition: openPositions.containsKey(symbol),
      );
      evaluations.add(
        StrategyEvaluationResult(
          signalType: StrategySignalType.none,
          description: 'WARM-UP COMPLETE — ${eval.description}',
          evaluatedCandleCloseMs: latestCandle.closeTimeMs,
          ema20_15m: eval.ema20_15m,
          ema50_15m: eval.ema50_15m,
          rsi14_15m: eval.rsi14_15m,
          atr14_15m: eval.atr14_15m,
          ema20_1h: eval.ema20_1h,
          ema50_1h: eval.ema50_1h,
          higherTimeframeBullish: eval.higherTimeframeBullish,
        ),
      );
      return CandleStreamOutcome(evaluations: evaluations);
    }

    final newIndices = <int>[];
    for (int i = 0; i < closed15m.length; i++) {
      if (lastCheckpointMs == null ||
          closed15m[i].closeTimeMs > lastCheckpointMs) {
        newIndices.add(i);
      }
    }

    if (newIndices.isEmpty) {
      final eval = strategyEngine.evaluateClosedCandles(
        closed15m: closed15m,
        closed1h: closed1h,
        hasOpenPosition: openPositions.containsKey(symbol),
      );
      evaluations.add(
        StrategyEvaluationResult(
          signalType: StrategySignalType.none,
          description: 'NO NEW CLOSED 15M CANDLES',
          evaluatedCandleCloseMs: closed15m.last.closeTimeMs,
          ema20_15m: eval.ema20_15m,
          ema50_15m: eval.ema50_15m,
          rsi14_15m: eval.rsi14_15m,
          atr14_15m: eval.atr14_15m,
          ema20_1h: eval.ema20_1h,
          ema50_1h: eval.ema50_1h,
          higherTimeframeBullish: eval.higherTimeframeBullish,
        ),
      );
      return CandleStreamOutcome(evaluations: evaluations);
    }

    for (final idx in newIndices) {
      final candle = closed15m[idx];
      final priceMap = <String, double>{
        ...latestPrices,
        symbol: candle.close,
      };
      ensureUtcDayBaseline(candle.closeTimeMs, priceMap);

      // 1) Check pending entry signal from previous candle C (must execute at open of C+1)
      final pending = pendingSignalsBySymbol[symbol];
      if (pending != null) {
        if (candle.openTimeMs == pending.signalCandleCloseMs) {
          pendingSignalsBySymbol.remove(symbol);
          final sigKey = '$symbol:${pending.signalCandleCloseMs}';
          if (!processedEntrySignalKeys.contains(sigKey) &&
              !maxDrawdownLocked &&
              !isDailyLockedAt(candle.openTimeMs, priceMap)) {
            final sizing = riskManager.evaluateEntryAndSize(
              rawNextOpenPrice: candle.open,
              atr14: pending.atr14,
              strategyConfig: strategyConfig,
              availableCashUsdt: availableCashUsdt,
              currentEquityUsdt: accountEquity(priceMap),
              startOfDayEquityUsdt: startOfDayEquityUsdt,
              todayRealizedPnlUsdt:
                  dailyRealizedPnlByUtcDate[currentUtcDateKey] ?? 0.0,
              todayUnrealizedPnlUsdt: unrealizedPnl(priceMap),
              currentOpenPositionsCount: openPositions.length,
              minNotionalUsdt: minNotionalUsdt,
              minQuantity: minQuantity,
            );
            if (sizing.approved) {
              processedEntrySignalKeys.add(sigKey);
              availableCashUsdt -=
                  (sizing.estimatedNotionalUsdt + sizing.estimatedEntryFeeUsdt);
              final posId = 'POS-$symbol-${candle.openTimeMs}';
              openPositions[symbol] = PaperPosition(
                id: posId,
                symbol: symbol,
                entryPrice: sizing.estimatedEntryPrice,
                quantity: sizing.quantity,
                stopLoss: sizing.stopLossPrice,
                takeProfit: sizing.takeProfitPrice,
                entryFeeUsdt: sizing.estimatedEntryFeeUsdt,
                signalCandleCloseMs: pending.signalCandleCloseMs,
                openedAtMs: candle.openTimeMs,
              );
              orderHistory.insert(
                0,
                SimulatedOrder(
                  id: 'ORD-BUY-$symbol-${candle.openTimeMs}',
                  symbol: symbol,
                  side: 'BUY',
                  requestedPrice: candle.open,
                  executedPrice: sizing.estimatedEntryPrice,
                  quantity: sizing.quantity,
                  notionalUsdt: sizing.estimatedNotionalUsdt,
                  feeUsdt: sizing.estimatedEntryFeeUsdt,
                  signalCandleCloseMs: pending.signalCandleCloseMs,
                  executedAtMs: candle.openTimeMs,
                  reason: 'SIGNAL_NEXT_OPEN_ENTRY',
                ),
              );
            }
          }
        } else if (candle.openTimeMs > pending.signalCandleCloseMs) {
          // Missing C+1 candle: discard stale signal and pause safely
          pendingSignalsBySymbol.remove(symbol);
          lastProcessedCandleCloseMs[symbol] = candle.closeTimeMs;
          return CandleStreamOutcome(
            evaluations: evaluations,
            pausedOnMissingNextCandle: true,
            pauseReason:
                'MISSING NEXT CANDLE C+1 FOR $symbol PENDING SIGNAL (${pending.signalCandleCloseMs})',
          );
        }
      }

      // 2) Manage open position SL/TP on current closed candle
      final openPos = openPositions[symbol];
      if (openPos != null) {
        final exitDec = strategyEngine.checkStopLossOrTakeProfit(
          position: openPos,
          candle: candle,
        );
        if (exitDec.shouldExit) {
          _closePositionInternal(
            position: openPos,
            rawExitReferencePrice: exitDec.exitReferencePrice,
            closedAtMs: candle.closeTimeMs,
            signalCandleCloseMs: openPos.signalCandleCloseMs,
            exitReason: exitDec.reason,
          );
        }
      }

      // 3) Enforce max drawdown & daily loss check
      enforceMaxDrawdownCheck(candle.closeTimeMs, priceMap);
      final dailyLocked = isDailyLockedAt(candle.closeTimeMs, priceMap);

      // 4) Evaluate strategy on prefix up to idx
      final prefix15m = closed15m.sublist(0, idx + 1);
      final eval = strategyEngine.evaluateClosedCandles(
        closed15m: prefix15m,
        closed1h: closed1h,
        hasOpenPosition: openPositions.containsKey(symbol),
      );
      evaluations.add(eval);

      if (eval.signalType == StrategySignalType.buyEntry &&
          !maxDrawdownLocked &&
          !dailyLocked &&
          !openPositions.containsKey(symbol) &&
          openPositions.length < riskConfig.maxConcurrentOpenPositions) {
        final sigKey = '$symbol:${candle.closeTimeMs}';
        if (!processedEntrySignalKeys.contains(sigKey) &&
            eval.atr14_15m != null &&
            eval.rsi14_15m != null &&
            eval.ema20_15m != null &&
            eval.ema50_15m != null) {
          pendingSignalsBySymbol[symbol] = PendingEntrySignal(
            symbol: symbol,
            signalCandleCloseMs: candle.closeTimeMs,
            atr14: eval.atr14_15m!,
            rsi14: eval.rsi14_15m!,
            ema20: eval.ema20_15m!,
            ema50: eval.ema50_15m!,
          );
        }
      }

      lastProcessedCandleCloseMs[symbol] = candle.closeTimeMs;
    }

    return CandleStreamOutcome(evaluations: evaluations);
  }

  static BacktestReport runHistoricalBacktest({
    required String symbol,
    required List<Candle> candles15m,
    required List<Candle> candles1h,
    StrategyConfig strategyConfig = const StrategyConfig(),
    RiskConfig riskConfig = const RiskConfig(),
  }) {
    final simBroker = PaperBroker(
      strategyConfig: strategyConfig,
      riskConfig: riskConfig,
    );
    simBroker.processClosedCandleStream(
      symbol: symbol,
      closed15m: candles15m,
      closed1h: candles1h,
      latestPrices: {},
      allowHistoricalWarmupTrades: true,
    );

    final trades = simBroker.closedTrades.reversed.toList();
    final total = trades.length;
    int wins = 0;
    int losses = 0;
    double grossProfit = 0.0;
    double grossLoss = 0.0;
    double sumRR = 0.0;

    double runningEq = riskConfig.initialCapitalUsdt;
    double peakEq = runningEq;
    double maxDd = 0.0;

    for (final t in trades) {
      runningEq += t.realizedPnlUsdt;
      if (runningEq > peakEq) peakEq = runningEq;
      final dd = peakEq - runningEq;
      if (dd > maxDd) maxDd = dd;

      if (t.realizedPnlUsdt >= 0) {
        wins++;
        grossProfit += t.realizedPnlUsdt;
      } else {
        losses++;
        grossLoss += t.realizedPnlUsdt.abs();
      }

      final riskPerUnit = (t.entryPrice - t.stopLoss).abs();
      final unitRiskUsdt = riskPerUnit * t.quantity;
      if (unitRiskUsdt > 0) {
        sumRR += (t.realizedPnlUsdt / unitRiskUsdt);
      }
    }

    final endingEq = candles15m.isNotEmpty
        ? simBroker.accountEquity({symbol: candles15m.last.close})
        : simBroker.availableCashUsdt;
    final netPnl = endingEq - riskConfig.initialCapitalUsdt;
    final winRate = total > 0 ? (wins / total) * 100.0 : 0.0;
    final pf = grossLoss > 0
        ? (grossProfit / grossLoss)
        : (grossProfit > 0 ? 99.99 : 0.0);
    final avgRR = total > 0 ? (sumRR / total) : 0.0;

    return BacktestReport(
      totalTrades: total,
      winningTrades: wins,
      losingTrades: losses,
      winRatePercent: winRate,
      netPnlUsdt: netPnl,
      endingEquityUsdt: endingEq,
      profitFactor: pf,
      maxDrawdownUsdt: maxDd,
      averageRewardToRisk: avgRR,
    );
  }
}

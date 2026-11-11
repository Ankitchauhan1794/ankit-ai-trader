import 'dart:math' as math;
import '../models/trading_models.dart';
import 'risk_manager.dart';
import 'strategy_engine.dart';

enum CandleStreamOutcome {
  none,
  stopLossTriggered,
  takeProfitTriggered,
  strategyExitTriggered,
}

class PaperBroker {
  final double feeRate;
  final double slippageRate;

  const PaperBroker({
    this.feeRate = 0.001,
    this.slippageRate = 0.0005,
  });

  double computeBuyFillPrice(double referenceAskOrOpen) {
    return referenceAskOrOpen * (1.0 + slippageRate);
  }

  double computeSellFillPrice(double referenceBidOrTrigger) {
    return referenceBidOrTrigger * (1.0 - slippageRate);
  }

  ({
    PaperPosition position,
    SimulatedOrder order,
    double cashDeltaUsdt,
  }) executeEntry({
    required String positionId,
    required String orderId,
    required String symbol,
    required double rawReferencePrice,
    required PositionSizingDecision sizing,
    required int signalCandleCloseMs,
    required int executedAtMs,
    required String reason,
  }) {
    final fillPrice = computeBuyFillPrice(rawReferencePrice);
    final notional = fillPrice * sizing.quantity;
    final fee = notional * feeRate;
    final slDist = rawReferencePrice - sizing.stopLossPrice;
    final tpDist = sizing.takeProfitPrice - rawReferencePrice;
    final pos = PaperPosition(
      id: positionId,
      symbol: symbol,
      entryPrice: fillPrice,
      quantity: sizing.quantity,
      stopLoss: fillPrice - slDist,
      takeProfit: fillPrice + tpDist,
      entryFeeUsdt: fee,
      signalCandleCloseMs: signalCandleCloseMs,
      openedAtMs: executedAtMs,
    );
    final ord = SimulatedOrder(
      id: orderId,
      symbol: symbol,
      side: 'BUY',
      requestedPrice: rawReferencePrice,
      executedPrice: fillPrice,
      quantity: sizing.quantity,
      notionalUsdt: notional,
      feeUsdt: fee,
      signalCandleCloseMs: signalCandleCloseMs,
      executedAtMs: executedAtMs,
      reason: reason,
    );
    return (
      position: pos,
      order: ord,
      cashDeltaUsdt: -(notional + fee),
    );
  }

  /// Stage 18: Conservative SL-first resolution when both SL and TP are touched inside the same closed candle.
  ({
    CandleStreamOutcome outcome,
    ClosedPaperTrade? closedTrade,
    SimulatedOrder? exitOrder,
    double cashDeltaUsdt,
  }) evaluateOpenPositionOnClosedCandle({
    required PaperPosition position,
    required Candle closedCandle,
    required String nextOrderId,
    required String nextTradeId,
    StrategySignalType strategySignal = StrategySignalType.none,
  }) {
    final touchedSl = closedCandle.low <= position.stopLoss;
    final touchedTp = closedCandle.high >= position.takeProfit;

    String? exitReason;
    double? rawExitPrice;
    CandleStreamOutcome outcome = CandleStreamOutcome.none;

    if (touchedSl && touchedTp) {
      // Conservative SL-first rule
      exitReason = 'STOP_LOSS_CONSERVATIVE_BOTH_TOUCHED';
      rawExitPrice = position.stopLoss;
      outcome = CandleStreamOutcome.stopLossTriggered;
    } else if (touchedSl) {
      exitReason = 'STOP_LOSS';
      rawExitPrice = position.stopLoss;
      outcome = CandleStreamOutcome.stopLossTriggered;
    } else if (touchedTp) {
      exitReason = 'TAKE_PROFIT';
      rawExitPrice = position.takeProfit;
      outcome = CandleStreamOutcome.takeProfitTriggered;
    } else if (strategySignal == StrategySignalType.sell) {
      exitReason = 'STRATEGY_SELL_SIGNAL';
      rawExitPrice = closedCandle.close;
      outcome = CandleStreamOutcome.strategyExitTriggered;
    }

    if (exitReason == null || rawExitPrice == null) {
      return (
        outcome: CandleStreamOutcome.none,
        closedTrade: null,
        exitOrder: null,
        cashDeltaUsdt: 0.0,
      );
    }

    final fillExitPrice = computeSellFillPrice(rawExitPrice);
    final exitNotional = fillExitPrice * position.quantity;
    final exitFee = exitNotional * feeRate;
    final totalFees = position.entryFeeUsdt + exitFee;
    final realizedPnl =
        (exitNotional - position.investedNotionalUsdt) - totalFees;

    final ord = SimulatedOrder(
      id: nextOrderId,
      symbol: position.symbol,
      side: 'SELL',
      requestedPrice: rawExitPrice,
      executedPrice: fillExitPrice,
      quantity: position.quantity,
      notionalUsdt: exitNotional,
      feeUsdt: exitFee,
      signalCandleCloseMs: closedCandle.closeTimeMs,
      executedAtMs: closedCandle.closeTimeMs,
      reason: exitReason,
    );

    final trd = ClosedPaperTrade(
      id: nextTradeId,
      symbol: position.symbol,
      entryPrice: position.entryPrice,
      exitPrice: fillExitPrice,
      quantity: position.quantity,
      stopLoss: position.stopLoss,
      takeProfit: position.takeProfit,
      totalFeesUsdt: totalFees,
      realizedPnlUsdt: realizedPnl,
      openedAtMs: position.openedAtMs,
      closedAtMs: closedCandle.closeTimeMs,
      exitReason: exitReason,
    );

    return (
      outcome: outcome,
      closedTrade: trd,
      exitOrder: ord,
      cashDeltaUsdt: exitNotional - exitFee,
    );
  }

  static BacktestReport runHistoricalBacktest({
    required String symbol,
    required List<Candle> candles15m,
    required List<Candle> candles1h,
  }) {
    const broker = PaperBroker();
    const strategy = StrategyEngine();
    const riskMgr = RiskManager();
    const meta = MarketPairMetadata(
      symbol: 'B-BTC_USDT',
      baseCurrency: 'BTC',
      quoteCurrency: 'USDT',
    );

    double cash = 100.0;
    double peakEq = 100.0;
    double maxDd = 0.0;
    final openPositions = <PaperPosition>[];
    final closedTrades = <ClosedPaperTrade>[];
    int? lastSlMs;
    int seq = 0;

    for (int i = 55; i < candles15m.length; i++) {
      final slice15m = candles15m.sublist(0, i + 1);
      final curCandle = slice15m.last;
      final slice1h = candles1h
          .where((c) => c.closeTimeMs <= curCandle.closeTimeMs)
          .toList();
      if (slice1h.length < 50) continue;

      final eval = strategy.evaluate(
        symbol: symbol,
        closedCandles15m: slice15m,
        closedCandles1h: slice1h,
        nowMs: curCandle.closeTimeMs,
      );

      if (openPositions.isNotEmpty) {
        final pos = openPositions.first;
        final res = broker.evaluateOpenPositionOnClosedCandle(
          position: pos,
          closedCandle: curCandle,
          nextOrderId: 'BT_ORD_${++seq}',
          nextTradeId: 'BT_TRD_$seq',
          strategySignal: eval.signal,
        );
        if (res.closedTrade != null) {
          cash += res.cashDeltaUsdt;
          openPositions.clear();
          closedTrades.add(res.closedTrade!);
          if (res.outcome == CandleStreamOutcome.stopLossTriggered) {
            lastSlMs = curCandle.closeTimeMs;
          }
        }
      } else if (eval.signal == StrategySignalType.buy) {
        final eq = cash;
        final sizing = riskMgr.evaluateEntry(
          symbol: symbol,
          entryFillPrice: broker.computeBuyFillPrice(curCandle.close),
          atr14: eval.atr14_15m,
          currentEquityUsdt: eq,
          startOfDayEquityUsdt: 100.0,
          availableCashUsdt: cash,
          openPositions: openPositions,
          metadata: meta,
          lastStopLossClosedAtMs: lastSlMs,
          nowMs: curCandle.closeTimeMs,
        );
        if (sizing.approved) {
          final entry = broker.executeEntry(
            positionId: 'BT_POS_${++seq}',
            orderId: 'BT_ORD_$seq',
            symbol: symbol,
            rawReferencePrice: curCandle.close,
            sizing: sizing,
            signalCandleCloseMs: curCandle.closeTimeMs,
            executedAtMs: curCandle.closeTimeMs,
            reason: eval.reason,
          );
          cash += entry.cashDeltaUsdt;
          openPositions.add(entry.position);
        }
      }

      final curEq = cash +
          openPositions.fold<double>(
            0.0,
            (acc, p) => acc + (p.quantity * curCandle.close),
          );
      if (curEq > peakEq) peakEq = curEq;
      final dd = (peakEq - curEq).clamp(0.0, 100.0);
      if (dd > maxDd) maxDd = dd;
    }

    final wins = closedTrades.where((t) => t.realizedPnlUsdt >= 0).length;
    final losses = closedTrades.length - wins;
    final netPnl = closedTrades.fold<double>(
      0.0,
      (acc, t) => acc + t.realizedPnlUsdt,
    );
    final winRate =
        closedTrades.isNotEmpty ? (wins / closedTrades.length) * 100.0 : 0.0;

    return BacktestReport(
      symbol: symbol,
      totalCandlesEvaluated: candles15m.length,
      totalTrades: closedTrades.length,
      winningTrades: wins,
      losingTrades: losses,
      winRatePct: winRate,
      netPnlUsdt: netPnl,
      endingEquityUsdt: 100.0 + netPnl,
      maxDrawdownUsdt: maxDd,
    );
  }
}

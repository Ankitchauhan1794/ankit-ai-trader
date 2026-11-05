import 'dart:math' as math;
import '../models/trading_models.dart';

class PositionSizeDecision {
  final bool approved;
  final double quantity;
  final double executedEntryPrice;
  final double stopLossPrice;
  final double takeProfitPrice;
  final double estimatedNotionalUsdt;
  final double estimatedEntryFeeUsdt;
  final double estimatedRiskUsdt;
  final String rejectionReason;

  const PositionSizeDecision({
    required this.approved,
    this.quantity = 0.0,
    this.executedEntryPrice = 0.0,
    this.stopLossPrice = 0.0,
    this.takeProfitPrice = 0.0,
    this.estimatedNotionalUsdt = 0.0,
    this.estimatedEntryFeeUsdt = 0.0,
    this.estimatedRiskUsdt = 0.0,
    this.rejectionReason = '',
  });
}

class RiskManager {
  final RiskConfig config;

  const RiskManager({this.config = const RiskConfig()});

  static String utcDayKey(int epochMs) {
    final dt = DateTime.fromMillisecondsSinceEpoch(epochMs, isUtc: true);
    final m = dt.month.toString().padLeft(2, '0');
    final d = dt.day.toString().padLeft(2, '0');
    return '${dt.year}-$m-$d';
  }

  /// Evaluates daily loss against the persistent UTC-day start-of-day equity baseline,
  /// incorporating both realized P&L (including trading fees) and unrealized P&L:
  /// `dailyTotalPnl = currentEquityUsdt - startOfDayEquityUsdt`
  bool isDailyLossLimitReachedAgainstBaseline({
    required double currentEquityUsdt,
    required double startOfDayEquityUsdt,
  }) {
    final dailyTotalPnl = currentEquityUsdt - startOfDayEquityUsdt;
    return dailyTotalPnl <= -config.maxDailyLossDollars + 1e-9;
  }

  /// Also supports direct realized + unrealized components check.
  bool isDailyLossLimitReached({
    required double todayRealizedPnlUsdt,
    required double todayUnrealizedPnlUsdt,
  }) {
    final totalDailyPnl = todayRealizedPnlUsdt + todayUnrealizedPnlUsdt;
    return totalDailyPnl <= -config.maxDailyLossDollars + 1e-9;
  }

  bool isMaxDrawdownReached(double currentEquityUsdt) {
    return currentEquityUsdt <= config.drawdownFloorEquity + 1e-9;
  }

  PositionSizeDecision evaluateEntryAndSize({
    required double rawNextOpenPrice,
    required double atr14,
    required StrategyConfig strategyConfig,
    required double availableCashUsdt,
    required double currentEquityUsdt,
    required double startOfDayEquityUsdt,
    required double todayRealizedPnlUsdt,
    required double todayUnrealizedPnlUsdt,
    required int currentOpenPositionsCount,
    double minNotionalUsdt = 1.0,
    double minQuantity = 0.00001,
  }) {
    if (isMaxDrawdownReached(currentEquityUsdt)) {
      return const PositionSizeDecision(
        approved: false,
        rejectionReason: 'MAXIMUM DRAWDOWN REACHED',
      );
    }

    if (isDailyLossLimitReachedAgainstBaseline(
          currentEquityUsdt: currentEquityUsdt,
          startOfDayEquityUsdt: startOfDayEquityUsdt,
        ) ||
        isDailyLossLimitReached(
          todayRealizedPnlUsdt: todayRealizedPnlUsdt,
          todayUnrealizedPnlUsdt: todayUnrealizedPnlUsdt,
        )) {
      return const PositionSizeDecision(
        approved: false,
        rejectionReason: 'DAILY LOSS LIMIT REACHED',
      );
    }

    if (currentOpenPositionsCount >= config.maxOpenPositions) {
      return const PositionSizeDecision(
        approved: false,
        rejectionReason: 'MAX OPEN POSITIONS REACHED',
      );
    }

    if (rawNextOpenPrice <= 0 || atr14 <= 0 || availableCashUsdt <= 0) {
      return const PositionSizeDecision(
        approved: false,
        rejectionReason: 'INVALID PRICE, ATR OR AVAILABLE CASH',
      );
    }

    final executedEntry = rawNextOpenPrice * (1.0 + config.slippageRate);
    final stopDistance = strategyConfig.stopLossAtrMultiplier * atr14;
    final takeProfitDistance = strategyConfig.takeProfitAtrMultiplier * atr14;

    if (stopDistance <= 0 || stopDistance >= executedEntry) {
      return const PositionSizeDecision(
        approved: false,
        rejectionReason: 'INVALID STOP-LOSS DISTANCE',
      );
    }

    final stopLossPrice = executedEntry - stopDistance;
    final takeProfitPrice = executedEntry + takeProfitDistance;

    final conservativeStopExit = stopLossPrice * (1.0 - config.slippageRate);
    final entryFeePerUnit = executedEntry * config.feeRate;
    final stopExitFeePerUnit = conservativeStopExit * config.feeRate;
    final totalRiskPerUnit =
        (executedEntry - conservativeStopExit) +
            entryFeePerUnit +
            stopExitFeePerUnit;

    if (totalRiskPerUnit <= 0) {
      return const PositionSizeDecision(
        approved: false,
        rejectionReason: 'INVALID RISK PER UNIT',
      );
    }

    final maxAllowedRiskDollars = config.maxRiskPerTradeDollars;
    final qtyByRisk = maxAllowedRiskDollars / totalRiskPerUnit;
    final maxCashQty =
        availableCashUsdt / (executedEntry * (1.0 + config.feeRate));
    final quantity = math.min(qtyByRisk, maxCashQty);

    if (quantity < minQuantity) {
      return const PositionSizeDecision(
        approved: false,
        rejectionReason: 'QUANTITY BELOW EXCHANGE MINIMUM',
      );
    }

    final notional = quantity * executedEntry;
    final entryFee = notional * config.feeRate;
    final estimatedRisk = quantity * totalRiskPerUnit;

    if (notional < minNotionalUsdt) {
      return const PositionSizeDecision(
        approved: false,
        rejectionReason:
            'MINIMUM MARKET NOTIONAL VIOLATES 1% RISK OR CASH LIMIT',
      );
    }

    if (estimatedRisk > maxAllowedRiskDollars + 1e-6) {
      return const PositionSizeDecision(
        approved: false,
        rejectionReason: 'TRADE RISK EXCEEDS 1% LIMIT',
      );
    }

    if (notional + entryFee > availableCashUsdt + 1e-6) {
      return const PositionSizeDecision(
        approved: false,
        rejectionReason: 'INSUFFICIENT AVAILABLE CASH',
      );
    }

    return PositionSizeDecision(
      approved: true,
      quantity: quantity,
      executedEntryPrice: executedEntry,
      stopLossPrice: stopLossPrice,
      takeProfitPrice: takeProfitPrice,
      estimatedNotionalUsdt: notional,
      estimatedEntryFeeUsdt: entryFee,
      estimatedRiskUsdt: estimatedRisk,
    );
  }
}

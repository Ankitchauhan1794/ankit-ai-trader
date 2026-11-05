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

  bool isDailyLossLimitReached(double todayRealizedPnlUsdt) {
    return todayRealizedPnlUsdt <= -config.maxDailyLossDollars + 1e-9;
  }

  bool isMaxDrawdownReached(double currentEquityUsdt) {
    return currentEquityUsdt <= config.drawdownFloorEquity + 1e-9;
  }

  /// Calculates risk-capped position size using stop-loss distance (1.5 × ATR14),
  /// slippage, round-trip fee buffer, available cash, and minimum notional rules.
  PositionSizeDecision evaluateEntryAndSize({
    required double rawNextOpenPrice,
    required double atr14,
    required StrategyConfig strategyConfig,
    required double availableCashUsdt,
    required double currentEquityUsdt,
    required double todayRealizedPnlUsdt,
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

    if (isDailyLossLimitReached(todayRealizedPnlUsdt)) {
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

    // Include conservative exit slippage + round-trip fees in per-unit risk so
    // total realized loss at stop-loss never exceeds $1.00 (1% max risk).
    final conservativeStopExit = stopLossPrice * (1.0 - config.slippageRate);
    final entryFeePerUnit = executedEntry * config.feeRate;
    final stopExitFeePerUnit = conservativeStopExit * config.feeRate;
    final totalRiskPerUnit =
        (executedEntry - conservativeStopExit) + entryFeePerUnit + stopExitFeePerUnit;

    if (totalRiskPerUnit <= 0) {
      return const PositionSizeDecision(
        approved: false,
        rejectionReason: 'INVALID RISK PER UNIT',
      );
    }

    final maxAllowedRiskDollars = config.maxRiskPerTradeDollars;
    final qtyByRisk = maxAllowedRiskDollars / totalRiskPerUnit;

    // Never exceed available cash (1x spot only, no leverage/borrowing)
    final maxCashQty = availableCashUsdt / (executedEntry * (1.0 + config.feeRate));
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
import 'dart:math' as math;
import '../models/trading_models.dart';

class PositionSizingDecision {
  final bool approved;
  final double quantity;
  final double estimatedEntryPrice;
  final double stopLossPrice;
  final double takeProfitPrice;
  final double estimatedRiskUsdt;
  final double estimatedNotionalUsdt;
  final double estimatedEntryFeeUsdt;
  final String rejectionReason;

  const PositionSizingDecision({
    required this.approved,
    this.quantity = 0.0,
    this.estimatedEntryPrice = 0.0,
    this.stopLossPrice = 0.0,
    this.takeProfitPrice = 0.0,
    this.estimatedRiskUsdt = 0.0,
    this.estimatedNotionalUsdt = 0.0,
    this.estimatedEntryFeeUsdt = 0.0,
    this.rejectionReason = '',
  });
}

class RiskManager {
  final RiskConfig config;

  const RiskManager({this.config = const RiskConfig()});

  static String utcDayKey(int epochMs) {
    final dt = DateTime.fromMillisecondsSinceEpoch(epochMs, isUtc: true);
    final y = dt.year.toString().padLeft(4, '0');
    final m = dt.month.toString().padLeft(2, '0');
    final d = dt.day.toString().padLeft(2, '0');
    return '$y-$m-$d';
  }

  bool isMaxDrawdownReached(double currentEquityUsdt) {
    final floor = config.initialCapitalUsdt - config.maxTotalDrawdownUsdt;
    return currentEquityUsdt <= floor + 1e-9;
  }

  bool isDailyLossLimitReached({
    required double currentEquityUsdt,
    required double startOfDayEquityUsdt,
  }) {
    final dailyLoss = startOfDayEquityUsdt - currentEquityUsdt;
    return dailyLoss >= config.maxDailyLossUsdt - 1e-9;
  }

  PositionSizingDecision evaluateEntryAndSize({
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
    double minQuantity = 0.000001,
  }) {
    if (isMaxDrawdownReached(currentEquityUsdt)) {
      return const PositionSizingDecision(
        approved: false,
        rejectionReason: 'MAX DRAWDOWN REACHED (\$90 FLOOR)',
      );
    }

    if (isDailyLossLimitReached(
      currentEquityUsdt: currentEquityUsdt,
      startOfDayEquityUsdt: startOfDayEquityUsdt,
    ) ||
        (todayRealizedPnlUsdt + todayUnrealizedPnlUsdt) <=
            -config.maxDailyLossUsdt + 1e-9) {
      return const PositionSizingDecision(
        approved: false,
        rejectionReason: 'DAILY LOSS LIMIT REACHED (\$2.00)',
      );
    }

    if (currentOpenPositionsCount >= config.maxConcurrentOpenPositions) {
      return const PositionSizingDecision(
        approved: false,
        rejectionReason: 'MAX CONCURRENT OPEN POSITIONS REACHED',
      );
    }

    if (rawNextOpenPrice <= 0 || atr14 <= 0) {
      return const PositionSizingDecision(
        approved: false,
        rejectionReason: 'INVALID ENTRY PRICE OR ATR',
      );
    }

    final entryExecPrice = rawNextOpenPrice * (1.0 + config.slippageRate);
    final stopDistance = atr14 * strategyConfig.stopLossAtrMultiplier;
    final stopLossPrice = entryExecPrice - stopDistance;
    if (stopLossPrice <= 0 || stopLossPrice >= entryExecPrice) {
      return const PositionSizingDecision(
        approved: false,
        rejectionReason: 'INVALID STOP LOSS DISTANCE',
      );
    }

    final takeProfitDistance =
        stopDistance * strategyConfig.takeProfitRewardRiskRatio;
    final takeProfitPrice = entryExecPrice + takeProfitDistance;

    // Effective stop execution price when exiting on SL (includes downward slippage)
    final slExitExecPrice = stopLossPrice * (1.0 - config.slippageRate);
    final priceLossPerUnit = math.max(0.0, entryExecPrice - slExitExecPrice);
    final feePerUnitRoundTrip =
        (entryExecPrice * config.feeRate) + (slExitExecPrice * config.feeRate);
    final totalRiskPerUnit = priceLossPerUnit + feePerUnitRoundTrip;

    if (totalRiskPerUnit <= 0) {
      return const PositionSizingDecision(
        approved: false,
        rejectionReason: 'INVALID UNIT RISK',
      );
    }

    final maxAllowedRiskUsdt = math.min(
      config.initialCapitalUsdt * config.maxRiskPerTradeFraction,
      currentEquityUsdt * config.maxRiskPerTradeFraction,
    );

    final qtyByRisk = maxAllowedRiskUsdt / totalRiskPerUnit;
    final maxAffordableNotional = availableCashUsdt / (1.0 + config.feeRate);
    final qtyByCash = maxAffordableNotional / entryExecPrice;

    final quantity = math.min(qtyByRisk, qtyByCash);
    if (quantity <= 0 || quantity < minQuantity) {
      return const PositionSizingDecision(
        approved: false,
        rejectionReason: 'QUANTITY BELOW EXCHANGE MINIMUM',
      );
    }

    final notionalUsdt = quantity * entryExecPrice;
    if (notionalUsdt < minNotionalUsdt) {
      return const PositionSizingDecision(
        approved: false,
        rejectionReason: 'BELOW MINIMUM ORDER NOTIONAL',
      );
    }

    final entryFeeUsdt = notionalUsdt * config.feeRate;
    if (notionalUsdt + entryFeeUsdt > availableCashUsdt + 1e-9) {
      return const PositionSizingDecision(
        approved: false,
        rejectionReason: 'INSUFFICIENT AVAILABLE CASH',
      );
    }

    final estimatedRiskUsdt = quantity * totalRiskPerUnit;
    if (estimatedRiskUsdt > maxAllowedRiskUsdt + 1e-6) {
      return const PositionSizingDecision(
        approved: false,
        rejectionReason: 'TRADE RISK EXCEEDS 1% LIMIT',
      );
    }

    return PositionSizingDecision(
      approved: true,
      quantity: quantity,
      estimatedEntryPrice: entryExecPrice,
      stopLossPrice: stopLossPrice,
      takeProfitPrice: takeProfitPrice,
      estimatedRiskUsdt: estimatedRiskUsdt,
      estimatedNotionalUsdt: notionalUsdt,
      estimatedEntryFeeUsdt: entryFeeUsdt,
    );
  }
}

import 'dart:math' as math;
import '../models/trading_models.dart';

class RiskConfig {
  final double initialCapitalUsdt;
  final double maxRiskPerTradeFraction;
  final double maxDailyLossUsdt;
  final double maxPortfolioLossPct;
  final double maxTotalDrawdownUsdt;
  final double equityFloorUsdt;
  final int maxConcurrentOpenPositions;
  final double stopLossAtrMultiplier;
  final double takeProfitAtrMultiplier;
  final int postStopLossCooldownMs;

  const RiskConfig({
    this.initialCapitalUsdt = 100.0,
    this.maxRiskPerTradeFraction = 0.01,
    this.maxDailyLossUsdt = 2.0,
    this.maxPortfolioLossPct = 15.0,
    this.maxTotalDrawdownUsdt = 15.0,
    this.equityFloorUsdt = 85.0,
    this.maxConcurrentOpenPositions = 5,
    this.stopLossAtrMultiplier = 1.5,
    this.takeProfitAtrMultiplier = 3.0,
    this.postStopLossCooldownMs = 30 * 60 * 1000,
  });

  double computePortfolioLossFloorUsdt([double? startingBalance]) {
    final base = startingBalance ?? initialCapitalUsdt;
    return (base * (1.0 - (maxPortfolioLossPct / 100.0))).clamp(0.0, base);
  }
}

class PositionSizingDecision {
  final bool approved;
  final double quantity;
  final double notionalUsdt;
  final double stopLossPrice;
  final double takeProfitPrice;
  final double estimatedEntryFeeUsdt;
  final String? rejectionReason;

  const PositionSizingDecision({
    required this.approved,
    this.quantity = 0.0,
    this.notionalUsdt = 0.0,
    this.stopLossPrice = 0.0,
    this.takeProfitPrice = 0.0,
    this.estimatedEntryFeeUsdt = 0.0,
    this.rejectionReason,
  });
}

class RiskManager {
  final RiskConfig config;

  const RiskManager({this.config = const RiskConfig()});

  static String currentUtcDateString(int timestampMs) {
    final dt = DateTime.fromMillisecondsSinceEpoch(timestampMs, isUtc: true);
    final y = dt.year.toString().padLeft(4, '0');
    final m = dt.month.toString().padLeft(2, '0');
    final d = dt.day.toString().padLeft(2, '0');
    return '$y-$m-$d';
  }

  bool shouldStopForMaxDrawdown(
    double currentEquityUsdt, {
    double? startingBalanceUsdt,
    double? maxPortfolioLossPctOverride,
  }) {
    if (maxPortfolioLossPctOverride != null) {
      final base = startingBalanceUsdt ?? config.initialCapitalUsdt;
      final floor =
          (base * (1.0 - (maxPortfolioLossPctOverride / 100.0))).clamp(0.0, base);
      return currentEquityUsdt <= floor + 1e-9;
    }
    return currentEquityUsdt <= config.equityFloorUsdt + 1e-9;
  }

  bool shouldLockDailyLoss({
    required double startOfDayEquityUsdt,
    required double currentEquityUsdt,
  }) {
    return (startOfDayEquityUsdt - currentEquityUsdt) >=
        config.maxDailyLossUsdt - 1e-9;
  }

  bool isInStopLossCooldown({
    required int? lastStopLossClosedAtMs,
    required int nowMs,
  }) {
    if (lastStopLossClosedAtMs == null) return false;
    return (nowMs - lastStopLossClosedAtMs) < config.postStopLossCooldownMs;
  }

  PositionSizingDecision evaluateEntry({
    required String symbol,
    required double entryFillPrice,
    required double atr14,
    required double currentEquityUsdt,
    required double startOfDayEquityUsdt,
    required double availableCashUsdt,
    required List<PaperPosition> openPositions,
    required MarketPairMetadata metadata,
    required int? lastStopLossClosedAtMs,
    required int nowMs,
    double feeRate = 0.001,
    int? maxOpenPositionsOverride,
    int pendingEntriesCount = 0,
    double? maxPortfolioLossPctOverride,
  }) {
    if (shouldStopForMaxDrawdown(
      currentEquityUsdt,
      maxPortfolioLossPctOverride: maxPortfolioLossPctOverride,
    )) {
      return const PositionSizingDecision(
        approved: false,
        rejectionReason: 'PORTFOLIO_LOSS_LIMIT_15PCT_REACHED',
      );
    }
    if (shouldLockDailyLoss(
      startOfDayEquityUsdt: startOfDayEquityUsdt,
      currentEquityUsdt: currentEquityUsdt,
    )) {
      return const PositionSizingDecision(
        approved: false,
        rejectionReason: 'DAILY_LOSS_LIMIT_REACHED',
      );
    }
    if (isInStopLossCooldown(
      lastStopLossClosedAtMs: lastStopLossClosedAtMs,
      nowMs: nowMs,
    )) {
      return const PositionSizingDecision(
        approved: false,
        rejectionReason: 'POST_STOPLOSS_COOLDOWN_ACTIVE',
      );
    }
    final maxAllowedPositions =
        maxOpenPositionsOverride ?? config.maxConcurrentOpenPositions;
    if ((openPositions.length + pendingEntriesCount) >= maxAllowedPositions) {
      return const PositionSizingDecision(
        approved: false,
        rejectionReason: 'MAX_OPEN_POSITIONS_REACHED',
      );
    }
    if (openPositions.any((p) => p.symbol == symbol)) {
      return const PositionSizingDecision(
        approved: false,
        rejectionReason: 'SYMBOL_POSITION_ALREADY_OPEN',
      );
    }
    if (entryFillPrice <= 0 || atr14 <= 0) {
      return const PositionSizingDecision(
        approved: false,
        rejectionReason: 'INVALID_PRICE_OR_ATR',
      );
    }

    final stopDistance = atr14 * config.stopLossAtrMultiplier;
    final tpDistance = atr14 * config.takeProfitAtrMultiplier;
    final stopLossPrice = entryFillPrice - stopDistance;
    final takeProfitPrice = entryFillPrice + tpDistance;
    if (stopLossPrice <= 0 || stopDistance <= 0) {
      return const PositionSizingDecision(
        approved: false,
        rejectionReason: 'INVALID_STOP_DISTANCE',
      );
    }

    final maxRiskUsdt = currentEquityUsdt * config.maxRiskPerTradeFraction;
    double rawQty = maxRiskUsdt / stopDistance;

    final maxAffordableNotional = availableCashUsdt / (1.0 + feeRate);
    if (rawQty * entryFillPrice > maxAffordableNotional) {
      rawQty = maxAffordableNotional / entryFillPrice;
    }

    final step = metadata.stepSize > 0 ? metadata.stepSize : 0.00001;
    final steppedQty = ((rawQty / step) + 1e-9).floorToDouble() * step;
    final factor = math.pow(10, metadata.quantityPrecision).toDouble();
    final qty = ((steppedQty * factor + 1e-9).floorToDouble()) / factor;

    if (qty < metadata.minQuantity) {
      return const PositionSizingDecision(
        approved: false,
        rejectionReason: 'BELOW_MIN_QUANTITY',
      );
    }

    final notional = qty * entryFillPrice;
    if (notional + 1e-9 < metadata.minNotionalUsdt) {
      return const PositionSizingDecision(
        approved: false,
        rejectionReason: 'BELOW_MIN_NOTIONAL',
      );
    }

    final entryFee = notional * feeRate;
    if (notional + entryFee > availableCashUsdt + 1e-9) {
      return const PositionSizingDecision(
        approved: false,
        rejectionReason: 'INSUFFICIENT_AVAILABLE_CASH',
      );
    }

    return PositionSizingDecision(
      approved: true,
      quantity: qty,
      notionalUsdt: notional,
      stopLossPrice: stopLossPrice,
      takeProfitPrice: takeProfitPrice,
      estimatedEntryFeeUsdt: entryFee,
    );
  }
}

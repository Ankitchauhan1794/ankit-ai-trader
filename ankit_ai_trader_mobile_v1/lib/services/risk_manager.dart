import 'dart:math' as math;
import '../models/trading_models.dart';

class RiskConfig {
  final double initialCapitalUsdt;
  final double maxRiskPerTradeFraction;
  final double maxDailyLossUsdt;
  final double maxTotalDrawdownUsdt;
  final int maxConcurrentOpenPositions;
  final double stopLossAtrMultiplier;
  final double takeProfitRewardRiskRatio;
  final int postStopLossCooldownMs;

  const RiskConfig({
    this.initialCapitalUsdt = 100.0,
    this.maxRiskPerTradeFraction = 0.01,
    this.maxDailyLossUsdt = 2.0,
    this.maxTotalDrawdownUsdt = 10.0,
    this.maxConcurrentOpenPositions = 1,
    this.stopLossAtrMultiplier = 1.5,
    this.takeProfitRewardRiskRatio = 2.0,
    this.postStopLossCooldownMs = 30 * 60 * 1000,
  });

  double get equityFloorUsdt => initialCapitalUsdt - maxTotalDrawdownUsdt;
}

class PositionSizingDecision {
  final bool approved;
  final double quantity;
  final double notionalUsdt;
  final double stopLossPrice;
  final double takeProfitPrice;
  final String? rejectionReason;

  const PositionSizingDecision({
    required this.approved,
    this.quantity = 0.0,
    this.notionalUsdt = 0.0,
    this.stopLossPrice = 0.0,
    this.takeProfitPrice = 0.0,
    this.rejectionReason,
  });
}

class RiskManager {
  final RiskConfig config;

  const RiskManager({this.config = const RiskConfig()});

  static String utcDateString(int timestampMs) {
    final dt = DateTime.fromMillisecondsSinceEpoch(timestampMs, isUtc: true);
    final y = dt.year.toString().padLeft(4, '0');
    final m = dt.month.toString().padLeft(2, '0');
    final d = dt.day.toString().padLeft(2, '0');
    return '$y-$m-$d';
  }

  bool isMaxDrawdownReached(double currentEquityUsdt) {
    return currentEquityUsdt <= config.equityFloorUsdt + 1e-9;
  }

  double currentDrawdownUsdt(double currentEquityUsdt) {
    return math.max(0.0, config.initialCapitalUsdt - currentEquityUsdt);
  }

  bool isDailyLossLimitReached({
    required double startOfDayEquityUsdt,
    required double currentEquityUsdt,
  }) {
    return (startOfDayEquityUsdt - currentEquityUsdt) >= config.maxDailyLossUsdt - 1e-9;
  }

  bool isInStopLossCooldown({
    required int? lastStopLossClosedAtMs,
    required int nowMs,
  }) {
    if (lastStopLossClosedAtMs == null || lastStopLossClosedAtMs <= 0) {
      return false;
    }
    return (nowMs - lastStopLossClosedAtMs) < config.postStopLossCooldownMs;
  }

  PositionSizingDecision evaluateEntrySizing({
    required String symbol,
    required double entryFillPrice,
    required double atr14,
    required double currentEquityUsdt,
    required double availableCashUsdt,
    required double startOfDayEquityUsdt,
    required List<PaperPosition> openPositions,
    required MarketPairMetadata pairMetadata,
    required double feeRate,
    int? lastStopLossClosedAtMs,
    int? nowMs,
  }) {
    if (isMaxDrawdownReached(currentEquityUsdt)) {
      return const PositionSizingDecision(
        approved: false,
        rejectionReason:
            'Account equity reached or fell below \$90.00 floor. Engine stopped; manual review & reset required.',
      );
    }

    if (isDailyLossLimitReached(
      startOfDayEquityUsdt: startOfDayEquityUsdt,
      currentEquityUsdt: currentEquityUsdt,
    )) {
      return const PositionSizingDecision(
        approved: false,
        rejectionReason: 'DAILY LOSS LIMIT (\$2.00) REACHED',
      );
    }

    if (nowMs != null &&
        isInStopLossCooldown(
          lastStopLossClosedAtMs: lastStopLossClosedAtMs,
          nowMs: nowMs,
        )) {
      final remMin =
          ((config.postStopLossCooldownMs - (nowMs - lastStopLossClosedAtMs!)) /
                  60000)
              .ceil();
      return PositionSizingDecision(
        approved: false,
        rejectionReason: 'Why no trade: Post stop-loss cooldown (${remMin}m left)',
      );
    }

    if (openPositions.any((p) => p.symbol == symbol)) {
      return const PositionSizingDecision(
        approved: false,
        rejectionReason: 'Why no trade: Position already open for symbol',
      );
    }

    if (openPositions.length >= config.maxConcurrentOpenPositions) {
      return const PositionSizingDecision(
        approved: false,
        rejectionReason: 'Why no trade: Max 1 concurrent open position active',
      );
    }

    if (entryFillPrice <= 0 || atr14 <= 0) {
      return const PositionSizingDecision(
        approved: false,
        rejectionReason: 'INVALID ENTRY PRICE OR ATR',
      );
    }

    final stopDistance = atr14 * config.stopLossAtrMultiplier;
    final stopLossPrice = entryFillPrice - stopDistance;
    if (stopDistance <= 0 || stopLossPrice <= 0) {
      return const PositionSizingDecision(
        approved: false,
        rejectionReason: 'INVALID STOP LOSS DISTANCE',
      );
    }

    final takeProfitPrice =
        entryFillPrice + (stopDistance * config.takeProfitRewardRiskRatio);

    final riskBudgetUsdt = currentEquityUsdt * config.maxRiskPerTradeFraction;
    double rawQty = riskBudgetUsdt / stopDistance;
    double maxAffordableNotional = availableCashUsdt / (1.0 + feeRate);
    double desiredNotional = rawQty * entryFillPrice;
    if (desiredNotional > maxAffordableNotional) {
      desiredNotional = maxAffordableNotional;
      rawQty = desiredNotional / entryFillPrice;
    }

    final step = pairMetadata.stepSize > 0 ? pairMetadata.stepSize : 0.00001;
    final roundedQty = (rawQty / step).floorToDouble() * step;
    final finalNotional = roundedQty * entryFillPrice;

    if (roundedQty <= 0 || finalNotional < pairMetadata.minNotionalUsdt) {
      return const PositionSizingDecision(
        approved: false,
        rejectionReason: 'Why no trade: Below minimum order',
      );
    }

    return PositionSizingDecision(
      approved: true,
      quantity: roundedQty,
      notionalUsdt: finalNotional,
      stopLossPrice: stopLossPrice,
      takeProfitPrice: takeProfitPrice,
    );
  }
}

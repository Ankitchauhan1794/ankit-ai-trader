import '../models/trading_models.dart';
import 'indicator_engine.dart';

class StrategyEvaluationResult {
  final StrategySignalType signalType;
  final String description;
  final double? ema20_15m;
  final double? ema50_15m;
  final double? rsi14_15m;
  final double? atr14_15m;
  final double? ema20_1h;
  final double? ema50_1h;
  final bool higherTimeframeBullish;
  final int evaluatedCandleCloseMs;

  const StrategyEvaluationResult({
    required this.signalType,
    required this.description,
    required this.evaluatedCandleCloseMs,
    this.ema20_15m,
    this.ema50_15m,
    this.rsi14_15m,
    this.atr14_15m,
    this.ema20_1h,
    this.ema50_1h,
    this.higherTimeframeBullish = false,
  });

  Map<String, dynamic> toMap() => {
        'signalType': signalType.name,
        'description': description,
        'evaluatedCandleCloseMs': evaluatedCandleCloseMs,
        'ema20_15m': ema20_15m,
        'ema50_15m': ema50_15m,
        'rsi14_15m': rsi14_15m,
        'atr14_15m': atr14_15m,
        'ema20_1h': ema20_1h,
        'ema50_1h': ema50_1h,
        'higherTimeframeBullish': higherTimeframeBullish,
      };

  factory StrategyEvaluationResult.fromMap(Map<String, dynamic> map) {
    final sigName = (map['signalType'] as String?) ?? 'none';
    return StrategyEvaluationResult(
      signalType: StrategySignalType.values.firstWhere(
        (e) => e.name == sigName,
        orElse: () => StrategySignalType.none,
      ),
      description: (map['description'] as String?) ?? '',
      evaluatedCandleCloseMs:
          (map['evaluatedCandleCloseMs'] as num?)?.toInt() ?? 0,
      ema20_15m: (map['ema20_15m'] as num?)?.toDouble(),
      ema50_15m: (map['ema50_15m'] as num?)?.toDouble(),
      rsi14_15m: (map['rsi14_15m'] as num?)?.toDouble(),
      atr14_15m: (map['atr14_15m'] as num?)?.toDouble(),
      ema20_1h: (map['ema20_1h'] as num?)?.toDouble(),
      ema50_1h: (map['ema50_1h'] as num?)?.toDouble(),
      higherTimeframeBullish:
          (map['higherTimeframeBullish'] as bool?) ?? false,
    );
  }
}

class IntrabarExitDecision {
  final bool shouldExit;
  final double? exitReferencePrice;
  final String reason;

  const IntrabarExitDecision({
    required this.shouldExit,
    this.exitReferencePrice,
    required this.reason,
  });
}

class StrategyEngine {
  final StrategyConfig config;

  const StrategyEngine({this.config = const StrategyConfig()});

  StrategyEvaluationResult evaluateClosedCandles({
    required List<Candle> closed15m,
    required List<Candle> closed1h,
    required bool hasOpenPosition,
  }) {
    if (closed15m.length < config.slowEmaPeriod + 2 ||
        closed1h.length < config.slowEmaPeriod) {
      return StrategyEvaluationResult(
        signalType: StrategySignalType.none,
        description: 'INSUFFICIENT CANDLE HISTORY FOR EMA 50',
        evaluatedCandleCloseMs:
            closed15m.isNotEmpty ? closed15m.last.closeTimeMs : 0,
      );
    }

    final closes1h = closed1h.map((c) => c.close).toList();
    final ema20Series1h =
        IndicatorEngine.calculateEmaSeries(closes1h, config.fastEmaPeriod);
    final ema50Series1h =
        IndicatorEngine.calculateEmaSeries(closes1h, config.slowEmaPeriod);

    final latestEma20_1h = ema20Series1h.last;
    final latestEma50_1h = ema50Series1h.last;
    final htfBullish = latestEma20_1h != null &&
        latestEma50_1h != null &&
        latestEma20_1h > latestEma50_1h;

    final closes15m = closed15m.map((c) => c.close).toList();
    final ema20Series15m =
        IndicatorEngine.calculateEmaSeries(closes15m, config.fastEmaPeriod);
    final ema50Series15m =
        IndicatorEngine.calculateEmaSeries(closes15m, config.slowEmaPeriod);
    final rsiSeries15m =
        IndicatorEngine.calculateRsiSeries(closes15m, config.rsiPeriod);
    final atrSeries15m =
        IndicatorEngine.calculateAtrSeries(closed15m, config.atrPeriod);

    final lastIdx = closed15m.length - 1;
    final prevIdx = lastIdx - 1;

    final currEma20 = ema20Series15m[lastIdx];
    final currEma50 = ema50Series15m[lastIdx];
    final prevEma20 = ema20Series15m[prevIdx];
    final prevEma50 = ema50Series15m[prevIdx];
    final currRsi = rsiSeries15m[lastIdx];
    final currAtr = atrSeries15m[lastIdx];
    final latestCloseMs = closed15m.last.closeTimeMs;

    if (currEma20 == null ||
        currEma50 == null ||
        prevEma20 == null ||
        prevEma50 == null ||
        currRsi == null ||
        currAtr == null ||
        currAtr <= 0) {
      return StrategyEvaluationResult(
        signalType: StrategySignalType.none,
        description: 'INDICATORS WARMING UP',
        evaluatedCandleCloseMs: latestCloseMs,
      );
    }

    final bullishCross = prevEma20 <= prevEma50 && currEma20 > currEma50;
    final bearishCross = prevEma20 >= prevEma50 && currEma20 < currEma50;

    if (hasOpenPosition && bearishCross) {
      return StrategyEvaluationResult(
        signalType: StrategySignalType.exitBearishCross,
        description: 'BEARISH 15M EMA 20/50 CROSSOVER EXIT',
        evaluatedCandleCloseMs: latestCloseMs,
        ema20_15m: currEma20,
        ema50_15m: currEma50,
        rsi14_15m: currRsi,
        atr14_15m: currAtr,
        ema20_1h: latestEma20_1h,
        ema50_1h: latestEma50_1h,
        higherTimeframeBullish: htfBullish,
      );
    }

    if (!hasOpenPosition && bullishCross) {
      if (!htfBullish) {
        return StrategyEvaluationResult(
          signalType: StrategySignalType.waitingHigherTimeframe,
          description: '15M CROSSOVER BLOCKED: 1H TREND NOT BULLISH',
          evaluatedCandleCloseMs: latestCloseMs,
          ema20_15m: currEma20,
          ema50_15m: currEma50,
          rsi14_15m: currRsi,
          atr14_15m: currAtr,
          ema20_1h: latestEma20_1h,
          ema50_1h: latestEma50_1h,
          higherTimeframeBullish: false,
        );
      }

      final rsiInRange = currRsi >= config.rsiMin && currRsi <= config.rsiMax;
      if (rsiInRange) {
        return StrategyEvaluationResult(
          signalType: StrategySignalType.buySignal,
          description:
              'BUY SIGNAL: 1H BULLISH + 15M EMA CROSS + RSI ${currRsi.toStringAsFixed(1)}',
          evaluatedCandleCloseMs: latestCloseMs,
          ema20_15m: currEma20,
          ema50_15m: currEma50,
          rsi14_15m: currRsi,
          atr14_15m: currAtr,
          ema20_1h: latestEma20_1h,
          ema50_1h: latestEma50_1h,
          higherTimeframeBullish: true,
        );
      }
    }

    return StrategyEvaluationResult(
      signalType: StrategySignalType.none,
      description: htfBullish
          ? 'SCANNING 15M (1H BULLISH, RSI ${currRsi.toStringAsFixed(1)})'
          : 'WAITING: 1H EMA20 BELOW EMA50',
      evaluatedCandleCloseMs: latestCloseMs,
      ema20_15m: currEma20,
      ema50_15m: currEma50,
      rsi14_15m: currRsi,
      atr14_15m: currAtr,
      ema20_1h: latestEma20_1h,
      ema50_1h: latestEma50_1h,
      higherTimeframeBullish: htfBullish,
    );
  }

  IntrabarExitDecision checkStopLossOrTakeProfit({
    required PaperPosition position,
    required Candle candle,
  }) {
    final hitStop = candle.low <= position.stopLoss;
    final hitTarget = candle.high >= position.takeProfit;

    if (hitStop && hitTarget) {
      return IntrabarExitDecision(
        shouldExit: true,
        exitReferencePrice: position.stopLoss,
        reason: 'STOP_LOSS_CONSERVATIVE_BOTH_TOUCHED',
      );
    }
    if (hitStop) {
      return IntrabarExitDecision(
        shouldExit: true,
        exitReferencePrice: position.stopLoss,
        reason: 'STOP_LOSS',
      );
    }
    if (hitTarget) {
      return IntrabarExitDecision(
        shouldExit: true,
        exitReferencePrice: position.takeProfit,
        reason: 'TAKE_PROFIT',
      );
    }
    return const IntrabarExitDecision(
      shouldExit: false,
      reason: 'HOLD',
    );
  }

  /// Read-only helper that derives the "WHY NO TRADE" line per coin showing the
  /// first failed condition (no EMA cross, RSI outside 50-65, 1h not bullish,
  /// risk rejected, below minimum order, locked/paused, stale data) from existing
  /// evaluation and state snapshots without changing any strategy or risk logic.
  static String deriveWhyNoTradeReason({
    required BotEngineState botState,
    required MarketDataStatus marketDataStatus,
    required StrategyEvaluationResult? eval,
    bool hasOpenPositionForSymbol = false,
    bool hasOtherOpenPosition = false,
    String? lastSizingRejectionReason,
    StrategyConfig config = const StrategyConfig(),
  }) {
    if (marketDataStatus == MarketDataStatus.stale ||
        botState == BotEngineState.pausedStaleData) {
      return 'Why no trade: Stale data';
    }
    if (botState == BotEngineState.lockedDailyLossLimit ||
        botState == BotEngineState.stoppedMaxDrawdownReached ||
        (eval != null &&
            (eval.description.contains('DAILY LOSS LIMIT') ||
                eval.description.contains('MAXIMUM DRAWDOWN')))) {
      return 'Why no trade: Locked/paused (${botState.name})';
    }
    if (botState != BotEngineState.running) {
      return 'Why no trade: Locked/paused (${botState.name})';
    }
    if (hasOpenPositionForSymbol) {
      return 'Position open — managing SL/TP & exit';
    }
    if (hasOtherOpenPosition) {
      return 'Why no trade: Risk rejected (max 1 open position)';
    }
    if (lastSizingRejectionReason != null &&
        lastSizingRejectionReason.isNotEmpty) {
      final upper = lastSizingRejectionReason.toUpperCase();
      if (upper.contains('MINIMUM') || upper.contains('NOTIONAL')) {
        return 'Why no trade: Below minimum order';
      }
      return 'Why no trade: Risk rejected ($lastSizingRejectionReason)';
    }
    if (eval == null) {
      return 'Why no trade: Awaiting market evaluation';
    }

    final desc = eval.description.toUpperCase();
    if (desc.contains('MINIMUM') || desc.contains('NOTIONAL')) {
      return 'Why no trade: Below minimum order';
    }
    if (eval.signalType == StrategySignalType.blockedByRisk ||
        desc.contains('RISK') ||
        desc.contains('INSUFFICIENT AVAILABLE CASH')) {
      return 'Why no trade: Risk rejected';
    }
    if (eval.ema20_15m == null ||
        eval.ema50_15m == null ||
        eval.rsi14_15m == null) {
      return 'Why no trade: Indicators warming up';
    }
    if (!eval.higherTimeframeBullish ||
        eval.signalType == StrategySignalType.waitingHigherTimeframe ||
        desc.contains('1H TREND NOT BULLISH') ||
        desc.contains('1H EMA20 BELOW EMA50')) {
      return 'Why no trade: 1h not bullish';
    }
    if (eval.signalType == StrategySignalType.buySignal) {
      return 'Buy signal active — pending next 15m candle open';
    }

    final rsi = eval.rsi14_15m!;
    if (rsi < config.rsiMin || rsi > config.rsiMax) {
      return 'Why no trade: RSI outside 50-65 (${rsi.toStringAsFixed(1)})';
    }
    return 'Why no trade: No EMA cross';
  }
}

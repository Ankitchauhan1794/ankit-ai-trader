import '../models/trading_models.dart';
import 'indicator_engine.dart';

class StrategyEvaluationResult {
  final StrategySignalType signalType;
  final String description;
  final int evaluatedCandleCloseMs;
  final double? ema20_15m;
  final double? ema50_15m;
  final double? rsi14_15m;
  final double? atr14_15m;
  final double? ema20_1h;
  final double? ema50_1h;
  final bool higherTimeframeBullish;

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
    final sigName = (map['signalType'] as String?) ?? StrategySignalType.none.name;
    final sig = StrategySignalType.values.firstWhere(
      (e) => e.name == sigName,
      orElse: () => StrategySignalType.none,
    );
    return StrategyEvaluationResult(
      signalType: sig,
      description: (map['description'] as String?) ?? '',
      evaluatedCandleCloseMs:
          (map['evaluatedCandleCloseMs'] as num?)?.toInt() ?? 0,
      ema20_15m: (map['ema20_15m'] as num?)?.toDouble(),
      ema50_15m: (map['ema50_15m'] as num?)?.toDouble(),
      rsi14_15m: (map['rsi14_15m'] as num?)?.toDouble(),
      atr14_15m: (map['atr14_15m'] as num?)?.toDouble(),
      ema20_1h: (map['ema20_1h'] as num?)?.toDouble(),
      ema50_1h: (map['ema50_1h'] as num?)?.toDouble(),
      higherTimeframeBullish: (map['higherTimeframeBullish'] as bool?) ?? false,
    );
  }
}

class ExitDecision {
  final bool shouldExit;
  final double exitReferencePrice;
  final String reason;

  const ExitDecision({
    required this.shouldExit,
    this.exitReferencePrice = 0.0,
    this.reason = '',
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
    final minBars = config.slowEmaPeriod + 2;
    if (closed15m.length < minBars || closed1h.length < config.slowEmaPeriod) {
      return StrategyEvaluationResult(
        signalType: StrategySignalType.none,
        description: 'INSUFFICIENT CANDLE HISTORY FOR EMA 50',
        evaluatedCandleCloseMs:
            closed15m.isNotEmpty ? closed15m.last.closeTimeMs : 0,
      );
    }

    final closes15m = closed15m.map((c) => c.close).toList();
    final closes1h = closed1h.map((c) => c.close).toList();

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

    final ema20Curr = ema20Series15m[lastIdx];
    final ema50Curr = ema50Series15m[lastIdx];
    final ema20Prev = ema20Series15m[prevIdx];
    final ema50Prev = ema50Series15m[prevIdx];
    final rsiCurr = rsiSeries15m[lastIdx];
    final atrCurr = atrSeries15m[lastIdx];

    final closeTimeMs = closed15m.last.closeTimeMs;
    final eligible1h =
        closed1h.where((c) => c.closeTimeMs <= closeTimeMs).toList();
    final htfCandles =
        eligible1h.length >= config.slowEmaPeriod ? eligible1h : closed1h;
    final htfCloses = htfCandles.map((c) => c.close).toList();

    final ema20Series1h =
        IndicatorEngine.calculateEmaSeries(htfCloses, config.fastEmaPeriod);
    final ema50Series1h =
        IndicatorEngine.calculateEmaSeries(htfCloses, config.slowEmaPeriod);
    final ema20_1h = ema20Series1h.last;
    final ema50_1h = ema50Series1h.last;

    if (ema20Curr == null ||
        ema50Curr == null ||
        ema20Prev == null ||
        ema50Prev == null ||
        rsiCurr == null ||
        atrCurr == null ||
        ema20_1h == null ||
        ema50_1h == null) {
      return StrategyEvaluationResult(
        signalType: StrategySignalType.none,
        description: 'INDICATORS WARMING UP',
        evaluatedCandleCloseMs: closeTimeMs,
      );
    }

    final htfBullish = ema20_1h > ema50_1h;

    if (hasOpenPosition) {
      return StrategyEvaluationResult(
        signalType: StrategySignalType.none,
        description: 'MANAGING OPEN POSITION (SL/TP ACTIVE)',
        evaluatedCandleCloseMs: closeTimeMs,
        ema20_15m: ema20Curr,
        ema50_15m: ema50Curr,
        rsi14_15m: rsiCurr,
        atr14_15m: atrCurr,
        ema20_1h: ema20_1h,
        ema50_1h: ema50_1h,
        higherTimeframeBullish: htfBullish,
      );
    }

    final crossedUp = ema20Prev <= ema50Prev && ema20Curr > ema50Curr;
    final rsiValid =
        rsiCurr >= config.rsiMinBullish && rsiCurr <= config.rsiMaxBullish;

    if (crossedUp && !htfBullish) {
      return StrategyEvaluationResult(
        signalType: StrategySignalType.waitingHigherTimeframe,
        description: '15M CROSSOVER BLOCKED: 1H TREND NOT BULLISH',
        evaluatedCandleCloseMs: closeTimeMs,
        ema20_15m: ema20Curr,
        ema50_15m: ema50Curr,
        rsi14_15m: rsiCurr,
        atr14_15m: atrCurr,
        ema20_1h: ema20_1h,
        ema50_1h: ema50_1h,
        higherTimeframeBullish: htfBullish,
      );
    }

    if (crossedUp && htfBullish && rsiValid) {
      return StrategyEvaluationResult(
        signalType: StrategySignalType.buyEntry,
        description:
            'BULLISH 15M EMA20/50 CROSSOVER CONFIRMED (1H BULLISH, RSI ${rsiCurr.toStringAsFixed(1)})',
        evaluatedCandleCloseMs: closeTimeMs,
        ema20_15m: ema20Curr,
        ema50_15m: ema50Curr,
        rsi14_15m: rsiCurr,
        atr14_15m: atrCurr,
        ema20_1h: ema20_1h,
        ema50_1h: ema50_1h,
        higherTimeframeBullish: htfBullish,
      );
    }

    final htfLabel = htfBullish ? '1H BULLISH' : '1H BEARISH';
    return StrategyEvaluationResult(
      signalType: StrategySignalType.none,
      description: 'SCANNING 15M ($htfLabel, RSI ${rsiCurr.toStringAsFixed(1)})',
      evaluatedCandleCloseMs: closeTimeMs,
      ema20_15m: ema20Curr,
      ema50_15m: ema50Curr,
      rsi14_15m: rsiCurr,
      atr14_15m: atrCurr,
      ema20_1h: ema20_1h,
      ema50_1h: ema50_1h,
      higherTimeframeBullish: htfBullish,
    );
  }

  /// Conservative SL/TP evaluation on a closed 15m candle:
  /// If both Stop-Loss and Take-Profit are touched within the same candle,
  /// Stop-Loss is selected conservatively.
  ExitDecision checkStopLossOrTakeProfit({
    required PaperPosition position,
    required Candle candle,
  }) {
    final slTouched = candle.low <= position.stopLoss;
    final tpTouched = candle.high >= position.takeProfit;

    if (slTouched && tpTouched) {
      return ExitDecision(
        shouldExit: true,
        exitReferencePrice: position.stopLoss,
        reason: 'STOP_LOSS_CONSERVATIVE_BOTH_TOUCHED',
      );
    }
    if (slTouched) {
      return ExitDecision(
        shouldExit: true,
        exitReferencePrice: position.stopLoss,
        reason: 'STOP_LOSS',
      );
    }
    if (tpTouched) {
      return ExitDecision(
        shouldExit: true,
        exitReferencePrice: position.takeProfit,
        reason: 'TAKE_PROFIT',
      );
    }
    return const ExitDecision(shouldExit: false);
  }

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
    if (botState != BotEngineState.running) {
      return 'Why no trade: Locked/paused (${botState.name})';
    }
    if (hasOpenPositionForSymbol) {
      return 'Why no trade: Position already open for symbol';
    }
    if (hasOtherOpenPosition) {
      return 'Why no trade: Max 1 concurrent open position active';
    }
    if (lastSizingRejectionReason != null &&
        lastSizingRejectionReason.isNotEmpty) {
      final upper = lastSizingRejectionReason.toUpperCase();
      if (upper.contains('MINIMUM')) {
        return 'Why no trade: Below minimum order';
      }
      return 'Why no trade: Risk rejected';
    }
    if (eval == null || eval.ema20_15m == null) {
      return 'Why no trade: Indicators warming up';
    }
    if (eval.signalType == StrategySignalType.blockedByRisk) {
      if (eval.description.toUpperCase().contains('MINIMUM')) {
        return 'Why no trade: Below minimum order';
      }
      return 'Why no trade: Risk rejected';
    }
    if (!eval.higherTimeframeBullish) {
      return 'Why no trade: 1h not bullish';
    }
    final rsi = eval.rsi14_15m;
    if (rsi != null &&
        (rsi < config.rsiMinBullish || rsi > config.rsiMaxBullish)) {
      return 'Why no trade: RSI outside 50-65 (${rsi.toStringAsFixed(1)})';
    }
    if (eval.signalType == StrategySignalType.buyEntry) {
      return 'Entry signal active — awaiting next 15m candle open';
    }
    return 'Why no trade: No EMA cross';
  }
}

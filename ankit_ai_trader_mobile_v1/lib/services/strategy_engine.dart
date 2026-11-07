import '../models/trading_models.dart';
import 'indicator_engine.dart';

class StrategyConfig {
  final int fastEmaPeriod;
  final int slowEmaPeriod;
  final int rsiPeriod;
  final int atrPeriod;
  final double rsiMinBullish;
  final double rsiMaxBullish;

  const StrategyConfig({
    this.fastEmaPeriod = 20,
    this.slowEmaPeriod = 50,
    this.rsiPeriod = 14,
    this.atrPeriod = 14,
    this.rsiMinBullish = 50.0,
    this.rsiMaxBullish = 65.0,
  });
}

class StrategyEngine {
  final IndicatorEngine indicatorEngine;
  final StrategyConfig config;

  const StrategyEngine({
    this.indicatorEngine = const IndicatorEngine(),
    this.config = const StrategyConfig(),
  });

  StrategyEvaluationResult evaluateClosedCandles({
    required String symbol,
    required List<Candle> closedCandles15m,
    required List<Candle> closedCandles1h,
  }) {
    if (closedCandles15m.length < config.slowEmaPeriod + 2 ||
        closedCandles1h.length < config.slowEmaPeriod + 1) {
      final latestClose = closedCandles15m.isNotEmpty ? closedCandles15m.last.close : 0.0;
      final latestCloseMs = closedCandles15m.isNotEmpty ? closedCandles15m.last.closeTimeMs : 0;
      return StrategyEvaluationResult(
        symbol: symbol,
        signal: StrategySignalType.none,
        evaluatedCandleCloseMs: latestCloseMs,
        closePrice: latestClose,
        ema20_15m: 0.0,
        ema50_15m: 0.0,
        rsi14_15m: 0.0,
        atr14_15m: 0.0,
        ema20_1h: 0.0,
        ema50_1h: 0.0,
        higherTimeframeBullish: false,
        reason: 'Why no trade: Indicators warming up (INSUFFICIENT CANDLE HISTORY FOR EMA 50)',
      );
    }

    final closes15m = closedCandles15m.map((c) => c.close).toList();
    final closes1h = closedCandles1h.map((c) => c.close).toList();

    final ema20Series15m = indicatorEngine.calculateEmaSeries(closes15m, config.fastEmaPeriod);
    final ema50Series15m = indicatorEngine.calculateEmaSeries(closes15m, config.slowEmaPeriod);
    final ema20Series1h = indicatorEngine.calculateEmaSeries(closes1h, config.fastEmaPeriod);
    final ema50Series1h = indicatorEngine.calculateEmaSeries(closes1h, config.slowEmaPeriod);

    final rsi14 = indicatorEngine.calculateRsi(closes15m, period: config.rsiPeriod) ?? 0.0;
    final atr14 = indicatorEngine.calculateAtr(closedCandles15m, period: config.atrPeriod) ?? 0.0;

    final n = closes15m.length - 1;
    final curEma20 = ema20Series15m[n];
    final curEma50 = ema50Series15m[n];
    final prevEma20 = ema20Series15m[n - 1];
    final prevEma50 = ema50Series15m[n - 1];

    final curEma20_1h = ema20Series1h.last;
    final curEma50_1h = ema50Series1h.last;
    final higherBullish = curEma20_1h > curEma50_1h;

    final bullishCross = prevEma20 <= prevEma50 && curEma20 > curEma50;
    final bearishCross = prevEma20 >= prevEma50 && curEma20 < curEma50;
    final rsiValid = rsi14 >= config.rsiMinBullish && rsi14 <= config.rsiMaxBullish;

    final latestCandle = closedCandles15m.last;
    final diagnostics =
        '15m EMA20: ${curEma20.toStringAsFixed(2)} | EMA50: ${curEma50.toStringAsFixed(2)} | RSI14: ${rsi14.toStringAsFixed(1)} | ATR14: ${atr14.toStringAsFixed(2)} | 1h: ${higherBullish ? "BULL" : "BEAR"}';

    if (bearishCross) {
      return StrategyEvaluationResult(
        symbol: symbol,
        signal: StrategySignalType.sell,
        evaluatedCandleCloseMs: latestCandle.closeTimeMs,
        closePrice: latestCandle.close,
        ema20_15m: curEma20,
        ema50_15m: curEma50,
        rsi14_15m: rsi14,
        atr14_15m: atr14,
        ema20_1h: curEma20_1h,
        ema50_1h: curEma50_1h,
        higherTimeframeBullish: higherBullish,
        reason: 'BEARISH 15M EMA20/50 CROSSOVER EXIT ($diagnostics)',
      );
    }

    if (!higherBullish) {
      return StrategyEvaluationResult(
        symbol: symbol,
        signal: StrategySignalType.none,
        evaluatedCandleCloseMs: latestCandle.closeTimeMs,
        closePrice: latestCandle.close,
        ema20_15m: curEma20,
        ema50_15m: curEma50,
        rsi14_15m: rsi14,
        atr14_15m: atr14,
        ema20_1h: curEma20_1h,
        ema50_1h: curEma50_1h,
        higherTimeframeBullish: false,
        reason: 'Why no trade: 1h not bullish ($diagnostics)',
      );
    }

    if (!bullishCross) {
      return StrategyEvaluationResult(
        symbol: symbol,
        signal: StrategySignalType.none,
        evaluatedCandleCloseMs: latestCandle.closeTimeMs,
        closePrice: latestCandle.close,
        ema20_15m: curEma20,
        ema50_15m: curEma50,
        rsi14_15m: rsi14,
        atr14_15m: atr14,
        ema20_1h: curEma20_1h,
        ema50_1h: curEma50_1h,
        higherTimeframeBullish: true,
        reason: 'Why no trade: No EMA cross ($diagnostics)',
      );
    }

    if (!rsiValid) {
      return StrategyEvaluationResult(
        symbol: symbol,
        signal: StrategySignalType.none,
        evaluatedCandleCloseMs: latestCandle.closeTimeMs,
        closePrice: latestCandle.close,
        ema20_15m: curEma20,
        ema50_15m: curEma50,
        rsi14_15m: rsi14,
        atr14_15m: atr14,
        ema20_1h: curEma20_1h,
        ema50_1h: curEma50_1h,
        higherTimeframeBullish: true,
        reason: 'Why no trade: RSI outside 50-65 (${rsi14.toStringAsFixed(1)}) ($diagnostics)',
      );
    }

    return StrategyEvaluationResult(
      symbol: symbol,
      signal: StrategySignalType.buy,
      evaluatedCandleCloseMs: latestCandle.closeTimeMs,
      closePrice: latestCandle.close,
      ema20_15m: curEma20,
      ema50_15m: curEma50,
      rsi14_15m: rsi14,
      atr14_15m: atr14,
      ema20_1h: curEma20_1h,
      ema50_1h: curEma50_1h,
      higherTimeframeBullish: true,
      reason: 'BULLISH 15M EMA20/50 CROSSOVER CONFIRMED (1H BULLISH, RSI ${rsi14.toStringAsFixed(1)})',
    );
  }
}

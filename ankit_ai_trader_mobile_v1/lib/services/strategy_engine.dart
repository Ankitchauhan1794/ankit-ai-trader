import '../models/trading_models.dart';
import 'indicator_engine.dart';

class StrategyConfig {
  final int fastEmaPeriod;
  final int slowEmaPeriod;
  final int rsiPeriod;
  final int atrPeriod;
  final double rsiBuyMin;
  final double rsiBuyMax;
  final double rsiSellThreshold;

  const StrategyConfig({
    this.fastEmaPeriod = 20,
    this.slowEmaPeriod = 50,
    this.rsiPeriod = 14,
    this.atrPeriod = 14,
    this.rsiBuyMin = 50.0,
    this.rsiBuyMax = 68.0,
    this.rsiSellThreshold = 42.0,
  });
}

class StrategyEngine {
  final StrategyConfig config;
  final IndicatorEngine indicators;

  const StrategyEngine({
    this.config = const StrategyConfig(),
    this.indicators = const IndicatorEngine(),
  });

  StrategyEvaluationResult evaluate({
    required String symbol,
    required List<Candle> closedCandles15m,
    required List<Candle> closedCandles1h,
    required int nowMs,
  }) {
    final closed15m =
        closedCandles15m.where((c) => c.isClosedAt(nowMs)).toList();
    final closed1h =
        closedCandles1h.where((c) => c.isClosedAt(nowMs)).toList();

    if (closed15m.length < config.slowEmaPeriod + 2 ||
        closed1h.length < config.slowEmaPeriod) {
      return StrategyEvaluationResult(
        symbol: symbol,
        signal: StrategySignalType.none,
        evaluatedCandleCloseMs:
            closed15m.isNotEmpty ? closed15m.last.closeTimeMs : 0,
        closePrice: closed15m.isNotEmpty ? closed15m.last.close : 0.0,
        ema20_15m: 0.0,
        ema50_15m: 0.0,
        rsi14_15m: 50.0,
        atr14_15m: 0.0,
        ema20_1h: 0.0,
        ema50_1h: 0.0,
        higherTimeframeBullish: false,
        reason:
            'WARMING_UP: Need >=${config.slowEmaPeriod + 2} closed 15m and >=${config.slowEmaPeriod} closed 1h candles',
      );
    }

    final closes15m = closed15m.map((c) => c.close).toList();
    final closes1h = closed1h.map((c) => c.close).toList();

    final ema20Series15m =
        indicators.calculateEmaSeries(closes15m, config.fastEmaPeriod);
    final ema50Series15m =
        indicators.calculateEmaSeries(closes15m, config.slowEmaPeriod);
    final ema20Series1h =
        indicators.calculateEmaSeries(closes1h, config.fastEmaPeriod);
    final ema50Series1h =
        indicators.calculateEmaSeries(closes1h, config.slowEmaPeriod);

    final rsi14 =
        indicators.calculateRsi(closes15m, period: config.rsiPeriod) ?? 50.0;
    final atr14 =
        indicators.calculateAtr(closed15m, period: config.atrPeriod) ?? 0.0;

    final ema20_15m = ema20Series15m.last;
    final ema50_15m = ema50Series15m.last;
    final prevEma20_15m = ema20Series15m[ema20Series15m.length - 2];
    final prevEma50_15m = ema50Series15m[ema50Series15m.length - 2];

    final ema20_1h = ema20Series1h.last;
    final ema50_1h = ema50Series1h.last;
    final htfBullish = ema20_1h > ema50_1h && closes1h.last >= ema20_1h * 0.995;

    final lastCandle = closed15m.last;
    final closePrice = lastCandle.close;

    final crossedUp =
        prevEma20_15m <= prevEma50_15m && ema20_15m > ema50_15m;
    final trendAlignedUp =
        ema20_15m > ema50_15m && closePrice > ema20_15m;
    final rsiInBuyBand =
        rsi14 >= config.rsiBuyMin && rsi14 <= config.rsiBuyMax;

    if (htfBullish &&
        (crossedUp || trendAlignedUp) &&
        rsiInBuyBand &&
        atr14 > 0) {
      return StrategyEvaluationResult(
        symbol: symbol,
        signal: StrategySignalType.buy,
        evaluatedCandleCloseMs: lastCandle.closeTimeMs,
        closePrice: closePrice,
        ema20_15m: ema20_15m,
        ema50_15m: ema50_15m,
        rsi14_15m: rsi14,
        atr14_15m: atr14,
        ema20_1h: ema20_1h,
        ema50_1h: ema50_1h,
        higherTimeframeBullish: true,
        reason:
            'BUY_SIGNAL: 1H Bullish + 15m EMA20>EMA50 + RSI ${rsi14.toStringAsFixed(1)}',
      );
    }

    final crossedDown =
        prevEma20_15m >= prevEma50_15m && ema20_15m < ema50_15m;
    if (crossedDown ||
        (ema20_15m < ema50_15m && rsi14 <= config.rsiSellThreshold)) {
      return StrategyEvaluationResult(
        symbol: symbol,
        signal: StrategySignalType.sell,
        evaluatedCandleCloseMs: lastCandle.closeTimeMs,
        closePrice: closePrice,
        ema20_15m: ema20_15m,
        ema50_15m: ema50_15m,
        rsi14_15m: rsi14,
        atr14_15m: atr14,
        ema20_1h: ema20_1h,
        ema50_1h: ema50_1h,
        higherTimeframeBullish: htfBullish,
        reason:
            'SELL_SIGNAL: 15m EMA20<EMA50 bearish reversal (RSI ${rsi14.toStringAsFixed(1)})',
      );
    }

    final whyNo = !htfBullish
        ? 'NO_TRADE: 1H trend filter not bullish (1H EMA20 <= EMA50)'
        : (ema20_15m <= ema50_15m
            ? 'NO_TRADE: 15m EMA20 <= EMA50'
            : 'NO_TRADE: RSI ${rsi14.toStringAsFixed(1)} outside [${config.rsiBuyMin}-${config.rsiBuyMax}]');

    return StrategyEvaluationResult(
      symbol: symbol,
      signal: StrategySignalType.none,
      evaluatedCandleCloseMs: lastCandle.closeTimeMs,
      closePrice: closePrice,
      ema20_15m: ema20_15m,
      ema50_15m: ema50_15m,
      rsi14_15m: rsi14,
      atr14_15m: atr14,
      ema20_1h: ema20_1h,
      ema50_1h: ema50_1h,
      higherTimeframeBullish: htfBullish,
      reason: whyNo,
    );
  }
}

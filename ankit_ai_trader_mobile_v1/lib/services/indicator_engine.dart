import 'dart:math' as math;
import '../models/trading_models.dart';

class IndicatorEngine {
  const IndicatorEngine();

  List<double> calculateEmaSeries(List<double> closes, int period) {
    if (closes.length < period || period <= 0) return const [];
    final result = List<double>.filled(closes.length, 0.0);
    double sum = 0.0;
    for (int i = 0; i < period; i++) {
      sum += closes[i];
    }
    double ema = sum / period;
    result[period - 1] = ema;
    final k = 2.0 / (period + 1);
    for (int i = period; i < closes.length; i++) {
      ema = (closes[i] - ema) * k + ema;
      result[i] = ema;
    }
    return result;
  }

  double? calculateRsi(List<double> closes, {int period = 14}) {
    if (closes.length <= period) return null;
    double gains = 0.0;
    double losses = 0.0;
    for (int i = 1; i <= period; i++) {
      final diff = closes[i] - closes[i - 1];
      if (diff >= 0) {
        gains += diff;
      } else {
        losses -= diff;
      }
    }
    double avgGain = gains / period;
    double avgLoss = losses / period;
    for (int i = period + 1; i < closes.length; i++) {
      final diff = closes[i] - closes[i - 1];
      final gain = diff > 0 ? diff : 0.0;
      final loss = diff < 0 ? -diff : 0.0;
      avgGain = ((avgGain * (period - 1)) + gain) / period;
      avgLoss = ((avgLoss * (period - 1)) + loss) / period;
    }
    if (avgLoss == 0.0) return 100.0;
    final rs = avgGain / avgLoss;
    return 100.0 - (100.0 / (1.0 + rs));
  }

  double? calculateAtr(List<Candle> candles, {int period = 14}) {
    if (candles.length <= period) return null;
    final trs = <double>[];
    for (int i = 1; i < candles.length; i++) {
      final cur = candles[i];
      final prevClose = candles[i - 1].close;
      final hl = cur.high - cur.low;
      final hc = (cur.high - prevClose).abs();
      final lc = (cur.low - prevClose).abs();
      trs.add(math.max(hl, math.max(hc, lc)));
    }
    if (trs.length < period) return null;
    double atr = 0.0;
    for (int i = 0; i < period; i++) {
      atr += trs[i];
    }
    atr /= period;
    for (int i = period; i < trs.length; i++) {
      atr = ((atr * (period - 1)) + trs[i]) / period;
    }
    return atr;
  }
}

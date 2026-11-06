import '../models/trading_models.dart';

class IndicatorEngine {
  /// Calculates Exponential Moving Average (EMA) series.
  /// First `period` bars use Simple Moving Average (SMA) as seed at index `period - 1`.
  /// Subsequent bars use multiplier `2 / (period + 1)`.
  static List<double?> calculateEmaSeries(List<double> prices, int period) {
    final result = List<double?>.filled(prices.length, null);
    if (period <= 0 || prices.length < period) {
      return result;
    }

    double sum = 0.0;
    for (int i = 0; i < period; i++) {
      sum += prices[i];
    }
    double ema = sum / period;
    result[period - 1] = ema;

    final double k = 2.0 / (period + 1.0);
    for (int i = period; i < prices.length; i++) {
      ema = (prices[i] - ema) * k + ema;
      result[i] = ema;
    }
    return result;
  }

  /// Calculates Wilder's Relative Strength Index (RSI) series.
  /// Seed is at index `period` (requires `period + 1` price points for `period` changes).
  static List<double?> calculateRsiSeries(List<double> prices, int period) {
    final result = List<double?>.filled(prices.length, null);
    if (period <= 0 || prices.length <= period) {
      return result;
    }

    double gainSum = 0.0;
    double lossSum = 0.0;
    for (int i = 1; i <= period; i++) {
      final diff = prices[i] - prices[i - 1];
      if (diff > 0) {
        gainSum += diff;
      } else {
        lossSum += -diff;
      }
    }

    double avgGain = gainSum / period;
    double avgLoss = lossSum / period;

    result[period] = _computeRsiFromAverages(avgGain, avgLoss);

    for (int i = period + 1; i < prices.length; i++) {
      final diff = prices[i] - prices[i - 1];
      final gain = diff > 0 ? diff : 0.0;
      final loss = diff < 0 ? -diff : 0.0;

      avgGain = ((avgGain * (period - 1)) + gain) / period;
      avgLoss = ((avgLoss * (period - 1)) + loss) / period;
      result[i] = _computeRsiFromAverages(avgGain, avgLoss);
    }

    return result;
  }

  static double _computeRsiFromAverages(double avgGain, double avgLoss) {
    if (avgLoss == 0.0 && avgGain == 0.0) {
      return 50.0;
    }
    if (avgLoss == 0.0) {
      return 100.0;
    }
    final rs = avgGain / avgLoss;
    return 100.0 - (100.0 / (1.0 + rs));
  }

  /// Calculates Wilder's Average True Range (ATR) series.
  /// Seed is SMA of first `period` True Ranges at index `period - 1`.
  static List<double?> calculateAtrSeries(List<Candle> candles, int period) {
    final result = List<double?>.filled(candles.length, null);
    if (period <= 0 || candles.length < period) {
      return result;
    }

    final tr = List<double>.filled(candles.length, 0.0);
    for (int i = 0; i < candles.length; i++) {
      final c = candles[i];
      final hl = c.high - c.low;
      if (i == 0) {
        tr[i] = hl;
      } else {
        final prevClose = candles[i - 1].close;
        final hc = (c.high - prevClose).abs();
        final lc = (c.low - prevClose).abs();
        double maxTr = hl;
        if (hc > maxTr) maxTr = hc;
        if (lc > maxTr) maxTr = lc;
        tr[i] = maxTr;
      }
    }

    double sumTr = 0.0;
    for (int i = 0; i < period; i++) {
      sumTr += tr[i];
    }
    double atr = sumTr / period;
    result[period - 1] = atr;

    for (int i = period; i < candles.length; i++) {
      atr = ((atr * (period - 1)) + tr[i]) / period;
      result[i] = atr;
    }

    return result;
  }
}

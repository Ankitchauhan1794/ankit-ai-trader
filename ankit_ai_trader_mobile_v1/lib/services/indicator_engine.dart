import 'dart:math' as math;
import '../models/trading_models.dart';

class IndicatorEngine {
  /// Calculates standard Exponential Moving Average (EMA) series.
  /// Seeds the first EMA value at index `period - 1` with the Simple Moving Average (SMA)
  /// of the first `period` valid closes, then applies `k = 2 / (period + 1)`.
  /// Returns `null` at indices with insufficient history or invalid inputs.
  static List<double?> calculateEmaSeries(List<double> values, int period) {
    if (period <= 0 || values.length < period) {
      return List<double?>.filled(values.length, null);
    }
    for (final v in values) {
      if (!v.isFinite || v <= 0) {
        return List<double?>.filled(values.length, null);
      }
    }

    final result = List<double?>.filled(values.length, null);
    double sum = 0.0;
    for (int i = 0; i < period; i++) {
      sum += values[i];
    }
    double ema = sum / period;
    result[period - 1] = ema;

    final multiplier = 2.0 / (period + 1.0);
    for (int i = period; i < values.length; i++) {
      ema = ((values[i] - ema) * multiplier) + ema;
      result[i] = ema;
    }
    return result;
  }

  /// Calculates Wilder's Relative Strength Index (RSI) series (default period = 14).
  /// Handles zero average loss (`avgLoss == 0`) safely without division by zero.
  static List<double?> calculateRsiSeries(List<double> closes, int period) {
    if (period <= 0 || closes.length <= period) {
      return List<double?>.filled(closes.length, null);
    }
    for (final c in closes) {
      if (!c.isFinite || c <= 0) {
        return List<double?>.filled(closes.length, null);
      }
    }

    final result = List<double?>.filled(closes.length, null);
    double gainSum = 0.0;
    double lossSum = 0.0;

    for (int i = 1; i <= period; i++) {
      final change = closes[i] - closes[i - 1];
      if (change > 0) {
        gainSum += change;
      } else {
        lossSum += -change;
      }
    }

    double avgGain = gainSum / period;
    double avgLoss = lossSum / period;
    result[period] = _computeRsiFromAverages(avgGain, avgLoss);

    for (int i = period + 1; i < closes.length; i++) {
      final change = closes[i] - closes[i - 1];
      final gain = change > 0 ? change : 0.0;
      final loss = change < 0 ? -change : 0.0;

      avgGain = ((avgGain * (period - 1)) + gain) / period;
      avgLoss = ((avgLoss * (period - 1)) + loss) / period;
      result[i] = _computeRsiFromAverages(avgGain, avgLoss);
    }

    return result;
  }

  static double _computeRsiFromAverages(double avgGain, double avgLoss) {
    if (avgLoss <= 1e-12 && avgGain <= 1e-12) {
      return 50.0;
    }
    if (avgLoss <= 1e-12) {
      return 100.0;
    }
    if (avgGain <= 1e-12) {
      return 0.0;
    }
    final rs = avgGain / avgLoss;
    return 100.0 - (100.0 / (1.0 + rs));
  }

  /// Calculates Wilder's Average True Range (ATR) series (default period = 14).
  /// First True Range is `high - low` at index 0; subsequent TRs are
  /// `max(high - low, |high - prevClose|, |low - prevClose|)`.
  static List<double?> calculateAtrSeries(List<Candle> candles, int period) {
    if (period <= 0 || candles.length < period) {
      return List<double?>.filled(candles.length, null);
    }
    for (final c in candles) {
      if (!c.isValid) {
        return List<double?>.filled(candles.length, null);
      }
    }

    final tr = List<double>.filled(candles.length, 0.0);
    tr[0] = candles[0].high - candles[0].low;
    for (int i = 1; i < candles.length; i++) {
      final highLow = candles[i].high - candles[i].low;
      final highPrevClose = (candles[i].high - candles[i - 1].close).abs();
      final lowPrevClose = (candles[i].low - candles[i - 1].close).abs();
      tr[i] = math.max(highLow, math.max(highPrevClose, lowPrevClose));
    }

    final result = List<double?>.filled(candles.length, null);
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
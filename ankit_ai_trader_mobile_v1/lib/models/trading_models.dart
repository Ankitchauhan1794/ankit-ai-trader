enum BotEngineState {
  stopped,
  running,
  pausedNetworkLoss,
  pausedStaleData,
  pausedAfterRecoveryManualStartRequired,
  lockedDailyLossLimit,
  stoppedMaxDrawdownReached,
}

enum MarketDataStatus {
  connected,
  disconnected,
  stale,
  error,
}

enum StrategySignalType {
  none,
  buyEntry,
  waitingHigherTimeframe,
  blockedByRisk,
}

class MarketPairMetadata {
  final String symbol;
  final String pair;
  final String status;
  final double minNotional;
  final double minQuantity;

  const MarketPairMetadata({
    required this.symbol,
    required this.pair,
    required this.status,
    required this.minNotional,
    required this.minQuantity,
  });
}

class Candle {
  final String symbol;
  final String interval;
  final int openTimeMs;
  final int closeTimeMs;
  final double open;
  final double high;
  final double low;
  final double close;
  final double volume;

  const Candle({
    required this.symbol,
    required this.interval,
    required this.openTimeMs,
    required this.closeTimeMs,
    required this.open,
    required this.high,
    required this.low,
    required this.close,
    required this.volume,
  });
}

class PendingEntrySignal {
  final String symbol;
  final int signalCandleCloseMs;
  final double atr14;
  final double rsi14;
  final double ema20;
  final double ema50;

  const PendingEntrySignal({
    required this.symbol,
    required this.signalCandleCloseMs,
    required this.atr14,
    required this.rsi14,
    required this.ema20,
    required this.ema50,
  });

  Map<String, dynamic> toMap() => {
        'symbol': symbol,
        'signalCandleCloseMs': signalCandleCloseMs,
        'atr14': atr14,
        'rsi14': rsi14,
        'ema20': ema20,
        'ema50': ema50,
      };

  factory PendingEntrySignal.fromMap(Map<String, dynamic> map) {
    return PendingEntrySignal(
      symbol: (map['symbol'] as String?) ?? 'BTCUSDT',
      signalCandleCloseMs: (map['signalCandleCloseMs'] as num).toInt(),
      atr14: (map['atr14'] as num).toDouble(),
      rsi14: (map['rsi14'] as num).toDouble(),
      ema20: (map['ema20'] as num).toDouble(),
      ema50: (map['ema50'] as num).toDouble(),
    );
  }
}

class PaperPosition {
  final String id;
  final String symbol;
  final double entryPrice;
  final double quantity;
  final double stopLoss;
  final double takeProfit;
  final double entryFeeUsdt;
  final int signalCandleCloseMs;
  final int openedAtMs;

  const PaperPosition({
    required this.id,
    required this.symbol,
    required this.entryPrice,
    required this.quantity,
    required this.stopLoss,
    required this.takeProfit,
    required this.entryFeeUsdt,
    required this.signalCandleCloseMs,
    required this.openedAtMs,
  });

  Map<String, dynamic> toMap() => {
        'id': id,
        'symbol': symbol,
        'entryPrice': entryPrice,
        'quantity': quantity,
        'stopLoss': stopLoss,
        'takeProfit': takeProfit,
        'entryFeeUsdt': entryFeeUsdt,
        'signalCandleCloseMs': signalCandleCloseMs,
        'openedAtMs': openedAtMs,
      };

  factory PaperPosition.fromMap(Map<String, dynamic> map) {
    return PaperPosition(
      id: map['id'] as String,
      symbol: map['symbol'] as String,
      entryPrice: (map['entryPrice'] as num).toDouble(),
      quantity: (map['quantity'] as num).toDouble(),
      stopLoss: (map['stopLoss'] as num).toDouble(),
      takeProfit: (map['takeProfit'] as num).toDouble(),
      entryFeeUsdt: (map['entryFeeUsdt'] as num).toDouble(),
      signalCandleCloseMs: (map['signalCandleCloseMs'] as num).toInt(),
      openedAtMs: (map['openedAtMs'] as num).toInt(),
    );
  }
}

class ClosedPaperTrade {
  final String id;
  final String symbol;
  final double entryPrice;
  final double exitPrice;
  final double quantity;
  final double stopLoss;
  final double takeProfit;
  final double totalFeesUsdt;
  final double realizedPnlUsdt;
  final int openedAtMs;
  final int closedAtMs;
  final String exitReason;

  const ClosedPaperTrade({
    required this.id,
    required this.symbol,
    required this.entryPrice,
    required this.exitPrice,
    required this.quantity,
    required this.stopLoss,
    required this.takeProfit,
    required this.totalFeesUsdt,
    required this.realizedPnlUsdt,
    required this.openedAtMs,
    required this.closedAtMs,
    required this.exitReason,
  });

  Map<String, dynamic> toMap() => {
        'id': id,
        'symbol': symbol,
        'entryPrice': entryPrice,
        'exitPrice': exitPrice,
        'quantity': quantity,
        'stopLoss': stopLoss,
        'takeProfit': takeProfit,
        'totalFeesUsdt': totalFeesUsdt,
        'realizedPnlUsdt': realizedPnlUsdt,
        'openedAtMs': openedAtMs,
        'closedAtMs': closedAtMs,
        'exitReason': exitReason,
      };

  factory ClosedPaperTrade.fromMap(Map<String, dynamic> map) {
    return ClosedPaperTrade(
      id: map['id'] as String,
      symbol: map['symbol'] as String,
      entryPrice: (map['entryPrice'] as num).toDouble(),
      exitPrice: (map['exitPrice'] as num).toDouble(),
      quantity: (map['quantity'] as num).toDouble(),
      stopLoss: (map['stopLoss'] as num).toDouble(),
      takeProfit: (map['takeProfit'] as num).toDouble(),
      totalFeesUsdt: (map['totalFeesUsdt'] as num).toDouble(),
      realizedPnlUsdt: (map['realizedPnlUsdt'] as num).toDouble(),
      openedAtMs: (map['openedAtMs'] as num).toInt(),
      closedAtMs: (map['closedAtMs'] as num).toInt(),
      exitReason: map['exitReason'] as String,
    );
  }
}

class SimulatedOrder {
  final String id;
  final String symbol;
  final String side;
  final double requestedPrice;
  final double executedPrice;
  final double quantity;
  final double notionalUsdt;
  final double feeUsdt;
  final int signalCandleCloseMs;
  final int executedAtMs;
  final String reason;

  const SimulatedOrder({
    required this.id,
    required this.symbol,
    required this.side,
    required this.requestedPrice,
    required this.executedPrice,
    required this.quantity,
    required this.notionalUsdt,
    required this.feeUsdt,
    required this.signalCandleCloseMs,
    required this.executedAtMs,
    required this.reason,
  });

  Map<String, dynamic> toMap() => {
        'id': id,
        'symbol': symbol,
        'side': side,
        'requestedPrice': requestedPrice,
        'executedPrice': executedPrice,
        'quantity': quantity,
        'notionalUsdt': notionalUsdt,
        'feeUsdt': feeUsdt,
        'signalCandleCloseMs': signalCandleCloseMs,
        'executedAtMs': executedAtMs,
        'reason': reason,
      };

  factory SimulatedOrder.fromMap(Map<String, dynamic> map) {
    return SimulatedOrder(
      id: map['id'] as String,
      symbol: map['symbol'] as String,
      side: map['side'] as String,
      requestedPrice: (map['requestedPrice'] as num).toDouble(),
      executedPrice: (map['executedPrice'] as num).toDouble(),
      quantity: (map['quantity'] as num).toDouble(),
      notionalUsdt: (map['notionalUsdt'] as num).toDouble(),
      feeUsdt: (map['feeUsdt'] as num).toDouble(),
      signalCandleCloseMs: (map['signalCandleCloseMs'] as num).toInt(),
      executedAtMs: (map['executedAtMs'] as num).toInt(),
      reason: map['reason'] as String,
    );
  }
}

class StrategyConfig {
  final int fastEmaPeriod;
  final int slowEmaPeriod;
  final int rsiPeriod;
  final int atrPeriod;
  final double rsiMinBullish;
  final double rsiMaxBullish;
  final double stopLossAtrMultiplier;
  final double takeProfitRewardRiskRatio;

  const StrategyConfig({
    this.fastEmaPeriod = 20,
    this.slowEmaPeriod = 50,
    this.rsiPeriod = 14,
    this.atrPeriod = 14,
    this.rsiMinBullish = 50.0,
    this.rsiMaxBullish = 65.0,
    this.stopLossAtrMultiplier = 1.5,
    this.takeProfitRewardRiskRatio = 2.0,
  });

  Map<String, dynamic> toMap() => {
        'fastEmaPeriod': fastEmaPeriod,
        'slowEmaPeriod': slowEmaPeriod,
        'rsiPeriod': rsiPeriod,
        'atrPeriod': atrPeriod,
        'rsiMinBullish': rsiMinBullish,
        'rsiMaxBullish': rsiMaxBullish,
        'stopLossAtrMultiplier': stopLossAtrMultiplier,
        'takeProfitRewardRiskRatio': takeProfitRewardRiskRatio,
      };

  factory StrategyConfig.fromMap(Map<String, dynamic> map) {
    return StrategyConfig(
      fastEmaPeriod: (map['fastEmaPeriod'] as num?)?.toInt() ?? 20,
      slowEmaPeriod: (map['slowEmaPeriod'] as num?)?.toInt() ?? 50,
      rsiPeriod: (map['rsiPeriod'] as num?)?.toInt() ?? 14,
      atrPeriod: (map['atrPeriod'] as num?)?.toInt() ?? 14,
      rsiMinBullish: (map['rsiMinBullish'] as num?)?.toDouble() ?? 50.0,
      rsiMaxBullish: (map['rsiMaxBullish'] as num?)?.toDouble() ?? 65.0,
      stopLossAtrMultiplier:
          (map['stopLossAtrMultiplier'] as num?)?.toDouble() ?? 1.5,
      takeProfitRewardRiskRatio:
          (map['takeProfitRewardRiskRatio'] as num?)?.toDouble() ?? 2.0,
    );
  }
}

class RiskConfig {
  final double initialCapitalUsdt;
  final double maxRiskPerTradeFraction;
  final double maxDailyLossUsdt;
  final double maxTotalDrawdownUsdt;
  final int maxConcurrentOpenPositions;
  final double feeRate;
  final double slippageRate;

  const RiskConfig({
    this.initialCapitalUsdt = 100.0,
    this.maxRiskPerTradeFraction = 0.01,
    this.maxDailyLossUsdt = 2.0,
    this.maxTotalDrawdownUsdt = 10.0,
    this.maxConcurrentOpenPositions = 1,
    this.feeRate = 0.001,
    this.slippageRate = 0.0005,
  });

  Map<String, dynamic> toMap() => {
        'initialCapitalUsdt': initialCapitalUsdt,
        'maxRiskPerTradeFraction': maxRiskPerTradeFraction,
        'maxDailyLossUsdt': maxDailyLossUsdt,
        'maxTotalDrawdownUsdt': maxTotalDrawdownUsdt,
        'maxConcurrentOpenPositions': maxConcurrentOpenPositions,
        'feeRate': feeRate,
        'slippageRate': slippageRate,
      };

  factory RiskConfig.fromMap(Map<String, dynamic> map) {
    return RiskConfig(
      initialCapitalUsdt:
          (map['initialCapitalUsdt'] as num?)?.toDouble() ?? 100.0,
      maxRiskPerTradeFraction:
          (map['maxRiskPerTradeFraction'] as num?)?.toDouble() ?? 0.01,
      maxDailyLossUsdt: (map['maxDailyLossUsdt'] as num?)?.toDouble() ?? 2.0,
      maxTotalDrawdownUsdt:
          (map['maxTotalDrawdownUsdt'] as num?)?.toDouble() ?? 10.0,
      maxConcurrentOpenPositions:
          (map['maxConcurrentOpenPositions'] as num?)?.toInt() ?? 1,
      feeRate: (map['feeRate'] as num?)?.toDouble() ?? 0.001,
      slippageRate: (map['slippageRate'] as num?)?.toDouble() ?? 0.0005,
    );
  }
}

class BacktestReport {
  final int totalTrades;
  final int winningTrades;
  final int losingTrades;
  final double winRatePercent;
  final double netPnlUsdt;
  final double endingEquityUsdt;
  final double profitFactor;
  final double maxDrawdownUsdt;
  final double averageRewardToRisk;

  const BacktestReport({
    required this.totalTrades,
    required this.winningTrades,
    required this.losingTrades,
    required this.winRatePercent,
    required this.netPnlUsdt,
    required this.endingEquityUsdt,
    required this.profitFactor,
    required this.maxDrawdownUsdt,
    required this.averageRewardToRisk,
  });
}

class ActiveTimerSummary {
  final int? runningSinceMs;
  final int totalActiveMs;
  final int lastSessionDurationMs;

  const ActiveTimerSummary({
    required this.runningSinceMs,
    required this.totalActiveMs,
    required this.lastSessionDurationMs,
  });

  int currentSessionElapsedMs(int nowMs) {
    if (runningSinceMs == null || runningSinceMs! <= 0) return 0;
    return nowMs > runningSinceMs! ? (nowMs - runningSinceMs!) : 0;
  }

  int effectiveTotalActiveMs(int nowMs) {
    return totalActiveMs + currentSessionElapsedMs(nowMs);
  }

  static String formatHhMmSs(int durationMs) {
    final totalSec = durationMs > 0 ? (durationMs ~/ 1000) : 0;
    final h = (totalSec ~/ 3600).toString().padLeft(2, '0');
    final m = ((totalSec % 3600) ~/ 60).toString().padLeft(2, '0');
    final s = (totalSec % 60).toString().padLeft(2, '0');
    return '$h:$m:$s';
  }

  static String formatDaysHhMm(int durationMs) {
    final totalMinutes = durationMs > 0 ? (durationMs ~/ 60000) : 0;
    final days = totalMinutes ~/ (24 * 60);
    final remMinutes = totalMinutes % (24 * 60);
    final h = (remMinutes ~/ 60).toString().padLeft(2, '0');
    final m = (remMinutes % 60).toString().padLeft(2, '0');
    return '${days}d $h:$m';
  }
}

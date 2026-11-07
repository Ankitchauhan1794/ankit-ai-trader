enum BotEngineState {
  stopped,
  running,
  pausedNetworkLoss,
  pausedStaleData,
  pausedAfterRecoveryManualStartRequired,
  lockedDailyLossLimit,
  stoppedMaxDrawdownReached,
}

/// Stage 2: Explicit user session intention persisted independently from runtime state.
enum UserSessionIntention {
  stopped,
  running,
  paused,
}

enum MarketDataStatus {
  healthy,
  stale,
  disconnected,
  warmingUp,
}

enum StrategySignalType {
  none,
  buy,
  sell,
}

class LiveMarketTicker {
  final String symbol;
  final double lastPrice;
  final double bid;
  final double ask;
  final double high24h;
  final double low24h;
  final double volume24h;
  final double change24hPct;
  final int timestampMs;

  const LiveMarketTicker({
    required this.symbol,
    required this.lastPrice,
    required this.bid,
    required this.ask,
    required this.high24h,
    required this.low24h,
    required this.volume24h,
    required this.change24hPct,
    required this.timestampMs,
  });

  double get spreadPct =>
      lastPrice > 0 && ask >= bid ? ((ask - bid) / lastPrice) * 100.0 : 0.0;

  bool isFresh(int nowMs, {int maxAgeMs = 120000}) =>
      timestampMs > 0 && (nowMs - timestampMs) <= maxAgeMs;

  Map<String, dynamic> toMap() => {
        'symbol': symbol,
        'lastPrice': lastPrice,
        'bid': bid,
        'ask': ask,
        'high24h': high24h,
        'low24h': low24h,
        'volume24h': volume24h,
        'change24hPct': change24hPct,
        'timestampMs': timestampMs,
      };

  factory LiveMarketTicker.fromMap(Map<String, dynamic> map) {
    final last = (map['lastPrice'] as num?)?.toDouble() ?? 0.0;
    return LiveMarketTicker(
      symbol: (map['symbol'] as String?) ?? '',
      lastPrice: last,
      bid: (map['bid'] as num?)?.toDouble() ?? last,
      ask: (map['ask'] as num?)?.toDouble() ?? last,
      high24h: (map['high24h'] as num?)?.toDouble() ?? last,
      low24h: (map['low24h'] as num?)?.toDouble() ?? last,
      volume24h: (map['volume24h'] as num?)?.toDouble() ?? 0.0,
      change24hPct: (map['change24hPct'] as num?)?.toDouble() ?? 0.0,
      timestampMs: (map['timestampMs'] as num?)?.toInt() ?? 0,
    );
  }
}

class MarketPairMetadata {
  final String symbol;
  final String baseCurrency;
  final String quoteCurrency;
  final double minNotionalUsdt;
  final double stepSize;

  const MarketPairMetadata({
    required this.symbol,
    required this.baseCurrency,
    required this.quoteCurrency,
    this.minNotionalUsdt = 5.0,
    this.stepSize = 0.00001,
  });
}

class Candle {
  final int openTimeMs;
  final int closeTimeMs;
  final double open;
  final double high;
  final double low;
  final double close;
  final double volume;

  const Candle({
    required this.openTimeMs,
    required this.closeTimeMs,
    required this.open,
    required this.high,
    required this.low,
    required this.close,
    required this.volume,
  });

  bool isClosedAt(int nowMs) => closeTimeMs <= nowMs;
}

class StrategyEvaluationResult {
  final String symbol;
  final StrategySignalType signal;
  final int evaluatedCandleCloseMs;
  final double closePrice;
  final double ema20_15m;
  final double ema50_15m;
  final double rsi14_15m;
  final double atr14_15m;
  final double ema20_1h;
  final double ema50_1h;
  final bool higherTimeframeBullish;
  final String reason;

  const StrategyEvaluationResult({
    required this.symbol,
    required this.signal,
    required this.evaluatedCandleCloseMs,
    required this.closePrice,
    required this.ema20_15m,
    required this.ema50_15m,
    required this.rsi14_15m,
    required this.atr14_15m,
    required this.ema20_1h,
    required this.ema50_1h,
    required this.higherTimeframeBullish,
    required this.reason,
  });
}

class PendingEntrySignal {
  final String symbol;
  final int signalCandleCloseMs;
  final double triggerPrice;
  final double atr14;
  final String reason;

  const PendingEntrySignal({
    required this.symbol,
    required this.signalCandleCloseMs,
    required this.triggerPrice,
    required this.atr14,
    required this.reason,
  });

  Map<String, dynamic> toMap() => {
        'symbol': symbol,
        'signalCandleCloseMs': signalCandleCloseMs,
        'triggerPrice': triggerPrice,
        'atr14': atr14,
        'reason': reason,
      };

  factory PendingEntrySignal.fromMap(Map<String, dynamic> map) =>
      PendingEntrySignal(
        symbol: map['symbol'] as String,
        signalCandleCloseMs: (map['signalCandleCloseMs'] as num).toInt(),
        triggerPrice: (map['triggerPrice'] as num).toDouble(),
        atr14: (map['atr14'] as num).toDouble(),
        reason: (map['reason'] as String?) ?? '',
      );
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

  double get investedNotionalUsdt => entryPrice * quantity;

  double unrealizedPnlUsdt(double markPrice, {double exitFeeRate = 0.001}) {
    final grossValue = markPrice * quantity;
    final estimatedExitFee = grossValue * exitFeeRate;
    return (grossValue - investedNotionalUsdt) - entryFeeUsdt - estimatedExitFee;
  }

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

  factory PaperPosition.fromMap(Map<String, dynamic> map) => PaperPosition(
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

  factory SimulatedOrder.fromMap(Map<String, dynamic> map) => SimulatedOrder(
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

  factory ClosedPaperTrade.fromMap(Map<String, dynamic> map) => ClosedPaperTrade(
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

class TradeAlertPayload {
  final String alertId;
  final String title;
  final String body;
  final int timestampMs;

  const TradeAlertPayload({
    required this.alertId,
    required this.title,
    required this.body,
    required this.timestampMs,
  });
}

class BacktestReport {
  final String symbol;
  final int totalCandlesEvaluated;
  final int totalTrades;
  final int winningTrades;
  final int losingTrades;
  final double winRatePct;
  final double netPnlUsdt;
  final double endingEquityUsdt;
  final double maxDrawdownUsdt;

  const BacktestReport({
    required this.symbol,
    required this.totalCandlesEvaluated,
    required this.totalTrades,
    required this.winningTrades,
    required this.losingTrades,
    required this.winRatePct,
    required this.netPnlUsdt,
    required this.endingEquityUsdt,
    required this.maxDrawdownUsdt,
  });
}

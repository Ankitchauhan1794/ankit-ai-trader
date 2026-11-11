import '../models/trading_models.dart';

class TradeAlertFormatter {
  static TradeAlertPayload formatEntryAlert(
    PaperPosition position,
    SimulatedOrder order,
  ) {
    return TradeAlertPayload(
      alertId: 'ENTRY_${position.id}_${position.signalCandleCloseMs}',
      title: 'PAPER BUY EXECUTED: ${position.symbol}',
      body:
          'Qty: ${position.quantity} @ \$${position.entryPrice.toStringAsFixed(2)} | SL: \$${position.stopLoss.toStringAsFixed(2)} | TP: \$${position.takeProfit.toStringAsFixed(2)}',
      timestampMs: order.executedAtMs,
    );
  }

  static TradeAlertPayload formatExitAlert(ClosedPaperTrade trade) {
    final sign = trade.realizedPnlUsdt >= 0 ? '+' : '';
    return TradeAlertPayload(
      alertId: 'EXIT_${trade.id}_${trade.closedAtMs}',
      title: 'PAPER POSITION CLOSED (${trade.exitReason}): ${trade.symbol}',
      body:
          'Exit @ \$${trade.exitPrice.toStringAsFixed(2)} | Realized PnL: $sign\$${trade.realizedPnlUsdt.toStringAsFixed(2)} USDT',
      timestampMs: trade.closedAtMs,
    );
  }

  static TradeAlertPayload formatRiskPauseAlert({
    required String lockType,
    required String reason,
    required int timestampMs,
  }) {
    return TradeAlertPayload(
      alertId: 'RISK_${lockType}_$timestampMs',
      title: 'RISK SUPERVISOR LOCK: $lockType',
      body: reason,
      timestampMs: timestampMs,
    );
  }
}

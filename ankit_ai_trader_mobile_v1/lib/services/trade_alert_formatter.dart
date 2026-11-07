import '../models/trading_models.dart';

class TradeAlertFormatter {
  const TradeAlertFormatter();

  static TradeAlertPayload formatEntryAlert(
    SimulatedOrder order, {
    required double stopLoss,
    required double takeProfit,
  }) {
    return TradeAlertPayload(
      alertId: 'ENTRY_${order.id}',
      title: '[PAPER TRADE] BUY ${order.symbol}',
      body:
          'Entered ${order.symbol} @ \$${order.executedPrice.toStringAsFixed(2)} | Qty: ${order.quantity.toStringAsFixed(5)} | SL: \$${stopLoss.toStringAsFixed(2)} | TP: \$${takeProfit.toStringAsFixed(2)} (Fees: \$${order.feeUsdt.toStringAsFixed(3)})',
      timestampMs: order.executedAtMs,
    );
  }

  static TradeAlertPayload formatExitAlert(ClosedPaperTrade trade) {
    final sign = trade.realizedPnlUsdt >= 0 ? '+' : '';
    return TradeAlertPayload(
      alertId: 'EXIT_${trade.id}',
      title: '[PAPER TRADE] EXIT ${trade.symbol} (${trade.exitReason})',
      body:
          'Closed ${trade.symbol} @ \$${trade.exitPrice.toStringAsFixed(2)} | PnL: $sign\$${trade.realizedPnlUsdt.toStringAsFixed(2)} (Fees: \$${trade.totalFeesUsdt.toStringAsFixed(3)})',
      timestampMs: trade.closedAtMs,
    );
  }

  static TradeAlertPayload formatSafetyLockAlert({
    required String lockType,
    required String message,
    required int timestampMs,
  }) {
    final dayBucket = timestampMs ~/ (60 * 60 * 1000);
    return TradeAlertPayload(
      alertId: 'LOCK_${lockType}_$dayBucket',
      title: '[PAPER BOT SAFETY LOCK] $lockType',
      body: message,
      timestampMs: timestampMs,
    );
  }
}

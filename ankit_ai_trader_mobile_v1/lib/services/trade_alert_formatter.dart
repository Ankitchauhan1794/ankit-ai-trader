import '../models/trading_models.dart';

class TradeAlertPayload {
  final String alertId;
  final String title;
  final String body;

  const TradeAlertPayload({
    required this.alertId,
    required this.title,
    required this.body,
  });
}

/// Formats trade entry, exit, and safety lock alerts with mandatory
/// `PAPER TRADE` labeling so simulated events are never mistaken for real orders.
class TradeAlertFormatter {
  static TradeAlertPayload formatEntryAlert({
    required SimulatedOrder buyOrder,
    required PaperPosition position,
  }) {
    final riskPerUnit = (position.entryPrice - position.stopLoss).abs();
    final dollarRisk =
        (riskPerUnit * position.quantity) + (position.entryFeeUsdt * 2.0);
    return TradeAlertPayload(
      alertId: 'ENTRY:${buyOrder.id}',
      title: 'PAPER TRADE ENTRY — ${position.symbol} (${buyOrder.side})',
      body:
          '[PAPER TRADE] ${buyOrder.side} ${position.symbol} | Entry: \$${position.entryPrice.toStringAsFixed(2)} | Qty: ${position.quantity.toStringAsFixed(6)} | SL: \$${position.stopLoss.toStringAsFixed(2)} | TP: \$${position.takeProfit.toStringAsFixed(2)} | Risked: \$${dollarRisk.toStringAsFixed(2)}',
    );
  }

  static TradeAlertPayload formatExitAlert({
    required SimulatedOrder sellOrder,
    required ClosedPaperTrade closedTrade,
    required double newAccountEquityUsdt,
  }) {
    final sign = closedTrade.realizedPnlUsdt >= 0 ? '+' : '';
    return TradeAlertPayload(
      alertId: 'EXIT:${sellOrder.id}',
      title: 'PAPER TRADE EXIT — ${closedTrade.symbol} (${closedTrade.exitReason})',
      body:
          '[PAPER TRADE] EXIT ${closedTrade.symbol} @ \$${closedTrade.exitPrice.toStringAsFixed(2)} | Reason: ${closedTrade.exitReason} | Net P&L: $sign\$${closedTrade.realizedPnlUsdt.toStringAsFixed(2)} | Equity: \$${newAccountEquityUsdt.toStringAsFixed(2)}',
    );
  }

  static TradeAlertPayload formatSafetyLockAlert({
    required String lockTypeKey,
    required String lockTitle,
    required String reasonDetail,
    required double currentEquityUsdt,
  }) {
    return TradeAlertPayload(
      alertId: 'LOCK:$lockTypeKey',
      title: 'PAPER TRADE SAFETY LOCK — $lockTitle',
      body:
          '[PAPER TRADE] $lockTitle | $reasonDetail | Equity: \$${currentEquityUsdt.toStringAsFixed(2)}',
    );
  }
}

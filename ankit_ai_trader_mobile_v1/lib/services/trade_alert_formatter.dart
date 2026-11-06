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

class TradeAlertFormatter {
  static TradeAlertPayload formatEntryAlert({
    required SimulatedOrder buyOrder,
    required PaperPosition position,
  }) {
    final slDist = (position.entryPrice - position.stopLoss).abs();
    final estimatedRisk =
        (slDist * position.quantity) + (position.entryFeeUsdt * 2.0);
    return TradeAlertPayload(
      alertId: 'ENTRY:${buyOrder.id}',
      title: 'PAPER TRADE ENTRY — ${buyOrder.symbol} (BUY)',
      body:
          '[PAPER TRADE] BUY ${buyOrder.symbol} | Entry: \$${position.entryPrice.toStringAsFixed(2)} | Qty: ${position.quantity.toStringAsFixed(6)} | SL: \$${position.stopLoss.toStringAsFixed(2)} | TP: \$${position.takeProfit.toStringAsFixed(2)} | Risked: \$${estimatedRisk.toStringAsFixed(2)}',
    );
  }

  static TradeAlertPayload formatExitAlert({
    required SimulatedOrder sellOrder,
    required ClosedPaperTrade closedTrade,
    required double newAccountEquityUsdt,
  }) {
    final sign = closedTrade.realizedPnlUsdt >= 0 ? '+' : '-';
    final absPnl = closedTrade.realizedPnlUsdt.abs().toStringAsFixed(2);
    return TradeAlertPayload(
      alertId: 'EXIT:${sellOrder.id}',
      title: 'PAPER TRADE EXIT — ${closedTrade.symbol}',
      body:
          '[PAPER TRADE] EXIT ${closedTrade.symbol} @ \$${closedTrade.exitPrice.toStringAsFixed(2)} | Reason: ${closedTrade.exitReason} | Net P&L: $sign\$$absPnl | Equity: \$${newAccountEquityUsdt.toStringAsFixed(2)}',
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

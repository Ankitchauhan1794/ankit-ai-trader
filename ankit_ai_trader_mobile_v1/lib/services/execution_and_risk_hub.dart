import 'dart:convert';
import '../models/trading_models.dart';
import 'persistence_db.dart';
import 'risk_manager.dart';

class OrderBookSnapshot {
  final String symbol;
  final Map<double, double> bids;
  final Map<double, double> asks;
  final int timestampMs;

  OrderBookSnapshot({
    required this.symbol,
    required this.bids,
    required this.asks,
    required this.timestampMs,
  });

  double get bestBid =>
      bids.keys.isEmpty ? 0.0 : bids.keys.reduce((a, b) => a > b ? a : b);

  double get bestAsk =>
      asks.keys.isEmpty ? 0.0 : asks.keys.reduce((a, b) => a < b ? a : b);

  double get midPrice =>
      (bestBid > 0 && bestAsk > 0) ? (bestBid + bestAsk) / 2.0 : 0.0;

  double get spreadPct =>
      midPrice > 0 && bestAsk >= bestBid
          ? ((bestAsk - bestBid) / midPrice) * 100.0
          : 0.0;

  bool isValidAndFresh(int nowMs, {int maxAgeMs = 60000}) {
    if (bids.isEmpty || asks.isEmpty) return false;
    if (bestBid <= 0 || bestAsk <= 0 || bestAsk < bestBid) return false;
    if (timestampMs <= 0 || (nowMs - timestampMs) > maxAgeMs) return false;
    return true;
  }
}

class PublicTradeRecord {
  final String tradeId;
  final String symbol;
  final double price;
  final double quantity;
  final bool isBuyerMaker;
  final int timestampMs;

  const PublicTradeRecord({
    required this.tradeId,
    required this.symbol,
    required this.price,
    required this.quantity,
    required this.isBuyerMaker,
    required this.timestampMs,
  });
}

class MarketDataQualityReport {
  final String symbol;
  final bool isFresh;
  final bool isCorrupt;
  final double spreadPct;
  final String statusReason;

  const MarketDataQualityReport({
    required this.symbol,
    required this.isFresh,
    required this.isCorrupt,
    required this.spreadPct,
    required this.statusReason,
  });

  bool get isDecisionAllowed => isFresh && !isCorrupt;
}

enum LedgerCategory {
  signal,
  riskCheck,
  orderLifecycle,
  fill,
  accountChange,
  strategyVersion,
  failure,
  reconciliation,
}

class LedgerRecord {
  final int sequenceNumber;
  final int timestampMs;
  final LedgerCategory category;
  final String eventName;
  final Map<String, dynamic> payload;

  const LedgerRecord({
    required this.sequenceNumber,
    required this.timestampMs,
    required this.category,
    required this.eventName,
    required this.payload,
  });
}

class AppendOnlyEventLedger {
  final PersistenceDatabase persistence;
  final List<LedgerRecord> _records = [];
  int _seq = 0;

  AppendOnlyEventLedger({required this.persistence});

  List<LedgerRecord> get records => List.unmodifiable(_records);

  Future<LedgerRecord> append({
    required LedgerCategory category,
    required String eventName,
    required Map<String, dynamic> payload,
    int? timestampMs,
  }) async {
    final ts = timestampMs ?? DateTime.now().millisecondsSinceEpoch;
    final rec = LedgerRecord(
      sequenceNumber: ++_seq,
      timestampMs: ts,
      category: category,
      eventName: eventName,
      payload: Map<String, dynamic>.from(payload),
    );
    _records.add(rec);
    await persistence.logDiagnosticEvent(
      'LEDGER_${category.name.toUpperCase()}',
      '$eventName: ${jsonEncode(payload)}',
      timestampMs: ts,
    );
    return rec;
  }
}

enum OrderLifecycleState {
  created,
  pendingSubmit,
  open,
  partiallyFilled,
  filled,
  canceled,
  rejected,
  unknownReconciling,
}

class ManagedExecutionOrder {
  final String clientOrderId;
  final String symbol;
  final String side;
  final double requestedQuantity;
  final double filledQuantity;
  final double requestedPrice;
  final double averageFillPrice;
  final double totalFeeUsdt;
  final OrderLifecycleState state;
  final int createdAtMs;
  final int updatedAtMs;
  final String strategyId;
  final String? rejectionReason;

  const ManagedExecutionOrder({
    required this.clientOrderId,
    required this.symbol,
    required this.side,
    required this.requestedQuantity,
    required this.filledQuantity,
    required this.requestedPrice,
    required this.averageFillPrice,
    required this.totalFeeUsdt,
    required this.state,
    required this.createdAtMs,
    required this.updatedAtMs,
    required this.strategyId,
    this.rejectionReason,
  });

  bool get isTerminal =>
      state == OrderLifecycleState.filled ||
      state == OrderLifecycleState.canceled ||
      state == OrderLifecycleState.rejected;

  bool get blocksNewSubmissions =>
      state == OrderLifecycleState.pendingSubmit ||
      state == OrderLifecycleState.unknownReconciling ||
      state == OrderLifecycleState.open ||
      state == OrderLifecycleState.partiallyFilled;

  ManagedExecutionOrder copyWith({
    double? filledQuantity,
    double? averageFillPrice,
    double? totalFeeUsdt,
    OrderLifecycleState? state,
    int? updatedAtMs,
    String? rejectionReason,
  }) {
    return ManagedExecutionOrder(
      clientOrderId: clientOrderId,
      symbol: symbol,
      side: side,
      requestedQuantity: requestedQuantity,
      filledQuantity: filledQuantity ?? this.filledQuantity,
      requestedPrice: requestedPrice,
      averageFillPrice: averageFillPrice ?? this.averageFillPrice,
      totalFeeUsdt: totalFeeUsdt ?? this.totalFeeUsdt,
      state: state ?? this.state,
      createdAtMs: createdAtMs,
      updatedAtMs: updatedAtMs ?? this.updatedAtMs,
      strategyId: strategyId,
      rejectionReason: rejectionReason ?? this.rejectionReason,
    );
  }
}

class IndependentRiskSupervisor {
  final RiskConfig config;
  final int maxConsecutiveLosses;
  final double maxAllowedSpreadPct;
  final double maxAtrVolatilityPct;
  bool emergencyKillSwitchActive = false;
  int consecutiveLosses = 0;

  IndependentRiskSupervisor({
    this.config = const RiskConfig(),
    this.maxConsecutiveLosses = 3,
    this.maxAllowedSpreadPct = 0.35,
    this.maxAtrVolatilityPct = 6.0,
  });

  ({bool approved, String? reason}) vetOrderRequest({
    required String symbol,
    required double currentEquityUsdt,
    required double startOfDayEquityUsdt,
    required double availableCashUsdt,
    required double entryPrice,
    required double stopLossPrice,
    required double quantity,
    required double feeRate,
    required double slippageRate,
    required double spreadPct,
    required double atr14,
    required bool isDataFresh,
    required List<PaperPosition> openPositions,
    required List<ManagedExecutionOrder> activeOrders,
    required int? lastStopLossClosedAtMs,
    required int nowMs,
  }) {
    if (emergencyKillSwitchActive) {
      return (
        approved: false,
        reason: 'RISK_SUPERVISOR_KILL_SWITCH: Emergency kill switch is active',
      );
    }
    if (!isDataFresh) {
      return (
        approved: false,
        reason: 'RISK_SUPERVISOR_STALE_DATA: Market or candle feed is stale',
      );
    }
    if (activeOrders.any((o) => o.blocksNewSubmissions)) {
      return (
        approved: false,
        reason:
            'RISK_SUPERVISOR_RECONCILIATION_LOCK: Earlier order status is unresolved/open',
      );
    }
    if (currentEquityUsdt <= config.equityFloorUsdt + 1e-9) {
      return (
        approved: false,
        reason:
            'RISK_SUPERVISOR_MAX_DRAWDOWN: Equity \$${currentEquityUsdt.toStringAsFixed(2)} <= \$${config.equityFloorUsdt.toStringAsFixed(2)} floor',
      );
    }
    if ((startOfDayEquityUsdt - currentEquityUsdt) >=
        config.maxDailyLossUsdt - 1e-9) {
      return (
        approved: false,
        reason:
            'RISK_SUPERVISOR_DAILY_LOSS: Daily loss reached \$${config.maxDailyLossUsdt.toStringAsFixed(2)} limit',
      );
    }
    if (consecutiveLosses >= maxConsecutiveLosses) {
      return (
        approved: false,
        reason:
            'RISK_SUPERVISOR_CONSECUTIVE_LOSSES: $consecutiveLosses consecutive losses reached',
      );
    }
    if (lastStopLossClosedAtMs != null &&
        (nowMs - lastStopLossClosedAtMs) < config.postStopLossCooldownMs) {
      return (
        approved: false,
        reason: 'RISK_SUPERVISOR_COOLDOWN: Post stop-loss cooldown active',
      );
    }
    if (spreadPct > maxAllowedSpreadPct) {
      return (
        approved: false,
        reason:
            'RISK_SUPERVISOR_SPREAD_GUARD: Spread ${spreadPct.toStringAsFixed(3)}% > ${maxAllowedSpreadPct.toStringAsFixed(2)}%',
      );
    }
    final atrPct = entryPrice > 0 ? (atr14 / entryPrice) * 100.0 : 100.0;
    if (atrPct > maxAtrVolatilityPct) {
      return (
        approved: false,
        reason:
            'RISK_SUPERVISOR_VOLATILITY_GUARD: ATR ${atrPct.toStringAsFixed(2)}% exceeds ${maxAtrVolatilityPct.toStringAsFixed(1)}% cap',
      );
    }
    if (stopLossPrice <= 0 || stopLossPrice >= entryPrice) {
      return (
        approved: false,
        reason: 'RISK_SUPERVISOR_STOPLOSS_GUARD: Mandatory valid stop-loss missing',
      );
    }
    if (openPositions.length >= config.maxConcurrentOpenPositions) {
      return (
        approved: false,
        reason: 'RISK_SUPERVISOR_EXPOSURE_LIMIT: Max concurrent positions reached',
      );
    }

    final notional = entryPrice * quantity;
    final entryFee = notional * feeRate;
    final expectedExitFee = notional * feeRate;
    final expectedSlippageCost = notional * slippageRate * 2.0;
    final priceStopRisk = (entryPrice - stopLossPrice) * quantity;
    final totalMonetaryRiskWithCosts =
        priceStopRisk + entryFee + expectedExitFee + expectedSlippageCost;
    final maxAllowedRiskUsdt =
        currentEquityUsdt * config.maxRiskPerTradeFraction;

    if (totalMonetaryRiskWithCosts > maxAllowedRiskUsdt * 1.35) {
      return (
        approved: false,
        reason:
            'RISK_SUPERVISOR_COST_EXPOSURE: Risk including fees/slippage (\$${totalMonetaryRiskWithCosts.toStringAsFixed(2)}) exceeds limit',
      );
    }
    if (notional + entryFee > availableCashUsdt + 1e-9) {
      return (
        approved: false,
        reason: 'RISK_SUPERVISOR_INSUFFICIENT_CASH: Notional + fee exceeds cash',
      );
    }

    return (approved: true, reason: null);
  }

  void recordClosedTradeOutcome(double realizedPnlUsdt) {
    if (realizedPnlUsdt < 0) {
      consecutiveLosses++;
    } else {
      consecutiveLosses = 0;
    }
  }
}

class DeterministicExecutionEngine {
  final Map<String, ManagedExecutionOrder> _ordersByClientId = {};
  final AppendOnlyEventLedger ledger;
  final IndependentRiskSupervisor riskSupervisor;

  DeterministicExecutionEngine({
    required this.ledger,
    required this.riskSupervisor,
  });

  List<ManagedExecutionOrder> get allOrders =>
      _ordersByClientId.values.toList();

  List<ManagedExecutionOrder> get activeOrders =>
      _ordersByClientId.values.where((o) => !o.isTerminal).toList();

  bool get hasUnresolvedOrder =>
      _ordersByClientId.values.any((o) => o.blocksNewSubmissions);

  void injectOrderForRecoveryTest(ManagedExecutionOrder order) {
    _ordersByClientId[order.clientOrderId] = order;
  }

  Future<int> reconcileStartupOrders({required int nowMs}) async {
    int resolved = 0;
    for (final entry in _ordersByClientId.entries.toList()) {
      final ord = entry.value;
      if (ord.state == OrderLifecycleState.unknownReconciling ||
          ord.state == OrderLifecycleState.pendingSubmit) {
        final canceled = ord.copyWith(
          state: OrderLifecycleState.canceled,
          updatedAtMs: nowMs,
          rejectionReason: 'RECONCILED_ON_STARTUP_SAFE_CANCEL',
        );
        _ordersByClientId[entry.key] = canceled;
        resolved++;
        await ledger.append(
          category: LedgerCategory.reconciliation,
          eventName: 'STARTUP_ORDER_RECONCILED',
          payload: {'clientOrderId': ord.clientOrderId},
          timestampMs: nowMs,
        );
      }
    }
    return resolved;
  }

  Future<ManagedExecutionOrder> submitIdempotentPaperOrder({
    required String clientOrderId,
    required String symbol,
    required String side,
    required double quantity,
    required double requestedPrice,
    required double stopLossPrice,
    required double currentEquityUsdt,
    required double startOfDayEquityUsdt,
    required double availableCashUsdt,
    required double spreadPct,
    required double atr14,
    required bool isDataFresh,
    required List<PaperPosition> openPositions,
    required int? lastStopLossClosedAtMs,
    required int nowMs,
    String strategyId = 'EMA_20_50_RSI_ATR_V1',
    double feeRate = 0.001,
    double slippageRate = 0.0005,
    double partialFillRatio = 1.0,
  }) async {
    if (_ordersByClientId.containsKey(clientOrderId)) {
      return _ordersByClientId[clientOrderId]!;
    }

    final riskDecision = riskSupervisor.vetOrderRequest(
      symbol: symbol,
      currentEquityUsdt: currentEquityUsdt,
      startOfDayEquityUsdt: startOfDayEquityUsdt,
      availableCashUsdt: availableCashUsdt,
      entryPrice: requestedPrice,
      stopLossPrice: stopLossPrice,
      quantity: quantity,
      feeRate: feeRate,
      slippageRate: slippageRate,
      spreadPct: spreadPct,
      atr14: atr14,
      isDataFresh: isDataFresh,
      openPositions: openPositions,
      activeOrders: activeOrders,
      lastStopLossClosedAtMs: lastStopLossClosedAtMs,
      nowMs: nowMs,
    );

    if (!riskDecision.approved) {
      final rejected = ManagedExecutionOrder(
        clientOrderId: clientOrderId,
        symbol: symbol,
        side: side,
        requestedQuantity: quantity,
        filledQuantity: 0.0,
        requestedPrice: requestedPrice,
        averageFillPrice: 0.0,
        totalFeeUsdt: 0.0,
        state: OrderLifecycleState.rejected,
        createdAtMs: nowMs,
        updatedAtMs: nowMs,
        strategyId: strategyId,
        rejectionReason: riskDecision.reason,
      );
      _ordersByClientId[clientOrderId] = rejected;
      await ledger.append(
        category: LedgerCategory.riskCheck,
        eventName: 'ORDER_REJECTED_BY_SUPERVISOR',
        payload: {
          'clientOrderId': clientOrderId,
          'reason': riskDecision.reason,
        },
        timestampMs: nowMs,
      );
      return rejected;
    }

    final ratio = partialFillRatio.clamp(0.0, 1.0);
    final filledQty = quantity * ratio;
    final execPrice = side == 'BUY'
        ? requestedPrice * (1.0 + slippageRate)
        : requestedPrice * (1.0 - slippageRate);
    final fee = filledQty * execPrice * feeRate;
    final state = ratio >= 0.9999
        ? OrderLifecycleState.filled
        : (ratio > 0
            ? OrderLifecycleState.partiallyFilled
            : OrderLifecycleState.open);

    final order = ManagedExecutionOrder(
      clientOrderId: clientOrderId,
      symbol: symbol,
      side: side,
      requestedQuantity: quantity,
      filledQuantity: filledQty,
      requestedPrice: requestedPrice,
      averageFillPrice: execPrice,
      totalFeeUsdt: fee,
      state: state,
      createdAtMs: nowMs,
      updatedAtMs: nowMs,
      strategyId: strategyId,
    );
    _ordersByClientId[clientOrderId] = order;
    await ledger.append(
      category: LedgerCategory.orderLifecycle,
      eventName: 'ORDER_${state.name.toUpperCase()}',
      payload: {
        'clientOrderId': clientOrderId,
        'symbol': symbol,
        'filledQty': filledQty,
        'avgPrice': execPrice,
      },
      timestampMs: nowMs,
    );
    return order;
  }

  Future<ManagedExecutionOrder?> completeRemainingPartialFill({
    required String clientOrderId,
    required int nowMs,
    double feeRate = 0.001,
  }) async {
    final existing = _ordersByClientId[clientOrderId];
    if (existing == null ||
        existing.state != OrderLifecycleState.partiallyFilled) {
      return existing;
    }
    final remQty = existing.requestedQuantity - existing.filledQuantity;
    final addFee = remQty * existing.averageFillPrice * feeRate;
    final completed = existing.copyWith(
      filledQuantity: existing.requestedQuantity,
      totalFeeUsdt: existing.totalFeeUsdt + addFee,
      state: OrderLifecycleState.filled,
      updatedAtMs: nowMs,
    );
    _ordersByClientId[clientOrderId] = completed;
    await ledger.append(
      category: LedgerCategory.fill,
      eventName: 'PARTIAL_FILL_COMPLETED',
      payload: {'clientOrderId': clientOrderId},
      timestampMs: nowMs,
    );
    return completed;
  }
}

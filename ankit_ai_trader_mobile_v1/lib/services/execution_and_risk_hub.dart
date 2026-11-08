import 'dart:convert';
import 'dart:math' as math;
import '../models/trading_models.dart';
import 'persistence_db.dart';
import 'risk_manager.dart';

/// STAGE 44 — CONNECTOR ARCHITECTURE:
/// Standard adapter interface. CoinDCX Spot first.
/// Verified: CoinDCX provides Spot & Crypto Derivatives only (NO Forex or Equity Indices).
enum SupportedAssetClass {
  cryptoSpot,
}

abstract class ExchangeConnectorAdapter {
  String get venueId;
  String get displayName;
  Set<SupportedAssetClass> get supportedAssetClasses;
  Future<Map<String, LiveMarketTicker>> fetchTickers({required int nowMs});
  Future<OrderBookSnapshot> fetchOrderBook({
    required String pair,
    required int nowMs,
    int depth = 20,
  });
  Future<List<PublicTradeRecord>> fetchPublicTrades({
    required String pair,
    required int nowMs,
    int limit = 30,
  });
}

/// STAGE 23 — ADVANCED MARKET DATA ENGINE MODELS:
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
      bids.keys.isEmpty ? 0.0 : bids.keys.reduce(math.max);
  double get bestAsk =>
      asks.keys.isEmpty ? 0.0 : asks.keys.reduce(math.min);
  double get midPrice =>
      (bestBid > 0 && bestAsk > 0) ? (bestBid + bestAsk) / 2.0 : 0.0;
  double get spreadPct =>
      (midPrice > 0 && bestAsk >= bestBid)
          ? ((bestAsk - bestBid) / midPrice) * 100.0
          : 0.0;

  bool isHealthy({required int nowMs, int maxAgeMs = 30000}) {
    if (bids.isEmpty || asks.isEmpty) return false;
    if (bestBid <= 0 || bestAsk <= 0 || bestAsk < bestBid) return false;
    return (nowMs - timestampMs) <= maxAgeMs;
  }
}

class PublicTradeRecord {
  final String symbol;
  final double price;
  final double quantity;
  final int timestampMs;
  final bool isBuyerMaker;

  const PublicTradeRecord({
    required this.symbol,
    required this.price,
    required this.quantity,
    required this.timestampMs,
    required this.isBuyerMaker,
  });
}

class MarketDataQualityReport {
  final String symbol;
  final bool tickerFresh;
  final bool candlesFresh;
  final bool spreadAcceptable;
  final double spreadPct;
  final int tickerAgeMs;
  final int candleAgeMs;
  final String? rejectionReason;

  const MarketDataQualityReport({
    required this.symbol,
    required this.tickerFresh,
    required this.candlesFresh,
    required this.spreadAcceptable,
    required this.spreadPct,
    required this.tickerAgeMs,
    required this.candleAgeMs,
    this.rejectionReason,
  });

  bool get isDecisionAllowed =>
      tickerFresh && candlesFresh && spreadAcceptable && rejectionReason == null;
}

/// STAGE 24 — CENTRAL APPEND-ONLY EVENT LEDGER:
enum LedgerCategory {
  signal,
  riskCheck,
  orderLifecycle,
  fill,
  positionChange,
  accountChange,
  strategyVersion,
  reconciliation,
  securityAudit,
  failure,
}

class LedgerRecord {
  final int sequenceId;
  final int timestampMs;
  final LedgerCategory category;
  final String strategyVersion;
  final String summary;
  final Map<String, dynamic> payload;

  const LedgerRecord({
    required this.sequenceId,
    required this.timestampMs,
    required this.category,
    required this.strategyVersion,
    required this.summary,
    this.payload = const {},
  });

  Map<String, dynamic> toMap() => {
        'sequenceId': sequenceId,
        'timestampMs': timestampMs,
        'category': category.name,
        'strategyVersion': strategyVersion,
        'summary': summary,
        'payload': jsonEncode(payload),
      };
}

class AppendOnlyEventLedger {
  final PersistenceDatabase persistence;
  final List<LedgerRecord> _records = [];
  int _seq = 0;

  AppendOnlyEventLedger({required this.persistence});

  List<LedgerRecord> get records => List.unmodifiable(_records);

  Future<LedgerRecord> append({
    required LedgerCategory category,
    required String strategyVersion,
    required String summary,
    Map<String, dynamic> payload = const {},
    int? timestampMs,
  }) async {
    _seq++;
    final ts = timestampMs ?? DateTime.now().millisecondsSinceEpoch;
    final record = LedgerRecord(
      sequenceId: _seq,
      timestampMs: ts,
      category: category,
      strategyVersion: strategyVersion,
      summary: summary,
      payload: payload,
    );
    _records.insert(0, record);
    if (_records.length > 500) {
      _records.removeRange(500, _records.length);
    }
    await persistence.logDiagnosticEvent(
      'LEDGER_${category.name.toUpperCase()}',
      '[$strategyVersion] $summary',
      timestampMs: ts,
    );
    return record;
  }
}

/// STAGE 25 & 26 — DETERMINISTIC EXECUTION ENGINE & ORDER STATE MACHINE:
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

/// STAGE 27 — INDEPENDENT DETERMINISTIC RISK SUPERVISOR (No AI/LLM Can Override):
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
    // Stage 25 rule: Never submit a new order while an earlier order's status is unknown/in-flight
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

    // Stage 27: Count fees and expected execution costs in monetary exposure
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

/// STAGE 25, 26 & 28 — HIGH-FIDELITY EXECUTION ENGINE WITH IDEMPOTENCY & RECONCILIATION:
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

  bool get hasUnresolvedOrderState =>
      _ordersByClientId.values.any((o) => o.blocksNewSubmissions);

  /// Stage 25: Reconcile open/unknown orders on startup or recovery before allowing new orders.
  Future<int> reconcileStartupOrders({required int nowMs}) async {
    int reconciled = 0;
    for (final entry in _ordersByClientId.entries.toList()) {
      final ord = entry.value;
      if (ord.state == OrderLifecycleState.unknownReconciling ||
          ord.state == OrderLifecycleState.pendingSubmit) {
        _ordersByClientId[entry.key] = ord.copyWith(
          state: OrderLifecycleState.canceled,
          updatedAtMs: nowMs,
          rejectionReason: 'Auto-canceled uncommitted order during startup reconciliation',
        );
        reconciled++;
      }
    }
    if (reconciled > 0) {
      await ledger.append(
        category: LedgerCategory.reconciliation,
        strategyVersion: 'v1.0.0',
        summary: 'Startup reconciliation resolved $reconciled in-flight order(s)',
        timestampMs: nowMs,
      );
    }
    return reconciled;
  }

  /// Stage 26 & 28: Idempotent order submission with bid/ask spread, slippage, fees & partial-fill support.
  Future<ManagedExecutionOrder> submitSimulatedOrder({
    required String clientOrderId,
    required String symbol,
    required String side,
    required double quantity,
    required double bidPrice,
    required double askPrice,
    required double feeRate,
    required double slippageRate,
    required String strategyId,
    required int nowMs,
    double liquidityFillRatio = 1.0,
    double minQuantity = 0.00001,
    double stepSize = 0.00001,
  }) async {
    // Stage 26: Idempotent submit — if clientOrderId already exists, return existing order
    final existing = _ordersByClientId[clientOrderId];
    if (existing != null) {
      return existing;
    }

    // Stage 25: Never submit a new BUY order while an earlier order's status is unknown/open
    if (side == 'BUY' && hasUnresolvedOrderState) {
      final rejected = ManagedExecutionOrder(
        clientOrderId: clientOrderId,
        symbol: symbol,
        side: side,
        requestedQuantity: quantity,
        filledQuantity: 0.0,
        requestedPrice: side == 'BUY' ? askPrice : bidPrice,
        averageFillPrice: 0.0,
        totalFeeUsdt: 0.0,
        state: OrderLifecycleState.rejected,
        createdAtMs: nowMs,
        updatedAtMs: nowMs,
        strategyId: strategyId,
        rejectionReason: 'RECONCILIATION_LOCK: Previous order state unresolved',
      );
      _ordersByClientId[clientOrderId] = rejected;
      return rejected;
    }

    final roundedQty = (((quantity / stepSize) + 1e-9).floorToDouble()) * stepSize;
    if (roundedQty < minQuantity || bidPrice <= 0 || askPrice <= 0 || askPrice < bidPrice) {
      final rejected = ManagedExecutionOrder(
        clientOrderId: clientOrderId,
        symbol: symbol,
        side: side,
        requestedQuantity: quantity,
        filledQuantity: 0.0,
        requestedPrice: side == 'BUY' ? askPrice : bidPrice,
        averageFillPrice: 0.0,
        totalFeeUsdt: 0.0,
        state: OrderLifecycleState.rejected,
        createdAtMs: nowMs,
        updatedAtMs: nowMs,
        strategyId: strategyId,
        rejectionReason: 'INVALID_QUANTITY_OR_BOOK',
      );
      _ordersByClientId[clientOrderId] = rejected;
      return rejected;
    }

    final ratio = liquidityFillRatio.clamp(0.0, 1.0);
    final filledQty = ((((roundedQty * ratio) / stepSize) + 1e-9).floorToDouble()) * stepSize;
    final refPrice = side == 'BUY' ? askPrice : bidPrice;
    final fillPrice = side == 'BUY'
        ? refPrice * (1.0 + slippageRate)
        : refPrice * (1.0 - slippageRate);
    final notional = filledQty * fillPrice;
    final feeUsdt = notional * feeRate;

    final targetState = filledQty <= 0
        ? OrderLifecycleState.open
        : (filledQty + 1e-9 < roundedQty
            ? OrderLifecycleState.partiallyFilled
            : OrderLifecycleState.filled);

    final order = ManagedExecutionOrder(
      clientOrderId: clientOrderId,
      symbol: symbol,
      side: side,
      requestedQuantity: roundedQty,
      filledQuantity: filledQty,
      requestedPrice: refPrice,
      averageFillPrice: fillPrice,
      totalFeeUsdt: feeUsdt,
      state: targetState,
      createdAtMs: nowMs,
      updatedAtMs: nowMs,
      strategyId: strategyId,
    );
    _ordersByClientId[clientOrderId] = order;

    await ledger.append(
      category: LedgerCategory.orderLifecycle,
      strategyVersion: strategyId,
      summary:
          'Order $clientOrderId ($side $symbol) -> ${targetState.name} @ \$${fillPrice.toStringAsFixed(2)}',
      payload: {
        'clientOrderId': clientOrderId,
        'symbol': symbol,
        'side': side,
        'filledQty': filledQty,
        'fillPrice': fillPrice,
        'feeUsdt': feeUsdt,
      },
      timestampMs: nowMs,
    );
    return order;
  }
}

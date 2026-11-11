import 'dart:convert';
import 'dart:math' as math;

enum BotEngineState {
  stopped,
  starting,
  running,
  pausedNetworkLoss,
  reconnecting,
  waitingForFreshData,
  pausedStaleData,
  pausedAfterRecoveryManualStartRequired,
  recoveryFailed,
  failedStartupError,
  lockedDailyLossLimit,
  stoppedMaxDrawdownReached,
}

extension BotEngineStateDisplay on BotEngineState {
  /// Part 2: Exact dashboard state label distinguishing all required states.
  String get dashboardLabel {
    switch (this) {
      case BotEngineState.starting:
        return 'STARTING';
      case BotEngineState.running:
        return 'RUNNING';
      case BotEngineState.pausedNetworkLoss:
        return 'PAUSED_BY_NETWORK';
      case BotEngineState.reconnecting:
        return 'RECONNECTING';
      case BotEngineState.waitingForFreshData:
      case BotEngineState.pausedStaleData:
        return 'WAITING_FOR_FRESH_DATA';
      case BotEngineState.pausedAfterRecoveryManualStartRequired:
        return 'PAUSED_BY_USER';
      case BotEngineState.lockedDailyLossLimit:
      case BotEngineState.stoppedMaxDrawdownReached:
        return 'PAUSED_BY_RISK';
      case BotEngineState.recoveryFailed:
        return 'RECOVERY_FAILED';
      case BotEngineState.failedStartupError:
        return 'FAILED — STARTUP ERROR';
      case BotEngineState.stopped:
        return 'STOPPED';
    }
  }

  /// Task 2: Explicit Startup & Runtime State Machine display label.
  String get startupStateMachineLabel {
    switch (this) {
      case BotEngineState.stopped:
        return 'STOPPED';
      case BotEngineState.starting:
      case BotEngineState.reconnecting:
        return 'STARTING';
      case BotEngineState.running:
        return 'RUNNING';
      case BotEngineState.waitingForFreshData:
        return 'RUNNING — WAITING FOR VALID MARKET DATA';
      case BotEngineState.pausedNetworkLoss:
      case BotEngineState.pausedStaleData:
        return 'PAUSED — NETWORK OR DATA ISSUE';
      case BotEngineState.lockedDailyLossLimit:
      case BotEngineState.stoppedMaxDrawdownReached:
      case BotEngineState.pausedAfterRecoveryManualStartRequired:
        return 'PAUSED — SAFETY RESTRICTION';
      case BotEngineState.failedStartupError:
      case BotEngineState.recoveryFailed:
        return 'FAILED — STARTUP ERROR';
    }
  }

  bool get isNetworkOrStalePause =>
      this == BotEngineState.pausedNetworkLoss ||
      this == BotEngineState.reconnecting ||
      this == BotEngineState.waitingForFreshData ||
      this == BotEngineState.pausedStaleData;

  bool get isRiskLock =>
      this == BotEngineState.lockedDailyLossLimit ||
      this == BotEngineState.stoppedMaxDrawdownReached;

  bool get isStartupFailure =>
      this == BotEngineState.failedStartupError ||
      this == BotEngineState.recoveryFailed;
}

/// Stage 3: Explicit user session intention persisted independently from runtime state.
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

/// Stage 47.1 Section 7 & Part 3: Market Eligibility states (Discovered != Approved Trading Market).
enum MarketEligibilityStatus {
  discovered,
  active,
  inactive,
  dataUnavailable,
  insufficientLiquidity,
  excessiveSpread,
  invalidMarketSpecifications,
  belowMinimumOrderRequirements,
  eligibleForPaperTrading,
  rejectedByRiskControls,
  pendingThresholdConfiguration,
}

extension MarketEligibilityCategory on MarketEligibilityStatus {
  /// Part 3 high-level category label (DISCOVERED, ACTIVE, ELIGIBLE, REJECTED, INACTIVE, DATA_UNAVAILABLE).
  String get categoryLabel {
    switch (this) {
      case MarketEligibilityStatus.eligibleForPaperTrading:
        return 'ELIGIBLE';
      case MarketEligibilityStatus.inactive:
        return 'INACTIVE';
      case MarketEligibilityStatus.dataUnavailable:
        return 'DATA_UNAVAILABLE';
      case MarketEligibilityStatus.active:
        return 'ACTIVE';
      case MarketEligibilityStatus.discovered:
        return 'DISCOVERED';
      case MarketEligibilityStatus.insufficientLiquidity:
      case MarketEligibilityStatus.excessiveSpread:
      case MarketEligibilityStatus.invalidMarketSpecifications:
      case MarketEligibilityStatus.belowMinimumOrderRequirements:
      case MarketEligibilityStatus.rejectedByRiskControls:
      case MarketEligibilityStatus.pendingThresholdConfiguration:
        return 'REJECTED';
    }
  }
}

/// Part 4 & Part 5: Multi-Pair Ranked Signal Opportunity.
class RankedSignalOpportunity {
  final CoinDcxMarketRecord market;
  final StrategyEvaluationResult evaluation;
  final List<Candle> closedCandles15m;
  final List<Candle> closedCandles1h;
  final LiveMarketTicker ticker;
  final double rankingScore;

  const RankedSignalOpportunity({
    required this.market,
    required this.evaluation,
    required this.closedCandles15m,
    required this.closedCandles1h,
    required this.ticker,
    required this.rankingScore,
  });
}

/// Part 7: Detailed Trading Diagnostics Snapshot persisted in SQLite.
class ScanCycleDiagnosticsSnapshot {
  final int? lastCycleTimestampMs;
  final int? lastSuccessfulScanMs;
  final int totalPairsDiscovered;
  final int activePairsCount;
  final int eligiblePairsCount;
  final int rejectedPairsCount;
  final int? lastCatalogueRefreshMs;
  final int totalPairsEvaluated;
  final int pairsSkippedCount;
  final Map<String, String> skippedPairsReasons;
  final int signalsGeneratedCount;
  final int buySignalsCount;
  final int sellSignalsCount;
  final int rejectedSignalsCount;
  final Map<String, String> signalRejectionReasons;
  final int paperOrdersSubmittedCount;
  final int acceptedOrdersCount;
  final int rejectedOrdersCount;
  final String coindcxRestStatus;
  final String webSocketStatus;
  final String recoveryStateLabel;

  const ScanCycleDiagnosticsSnapshot({
    this.lastCycleTimestampMs,
    this.lastSuccessfulScanMs,
    this.totalPairsDiscovered = 0,
    this.activePairsCount = 0,
    this.eligiblePairsCount = 0,
    this.rejectedPairsCount = 0,
    this.lastCatalogueRefreshMs,
    this.totalPairsEvaluated = 0,
    this.pairsSkippedCount = 0,
    this.skippedPairsReasons = const {},
    this.signalsGeneratedCount = 0,
    this.buySignalsCount = 0,
    this.sellSignalsCount = 0,
    this.rejectedSignalsCount = 0,
    this.signalRejectionReasons = const {},
    this.paperOrdersSubmittedCount = 0,
    this.acceptedOrdersCount = 0,
    this.rejectedOrdersCount = 0,
    this.coindcxRestStatus = 'IDLE',
    this.webSocketStatus = 'REST_POLLING_ACTIVE',
    this.recoveryStateLabel = 'NORMAL',
  });

  Map<String, dynamic> toMap() => {
        'lastCycleTimestampMs': lastCycleTimestampMs,
        'lastSuccessfulScanMs': lastSuccessfulScanMs,
        'totalPairsDiscovered': totalPairsDiscovered,
        'activePairsCount': activePairsCount,
        'eligiblePairsCount': eligiblePairsCount,
        'rejectedPairsCount': rejectedPairsCount,
        'lastCatalogueRefreshMs': lastCatalogueRefreshMs,
        'totalPairsEvaluated': totalPairsEvaluated,
        'pairsSkippedCount': pairsSkippedCount,
        'skippedPairsReasons': skippedPairsReasons,
        'signalsGeneratedCount': signalsGeneratedCount,
        'buySignalsCount': buySignalsCount,
        'sellSignalsCount': sellSignalsCount,
        'rejectedSignalsCount': rejectedSignalsCount,
        'signalRejectionReasons': signalRejectionReasons,
        'paperOrdersSubmittedCount': paperOrdersSubmittedCount,
        'acceptedOrdersCount': acceptedOrdersCount,
        'rejectedOrdersCount': rejectedOrdersCount,
        'coindcxRestStatus': coindcxRestStatus,
        'webSocketStatus': webSocketStatus,
        'recoveryStateLabel': recoveryStateLabel,
      };

  factory ScanCycleDiagnosticsSnapshot.fromMap(Map<String, dynamic> map) {
    Map<String, String> parseStrMap(dynamic raw) {
      if (raw is Map) {
        return {
          for (final e in raw.entries) e.key.toString(): e.value.toString(),
        };
      }
      return const {};
    }

    return ScanCycleDiagnosticsSnapshot(
      lastCycleTimestampMs: (map['lastCycleTimestampMs'] as num?)?.toInt(),
      lastSuccessfulScanMs: (map['lastSuccessfulScanMs'] as num?)?.toInt(),
      totalPairsDiscovered: (map['totalPairsDiscovered'] as num?)?.toInt() ?? 0,
      activePairsCount: (map['activePairsCount'] as num?)?.toInt() ?? 0,
      eligiblePairsCount: (map['eligiblePairsCount'] as num?)?.toInt() ?? 0,
      rejectedPairsCount: (map['rejectedPairsCount'] as num?)?.toInt() ?? 0,
      lastCatalogueRefreshMs: (map['lastCatalogueRefreshMs'] as num?)?.toInt(),
      totalPairsEvaluated: (map['totalPairsEvaluated'] as num?)?.toInt() ?? 0,
      pairsSkippedCount: (map['pairsSkippedCount'] as num?)?.toInt() ?? 0,
      skippedPairsReasons: parseStrMap(map['skippedPairsReasons']),
      signalsGeneratedCount:
          (map['signalsGeneratedCount'] as num?)?.toInt() ?? 0,
      buySignalsCount: (map['buySignalsCount'] as num?)?.toInt() ?? 0,
      sellSignalsCount: (map['sellSignalsCount'] as num?)?.toInt() ?? 0,
      rejectedSignalsCount:
          (map['rejectedSignalsCount'] as num?)?.toInt() ?? 0,
      signalRejectionReasons: parseStrMap(map['signalRejectionReasons']),
      paperOrdersSubmittedCount:
          (map['paperOrdersSubmittedCount'] as num?)?.toInt() ?? 0,
      acceptedOrdersCount: (map['acceptedOrdersCount'] as num?)?.toInt() ?? 0,
      rejectedOrdersCount: (map['rejectedOrdersCount'] as num?)?.toInt() ?? 0,
      coindcxRestStatus: (map['coindcxRestStatus'] as String?) ?? 'IDLE',
      webSocketStatus:
          (map['webSocketStatus'] as String?) ?? 'REST_POLLING_ACTIVE',
      recoveryStateLabel: (map['recoveryStateLabel'] as String?) ?? 'NORMAL',
    );
  }
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
      lastPrice > 0 && ask >= bid && bid > 0
          ? ((ask - bid) / ((ask + bid) / 2.0)) * 100.0
          : 0.0;

  double get spreadBps => spreadPct * 100.0;

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
  final double minQuantity;
  final double maxQuantity;
  final int pricePrecision;
  final int quantityPrecision;

  const MarketPairMetadata({
    required this.symbol,
    required this.baseCurrency,
    required this.quoteCurrency,
    this.minNotionalUsdt = 5.0,
    this.stepSize = 0.00001,
    this.minQuantity = 0.00001,
    this.maxQuantity = 90000000.0,
    this.pricePrecision = 2,
    this.quantityPrecision = 5,
  });
}

class CoinDcxMarketRecord {
  final String exchangeName;
  final String coindcxName;
  final String symbol;
  final String pair;
  final String ecode;
  final String baseCurrencyShortName;
  final String targetCurrencyShortName;
  final String baseCurrencyName;
  final String targetCurrencyName;
  final String status;
  final int baseCurrencyPrecision;
  final int targetCurrencyPrecision;
  final double minQuantity;
  final double maxQuantity;
  final double maxQuantityMarket;
  final double step;
  final double minNotional;
  final double minPrice;
  final double maxPrice;
  final List<String> orderTypes;
  final LiveMarketTicker? latestTicker;
  final int? latestDataTimestampMs;
  final int lastMetadataRefreshMs;
  final bool isNewlyListed;
  final bool isInActiveMarketsList;
  final MarketEligibilityStatus eligibilityStatus;
  final String eligibilityReason;

  const CoinDcxMarketRecord({
    this.exchangeName = 'CoinDCX',
    required this.coindcxName,
    required this.symbol,
    required this.pair,
    required this.ecode,
    required this.baseCurrencyShortName,
    required this.targetCurrencyShortName,
    this.baseCurrencyName = '',
    this.targetCurrencyName = '',
    required this.status,
    required this.baseCurrencyPrecision,
    required this.targetCurrencyPrecision,
    required this.minQuantity,
    required this.maxQuantity,
    required this.maxQuantityMarket,
    required this.step,
    required this.minNotional,
    required this.minPrice,
    required this.maxPrice,
    required this.orderTypes,
    this.latestTicker,
    this.latestDataTimestampMs,
    required this.lastMetadataRefreshMs,
    this.isNewlyListed = false,
    this.isInActiveMarketsList = true,
    this.eligibilityStatus = MarketEligibilityStatus.discovered,
    this.eligibilityReason = 'Discovered in CoinDCX catalogue',
  });

  String get quoteCurrency => baseCurrencyShortName;
  String get tradedAssetCurrency => targetCurrencyShortName;
  int get pricePrecision => baseCurrencyPrecision;
  int get quantityPrecision => targetCurrencyPrecision;

  bool get isActiveStatus =>
      status.toLowerCase() == 'active' &&
      isInActiveMarketsList &&
      hasValidSpecifications;

  bool get isEligibleForPaperTrading =>
      eligibilityStatus == MarketEligibilityStatus.eligibleForPaperTrading;

  double? get spreadBps => latestTicker?.spreadBps;
  double? get spreadPct => latestTicker?.spreadPct;

  bool get hasValidSpecifications {
    if (symbol.isEmpty || pair.isEmpty || ecode.isEmpty) return false;
    if (baseCurrencyShortName.isEmpty || targetCurrencyShortName.isEmpty) {
      return false;
    }
    if (baseCurrencyPrecision < 0 || targetCurrencyPrecision < 0) return false;
    if (minQuantity.isNaN || minQuantity.isInfinite || minQuantity <= 0) {
      return false;
    }
    if (maxQuantity.isNaN ||
        maxQuantity.isInfinite ||
        maxQuantity < minQuantity) {
      return false;
    }
    if (step.isNaN || step.isInfinite || step <= 0) return false;
    if (minNotional.isNaN || minNotional.isInfinite || minNotional <= 0) {
      return false;
    }
    if (minPrice.isNaN || minPrice.isInfinite || minPrice < 0) return false;
    if (maxPrice.isNaN ||
        maxPrice.isInfinite ||
        (maxPrice > 0 && maxPrice < minPrice)) {
      return false;
    }
    if (orderTypes.isEmpty) return false;
    return true;
  }

  double roundQuantityToPrecision(double rawQuantity) {
    if (rawQuantity <= 0 || step <= 0) return 0.0;
    final stepped = (((rawQuantity / step) + 1e-9).floorToDouble()) * step;
    final factor = math.pow(10, targetCurrencyPrecision).toDouble();
    return ((stepped * factor + 1e-9).floorToDouble()) / factor;
  }

  double roundPriceToPrecision(double rawPrice) {
    if (rawPrice <= 0) return 0.0;
    final factor = math.pow(10, baseCurrencyPrecision).toDouble();
    return (rawPrice * factor).roundToDouble() / factor;
  }

  ({bool valid, String? reason}) validateOrder({
    required double quantity,
    required double price,
    bool isMarketOrder = false,
  }) {
    if (!hasValidSpecifications) {
      return (valid: false, reason: 'Invalid market specifications for $pair');
    }
    if (!isActiveStatus) {
      return (valid: false, reason: 'Market $pair is not active ($status)');
    }
    final roundedQty = roundQuantityToPrecision(quantity);
    if (roundedQty + 1e-12 < minQuantity) {
      return (
        valid: false,
        reason:
            'Quantity $roundedQty below min_quantity $minQuantity $targetCurrencyShortName',
      );
    }
    if (roundedQty > maxQuantity + 1e-12) {
      return (
        valid: false,
        reason:
            'Quantity $roundedQty exceeds max_quantity $maxQuantity $targetCurrencyShortName',
      );
    }
    if (isMarketOrder &&
        maxQuantityMarket > 0 &&
        roundedQty > maxQuantityMarket + 1e-12) {
      return (
        valid: false,
        reason:
            'Market order quantity $roundedQty exceeds max_quantity_market $maxQuantityMarket',
      );
    }
    if (minPrice > 0 && price < minPrice) {
      return (
        valid: false,
        reason: 'Price $price below min_price $minPrice $baseCurrencyShortName',
      );
    }
    if (maxPrice > 0 && price > maxPrice) {
      return (
        valid: false,
        reason: 'Price $price exceeds max_price $maxPrice $baseCurrencyShortName',
      );
    }
    final notional = roundedQty * price;
    if (notional + 1e-9 < minNotional) {
      return (
        valid: false,
        reason:
            'Order notional $notional below min_notional $minNotional $baseCurrencyShortName',
      );
    }
    return (valid: true, reason: null);
  }

  MarketPairMetadata toMarketPairMetadata() {
    return MarketPairMetadata(
      symbol: pair,
      baseCurrency: targetCurrencyShortName,
      quoteCurrency: baseCurrencyShortName,
      minNotionalUsdt: minNotional,
      stepSize: step,
      minQuantity: minQuantity,
      maxQuantity: maxQuantity,
      pricePrecision: baseCurrencyPrecision,
      quantityPrecision: targetCurrencyPrecision,
    );
  }

  CoinDcxMarketRecord copyWith({
    String? status,
    LiveMarketTicker? latestTicker,
    int? latestDataTimestampMs,
    int? lastMetadataRefreshMs,
    bool? isNewlyListed,
    bool? isInActiveMarketsList,
    MarketEligibilityStatus? eligibilityStatus,
    String? eligibilityReason,
  }) {
    return CoinDcxMarketRecord(
      exchangeName: exchangeName,
      coindcxName: coindcxName,
      symbol: symbol,
      pair: pair,
      ecode: ecode,
      baseCurrencyShortName: baseCurrencyShortName,
      targetCurrencyShortName: targetCurrencyShortName,
      baseCurrencyName: baseCurrencyName,
      targetCurrencyName: targetCurrencyName,
      status: status ?? this.status,
      baseCurrencyPrecision: baseCurrencyPrecision,
      targetCurrencyPrecision: targetCurrencyPrecision,
      minQuantity: minQuantity,
      maxQuantity: maxQuantity,
      maxQuantityMarket: maxQuantityMarket,
      step: step,
      minNotional: minNotional,
      minPrice: minPrice,
      maxPrice: maxPrice,
      orderTypes: orderTypes,
      latestTicker: latestTicker ?? this.latestTicker,
      latestDataTimestampMs:
          latestDataTimestampMs ?? this.latestDataTimestampMs,
      lastMetadataRefreshMs:
          lastMetadataRefreshMs ?? this.lastMetadataRefreshMs,
      isNewlyListed: isNewlyListed ?? this.isNewlyListed,
      isInActiveMarketsList:
          isInActiveMarketsList ?? this.isInActiveMarketsList,
      eligibilityStatus: eligibilityStatus ?? this.eligibilityStatus,
      eligibilityReason: eligibilityReason ?? this.eligibilityReason,
    );
  }

  Map<String, dynamic> toMap() => {
        'pair': pair,
        'exchangeName': exchangeName,
        'coindcxName': coindcxName,
        'symbol': symbol,
        'ecode': ecode,
        'baseCurrencyShortName': baseCurrencyShortName,
        'targetCurrencyShortName': targetCurrencyShortName,
        'baseCurrencyName': baseCurrencyName,
        'targetCurrencyName': targetCurrencyName,
        'status': status,
        'baseCurrencyPrecision': baseCurrencyPrecision,
        'targetCurrencyPrecision': targetCurrencyPrecision,
        'minQuantity': minQuantity,
        'maxQuantity': maxQuantity,
        'maxQuantityMarket': maxQuantityMarket,
        'step': step,
        'minNotional': minNotional,
        'minPrice': minPrice,
        'maxPrice': maxPrice,
        'orderTypesJson': jsonEncode(orderTypes),
        'latestTickerJson':
            latestTicker != null ? jsonEncode(latestTicker!.toMap()) : null,
        'latestDataTimestampMs': latestDataTimestampMs,
        'lastMetadataRefreshMs': lastMetadataRefreshMs,
        'isNewlyListed': isNewlyListed ? 1 : 0,
        'isInActiveMarketsList': isInActiveMarketsList ? 1 : 0,
        'eligibilityStatus': eligibilityStatus.name,
        'eligibilityReason': eligibilityReason,
      };

  factory CoinDcxMarketRecord.fromMap(Map<String, dynamic> map) {
    List<String> parsedOrderTypes = const [];
    final rawTypes = map['orderTypesJson'];
    if (rawTypes is String && rawTypes.isNotEmpty) {
      try {
        final decoded = jsonDecode(rawTypes);
        if (decoded is List) {
          parsedOrderTypes = decoded.map((e) => e.toString()).toList();
        }
      } catch (_) {}
    } else if (map['order_types'] is List) {
      parsedOrderTypes =
          (map['order_types'] as List).map((e) => e.toString()).toList();
    }

    LiveMarketTicker? parsedTicker;
    final rawTicker = map['latestTickerJson'];
    if (rawTicker is String && rawTicker.isNotEmpty) {
      try {
        final decoded = jsonDecode(rawTicker);
        if (decoded is Map) {
          parsedTicker =
              LiveMarketTicker.fromMap(Map<String, dynamic>.from(decoded));
        }
      } catch (_) {}
    }

    final eligName = (map['eligibilityStatus'] as String?) ??
        MarketEligibilityStatus.discovered.name;
    final elig = MarketEligibilityStatus.values.firstWhere(
      (e) => e.name == eligName,
      orElse: () => MarketEligibilityStatus.discovered,
    );

    return CoinDcxMarketRecord(
      exchangeName: (map['exchangeName'] as String?) ?? 'CoinDCX',
      coindcxName: (map['coindcxName'] as String?) ?? '',
      symbol: (map['symbol'] as String?) ?? '',
      pair: (map['pair'] as String?) ?? '',
      ecode: (map['ecode'] as String?) ?? '',
      baseCurrencyShortName: (map['baseCurrencyShortName'] as String?) ?? '',
      targetCurrencyShortName:
          (map['targetCurrencyShortName'] as String?) ?? '',
      baseCurrencyName: (map['baseCurrencyName'] as String?) ?? '',
      targetCurrencyName: (map['targetCurrencyName'] as String?) ?? '',
      status: (map['status'] as String?) ?? 'inactive',
      baseCurrencyPrecision:
          (map['baseCurrencyPrecision'] as num?)?.toInt() ?? 0,
      targetCurrencyPrecision:
          (map['targetCurrencyPrecision'] as num?)?.toInt() ?? 0,
      minQuantity: (map['minQuantity'] as num?)?.toDouble() ?? 0.0,
      maxQuantity: (map['maxQuantity'] as num?)?.toDouble() ?? 0.0,
      maxQuantityMarket:
          (map['maxQuantityMarket'] as num?)?.toDouble() ?? 0.0,
      step: (map['step'] as num?)?.toDouble() ?? 0.0,
      minNotional: (map['minNotional'] as num?)?.toDouble() ?? 0.0,
      minPrice: (map['minPrice'] as num?)?.toDouble() ?? 0.0,
      maxPrice: (map['maxPrice'] as num?)?.toDouble() ?? 0.0,
      orderTypes: parsedOrderTypes,
      latestTicker: parsedTicker,
      latestDataTimestampMs:
          (map['latestDataTimestampMs'] as num?)?.toInt(),
      lastMetadataRefreshMs:
          (map['lastMetadataRefreshMs'] as num?)?.toInt() ?? 0,
      isNewlyListed: map['isNewlyListed'] == 1 || map['isNewlyListed'] == true,
      isInActiveMarketsList: map['isInActiveMarketsList'] == null
          ? true
          : (map['isInActiveMarketsList'] == 1 ||
              map['isInActiveMarketsList'] == true),
      eligibilityStatus: elig,
      eligibilityReason: (map['eligibilityReason'] as String?) ?? '',
    );
  }
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
  final String portfolioId;
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
    this.portfolioId = 'CRYPTO',
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
        'portfolioId': portfolioId,
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
        portfolioId: (map['portfolioId'] as String?) ?? 'CRYPTO',
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
  final String portfolioId;
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
    this.portfolioId = 'CRYPTO',
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
        'portfolioId': portfolioId,
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
        portfolioId: (map['portfolioId'] as String?) ?? 'CRYPTO',
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
  final String portfolioId;
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
    this.portfolioId = 'CRYPTO',
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
        'portfolioId': portfolioId,
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
        portfolioId: (map['portfolioId'] as String?) ?? 'CRYPTO',
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

class DiagnosticEvent {
  final int id;
  final int timestampMs;
  final String eventType;
  final String reason;

  const DiagnosticEvent({
    required this.id,
    required this.timestampMs,
    required this.eventType,
    required this.reason,
  });

  Map<String, dynamic> toMap() => {
        'id': id,
        'timestampMs': timestampMs,
        'eventType': eventType,
        'reason': reason,
      };

  factory DiagnosticEvent.fromMap(Map<String, dynamic> map) => DiagnosticEvent(
        id: (map['id'] as num?)?.toInt() ?? 0,
        timestampMs: (map['timestampMs'] as num?)?.toInt() ?? 0,
        eventType: (map['eventType'] as String?) ?? 'INFO',
        reason: (map['reason'] as String?) ?? '',
      );
}

class EquityPoint {
  final int timestampMs;
  final double equityUsdt;
  final String portfolioId;

  const EquityPoint({
    required this.timestampMs,
    required this.equityUsdt,
    this.portfolioId = 'CRYPTO',
  });
}

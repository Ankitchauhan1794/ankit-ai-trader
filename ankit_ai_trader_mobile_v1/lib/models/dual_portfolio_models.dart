import 'trading_models.dart';

/// Canonical identifier for the two completely independent portfolios.
enum PortfolioId {
  crypto,
  highVolatility,
}

extension PortfolioIdMetadata on PortfolioId {
  String get dbKey =>
      this == PortfolioId.crypto ? 'CRYPTO' : 'HIGH_VOLATILITY';

  String get displayName => this == PortfolioId.crypto
      ? 'CRYPTO PORTFOLIO'
      : 'HIGH-VOLATILITY PORTFOLIO';

  String get shortLabel =>
      this == PortfolioId.crypto ? 'Crypto' : 'High-Volatility';

  String get subtitleDescription => this == PortfolioId.crypto
      ? 'CoinDCX Spot Crypto • Paper Execution Active'
      : 'High-Vol Crypto & Precious Metals (XAUUSD/XAGUSD) • Research-Only';

  static PortfolioId fromKey(String? raw) {
    if (raw == null) return PortfolioId.crypto;
    final normalized = raw.trim().toUpperCase();
    if (normalized == 'HIGH_VOLATILITY' ||
        normalized == 'HIGHVOLATILITY' ||
        normalized == 'PORTFOLIO_B') {
      return PortfolioId.highVolatility;
    }
    return PortfolioId.crypto;
  }
}

/// Asset sub-category within the Dual Portfolio Architecture.
enum PortfolioAssetCategory {
  standardCryptoSpot,
  highVolatilityCryptoSpot,
  preciousMetalSpotCfd,
}

/// Verification state of an instrument and its market-data provider.
enum InstrumentVerificationStatus {
  verifiedTradableInPaper,
  verifiedResearchOnly,
  unverifiedProviderPending,
  rejectedInvalidSpecs,
  rejectedIlliquidOrWideSpread,
  rejectedInsufficientHistory,
  rejectedStaleOrIncompleteData,
}

/// Section 5: Verified Instrument Specification (never fabricates missing fields).
class VerifiedInstrumentSpecification {
  final String symbol;
  final String canonicalPair;
  final String providerId;
  final String baseCurrency;
  final String quoteCurrency;
  final PortfolioAssetCategory category;
  final double? contractSize;
  final double? minQuantity;
  final double? maxQuantity;
  final double? quantityStep;
  final double? tickSize;
  final double? tickValue;
  final double? minNotional;
  final double? currentSpreadBps;
  final double? makerFeeRate;
  final double? takerFeeRate;
  final double? swapLongRate;
  final double? swapShortRate;
  final double? marginRequirementFraction;
  final List<String> tradingSessions;
  final List<String> supportedOrderTypes;
  final bool isProviderConnected;
  final bool isSpecificationVerified;
  final bool isExecutionAuthorized;
  final String statusNote;

  const VerifiedInstrumentSpecification({
    required this.symbol,
    required this.canonicalPair,
    required this.providerId,
    required this.baseCurrency,
    required this.quoteCurrency,
    required this.category,
    this.contractSize,
    this.minQuantity,
    this.maxQuantity,
    this.quantityStep,
    this.tickSize,
    this.tickValue,
    this.minNotional,
    this.currentSpreadBps,
    this.makerFeeRate,
    this.takerFeeRate,
    this.swapLongRate,
    this.swapShortRate,
    this.marginRequirementFraction,
    this.tradingSessions = const [],
    this.supportedOrderTypes = const [],
    required this.isProviderConnected,
    required this.isSpecificationVerified,
    required this.isExecutionAuthorized,
    required this.statusNote,
  });

  bool get hasCompleteQuantitativeSpecs =>
      isProviderConnected &&
      isSpecificationVerified &&
      contractSize != null &&
      contractSize! > 0 &&
      minQuantity != null &&
      minQuantity! > 0 &&
      quantityStep != null &&
      quantityStep! > 0 &&
      tickSize != null &&
      tickSize! > 0 &&
      minNotional != null &&
      minNotional! > 0 &&
      takerFeeRate != null &&
      takerFeeRate! >= 0 &&
      supportedOrderTypes.isNotEmpty;
}

/// Section 4: Configurable and documented High-Volatility Market Classification Criteria.
class HighVolatilityClassificationCriteria {
  final double minAtrPct;
  final double maxAtrPct;
  final double minRealizedVolatilityPct;
  final double min24hPriceMovePct;
  final double min24hVolumeQuote;
  final double maxSpreadBps;
  final int minClosedCandlesRequired;
  final int maxDataAgeMs;

  const HighVolatilityClassificationCriteria({
    this.minAtrPct = 1.20,
    this.maxAtrPct = 6.00,
    this.minRealizedVolatilityPct = 0.85,
    this.min24hPriceMovePct = 2.00,
    this.min24hVolumeQuote = 50000.0,
    this.maxSpreadBps = 35.0,
    this.minClosedCandlesRequired = 30,
    this.maxDataAgeMs = 120000,
  });
}

/// Section 4: Evaluation result produced by HighVolatilityMarketClassifier.
class HighVolatilityClassificationResult {
  final String symbol;
  final String pair;
  final PortfolioAssetCategory category;
  final bool qualifiesAsHighVolatility;
  final bool isResearchEligible;
  final bool isExecutionAuthorized;
  final InstrumentVerificationStatus verificationStatus;
  final double? atrPct;
  final double? realizedVolatilityPct;
  final double? change24hPct;
  final double? volume24h;
  final double? spreadBps;
  final int availableCandlesCount;
  final bool isDataFresh;
  final bool hasValidSpecs;
  final String classificationReason;

  const HighVolatilityClassificationResult({
    required this.symbol,
    required this.pair,
    required this.category,
    required this.qualifiesAsHighVolatility,
    required this.isResearchEligible,
    required this.isExecutionAuthorized,
    required this.verificationStatus,
    this.atrPct,
    this.realizedVolatilityPct,
    this.change24hPct,
    this.volume24h,
    this.spreadBps,
    required this.availableCandlesCount,
    required this.isDataFresh,
    required this.hasValidSpecs,
    required this.classificationReason,
  });
}

/// Section 8: Eight-stage strategy improvement governance pipeline stage.
enum StrategyGovernancePipelineStage {
  research,
  candidateCreation,
  backtesting,
  outOfSampleTesting,
  walkForwardValidation,
  paperShadowValidation,
  humanApprovalRequired,
  controlledPromotion,
}

/// Section 8: Portfolio-specific AI Learning Context (never mixes across portfolios).
class PortfolioLearningContext {
  final PortfolioId portfolioId;
  final String activeStrategyId;
  final String activeStrategyVersion;
  final int evaluatedClosedTradesCount;
  final int observedWinningTrades;
  final int observedLosingTrades;
  final double cumulativeRealizedPnlUsdt;
  final Map<String, int> regimeObservationsCount;
  final Map<String, double> symbolRealizedPnlMap;
  final List<String> learningInsights;
  final StrategyGovernancePipelineStage currentPipelineStage;
  final bool autoStrategyTransferBlocked;
  final bool autoDeployOnSingleTradeBlocked;
  final bool preciousMetalsDataReady;

  const PortfolioLearningContext({
    required this.portfolioId,
    required this.activeStrategyId,
    this.activeStrategyVersion = '1.0.0',
    this.evaluatedClosedTradesCount = 0,
    this.observedWinningTrades = 0,
    this.observedLosingTrades = 0,
    this.cumulativeRealizedPnlUsdt = 0.0,
    this.regimeObservationsCount = const {},
    this.symbolRealizedPnlMap = const {},
    this.learningInsights = const [],
    this.currentPipelineStage = StrategyGovernancePipelineStage.research,
    this.autoStrategyTransferBlocked = true,
    this.autoDeployOnSingleTradeBlocked = true,
    this.preciousMetalsDataReady = false,
  });

  double get winRatePct => evaluatedClosedTradesCount > 0
      ? (observedWinningTrades / evaluatedClosedTradesCount) * 100.0
      : 0.0;
}

/// Section 3: Complete, isolated snapshot of a single portfolio's account, risk, positions, history & settings.
class PortfolioAccountSnapshot {
  final PortfolioId portfolioId;
  final String displayName;
  final double startingBalanceUsdt;
  final double availableCashUsdt;
  final double accountEquityUsdt;
  final double startOfDayEquityUsdt;
  final double realizedPnlUsdt;
  final double unrealizedPnlUsdt;
  final bool maxDrawdownLocked;
  final String? lockedDailyLossUtcDate;
  final int? lastStopLossClosedAtMs;
  final int consecutiveLosses;
  final bool executionEnabled;
  final bool isResearchOnlyMode;
  final bool liveTradingLocked;
  final String activeStrategyId;
  final int configuredMaxOpenPositions;
  final int architecturalMaxPositionCapacity;
  final List<PaperPosition> openPositions;
  final List<SimulatedOrder> orders;
  final List<ClosedPaperTrade> closedTrades;
  final List<EquityPoint> equityCurve;
  final double totalDepositsUsdt;
  final double totalWithdrawalsUsdt;
  final PortfolioLearningContext learningContext;
  final String statusSummary;
  final int updatedAtMs;

  const PortfolioAccountSnapshot({
    required this.portfolioId,
    required this.displayName,
    this.startingBalanceUsdt = 100.0,
    this.availableCashUsdt = 100.0,
    this.accountEquityUsdt = 100.0,
    this.startOfDayEquityUsdt = 100.0,
    this.realizedPnlUsdt = 0.0,
    this.unrealizedPnlUsdt = 0.0,
    this.maxDrawdownLocked = false,
    this.lockedDailyLossUtcDate,
    this.lastStopLossClosedAtMs,
    this.consecutiveLosses = 0,
    required this.executionEnabled,
    required this.isResearchOnlyMode,
    this.liveTradingLocked = true,
    this.activeStrategyId = 'EMA_20_50_RSI_ATR_V1',
    this.configuredMaxOpenPositions = 1,
    this.architecturalMaxPositionCapacity = 5,
    this.openPositions = const [],
    this.orders = const [],
    this.closedTrades = const [],
    this.equityCurve = const [],
    this.totalDepositsUsdt = 0.0,
    this.totalWithdrawalsUsdt = 0.0,
    required this.learningContext,
    required this.statusSummary,
    this.updatedAtMs = 0,
  });

  double get dailyPnlUsdt => accountEquityUsdt - startOfDayEquityUsdt;

  double get overallPnlUsdt =>
      accountEquityUsdt -
      startingBalanceUsdt -
      totalDepositsUsdt +
      totalWithdrawalsUsdt;

  double get currentDrawdownUsdt =>
      (startingBalanceUsdt - accountEquityUsdt).clamp(0.0, startingBalanceUsdt);

  double get usedMarginUsdt => openPositions.fold<double>(
        0.0,
        (acc, p) => acc + p.investedNotionalUsdt,
      );

  double get freeMarginUsdt =>
      (accountEquityUsdt - usedMarginUsdt).clamp(0.0, double.infinity);

  double get remainingDailyRiskBudgetUsdt {
    final usedLoss =
        (startOfDayEquityUsdt - accountEquityUsdt).clamp(0.0, 2.0);
    return (2.0 - usedLoss).clamp(0.0, 2.0);
  }

  double get remainingDrawdownBudgetUsdt =>
      (accountEquityUsdt - (startingBalanceUsdt - 10.0)).clamp(0.0, 10.0);

  int get winningTradesCount =>
      closedTrades.where((t) => t.realizedPnlUsdt >= 0).length;

  int get losingTradesCount =>
      closedTrades.where((t) => t.realizedPnlUsdt < 0).length;

  double get winRatePct => closedTrades.isNotEmpty
      ? (winningTradesCount / closedTrades.length) * 100.0
      : 0.0;

  PortfolioAccountSnapshot copyWith({
    double? startingBalanceUsdt,
    double? availableCashUsdt,
    double? accountEquityUsdt,
    double? startOfDayEquityUsdt,
    double? realizedPnlUsdt,
    double? unrealizedPnlUsdt,
    bool? maxDrawdownLocked,
    String? lockedDailyLossUtcDate,
    int? lastStopLossClosedAtMs,
    int? consecutiveLosses,
    bool? executionEnabled,
    bool? isResearchOnlyMode,
    String? activeStrategyId,
    int? configuredMaxOpenPositions,
    List<PaperPosition>? openPositions,
    List<SimulatedOrder>? orders,
    List<ClosedPaperTrade>? closedTrades,
    List<EquityPoint>? equityCurve,
    double? totalDepositsUsdt,
    double? totalWithdrawalsUsdt,
    PortfolioLearningContext? learningContext,
    String? statusSummary,
    int? updatedAtMs,
  }) {
    return PortfolioAccountSnapshot(
      portfolioId: portfolioId,
      displayName: displayName,
      startingBalanceUsdt: startingBalanceUsdt ?? this.startingBalanceUsdt,
      availableCashUsdt: availableCashUsdt ?? this.availableCashUsdt,
      accountEquityUsdt: accountEquityUsdt ?? this.accountEquityUsdt,
      startOfDayEquityUsdt: startOfDayEquityUsdt ?? this.startOfDayEquityUsdt,
      realizedPnlUsdt: realizedPnlUsdt ?? this.realizedPnlUsdt,
      unrealizedPnlUsdt: unrealizedPnlUsdt ?? this.unrealizedPnlUsdt,
      maxDrawdownLocked: maxDrawdownLocked ?? this.maxDrawdownLocked,
      lockedDailyLossUtcDate:
          lockedDailyLossUtcDate ?? this.lockedDailyLossUtcDate,
      lastStopLossClosedAtMs:
          lastStopLossClosedAtMs ?? this.lastStopLossClosedAtMs,
      consecutiveLosses: consecutiveLosses ?? this.consecutiveLosses,
      executionEnabled: executionEnabled ?? this.executionEnabled,
      isResearchOnlyMode: isResearchOnlyMode ?? this.isResearchOnlyMode,
      liveTradingLocked: true,
      activeStrategyId: activeStrategyId ?? this.activeStrategyId,
      configuredMaxOpenPositions:
          configuredMaxOpenPositions ?? this.configuredMaxOpenPositions,
      architecturalMaxPositionCapacity: architecturalMaxPositionCapacity,
      openPositions: openPositions ?? this.openPositions,
      orders: orders ?? this.orders,
      closedTrades: closedTrades ?? this.closedTrades,
      equityCurve: equityCurve ?? this.equityCurve,
      totalDepositsUsdt: totalDepositsUsdt ?? this.totalDepositsUsdt,
      totalWithdrawalsUsdt: totalWithdrawalsUsdt ?? this.totalWithdrawalsUsdt,
      learningContext: learningContext ?? this.learningContext,
      statusSummary: statusSummary ?? this.statusSummary,
      updatedAtMs: updatedAtMs ?? this.updatedAtMs,
    );
  }

  Map<String, dynamic> toDbRow() => {
        'portfolioId': portfolioId.dbKey,
        'displayName': displayName,
        'startingBalanceUsdt': startingBalanceUsdt,
        'availableCashUsdt': availableCashUsdt,
        'accountEquityUsdt': accountEquityUsdt,
        'startOfDayEquityUsdt': startOfDayEquityUsdt,
        'realizedPnlUsdt': realizedPnlUsdt,
        'maxDrawdownLocked': maxDrawdownLocked ? 1 : 0,
        'lockedDailyLossUtcDate': lockedDailyLossUtcDate,
        'lastStopLossClosedAtMs': lastStopLossClosedAtMs,
        'consecutiveLosses': consecutiveLosses,
        'executionEnabled': executionEnabled ? 1 : 0,
        'isResearchOnly': isResearchOnlyMode ? 1 : 0,
        'activeStrategyId': activeStrategyId,
        'maxOpenPositions': configuredMaxOpenPositions,
        'updatedAtMs': updatedAtMs,
      };
}

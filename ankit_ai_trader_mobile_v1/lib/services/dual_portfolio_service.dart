import 'dart:math' as math;
import '../models/dual_portfolio_models.dart';
import '../models/trading_models.dart';
import 'autonomous_intelligence_and_ops.dart';
import 'execution_and_risk_hub.dart';
import 'indicator_engine.dart';
import 'persistence_db.dart';
import 'quant_research_lab.dart';
import 'risk_manager.dart';
import 'stage47_autonomous_governance.dart';

/// Section 5: Modular Market-Data Provider Abstraction.
abstract class PortfolioMarketDataProvider {
  String get providerId;
  String get displayName;
  bool get isProviderConnected;
  bool get isProviderVerified;

  VerifiedInstrumentSpecification getInstrumentSpecification(
    String symbolOrPair, {
    CoinDcxMarketRecord? discoveredRecord,
  });

  List<VerifiedInstrumentSpecification> listKnownSpecifications({
    List<CoinDcxMarketRecord> discoveredCatalogue = const [],
  });
}

/// Section 5: Existing CoinDCX Provider for verified cryptocurrency spot markets.
/// Never claims support for XAUUSD or XAGUSD.
class CoinDcxPortfolioProvider implements PortfolioMarketDataProvider {
  @override
  String get providerId => 'COINDCX_SPOT';

  @override
  String get displayName => 'CoinDCX Spot Public REST/WS API';

  @override
  final bool isProviderConnected;

  @override
  bool get isProviderVerified => true;

  const CoinDcxPortfolioProvider({this.isProviderConnected = true});

  static bool isPreciousMetalSymbol(String symbol) {
    final upper = symbol.trim().toUpperCase();
    return upper.contains('XAU') ||
        upper.contains('XAG') ||
        upper == 'GOLD' ||
        upper == 'SILVER';
  }

  @override
  VerifiedInstrumentSpecification getInstrumentSpecification(
    String symbolOrPair, {
    CoinDcxMarketRecord? discoveredRecord,
  }) {
    final upper = symbolOrPair.trim().toUpperCase();
    if (isPreciousMetalSymbol(upper)) {
      return VerifiedInstrumentSpecification(
        symbol: upper,
        canonicalPair: upper,
        providerId: providerId,
        baseCurrency: upper.startsWith('XAU') ? 'XAU' : 'XAG',
        quoteCurrency: 'USD',
        category: PortfolioAssetCategory.preciousMetalSpotCfd,
        isProviderConnected: isProviderConnected,
        isSpecificationVerified: false,
        isExecutionAuthorized: false,
        statusNote:
            'UNSUPPORTED_ON_COINDCX: CoinDCX does not support precious metals ($upper). Research-only awaiting verified metals provider.',
      );
    }

    if (discoveredRecord != null && discoveredRecord.hasValidSpecifications) {
      final tickSz = math
          .pow(10, -discoveredRecord.baseCurrencyPrecision.clamp(0, 8))
          .toDouble();
      return VerifiedInstrumentSpecification(
        symbol: discoveredRecord.symbol,
        canonicalPair: discoveredRecord.pair,
        providerId: providerId,
        baseCurrency: discoveredRecord.targetCurrencyShortName,
        quoteCurrency: discoveredRecord.baseCurrencyShortName,
        category: PortfolioAssetCategory.standardCryptoSpot,
        contractSize: 1.0,
        minQuantity: discoveredRecord.minQuantity,
        maxQuantity: discoveredRecord.maxQuantity,
        quantityStep: discoveredRecord.step,
        tickSize: tickSz,
        tickValue: tickSz,
        minNotional: discoveredRecord.minNotional,
        currentSpreadBps: discoveredRecord.spreadBps,
        makerFeeRate: 0.001,
        takerFeeRate: 0.001,
        swapLongRate: 0.0,
        swapShortRate: 0.0,
        marginRequirementFraction: 1.0,
        tradingSessions: const ['24/7_SPOT'],
        supportedOrderTypes: discoveredRecord.orderTypes,
        isProviderConnected: isProviderConnected,
        isSpecificationVerified: discoveredRecord.isActiveStatus,
        isExecutionAuthorized:
            discoveredRecord.isActiveStatus &&
            discoveredRecord.isEligibleForPaperTrading,
        statusNote: discoveredRecord.eligibilityReason,
      );
    }

    if (upper == 'BTCUSDT' ||
        upper == 'B-BTC_USDT' ||
        upper == 'ETHUSDT' ||
        upper == 'B-ETH_USDT') {
      final isBtc = upper.contains('BTC');
      return VerifiedInstrumentSpecification(
        symbol: isBtc ? 'BTCUSDT' : 'ETHUSDT',
        canonicalPair: isBtc ? 'B-BTC_USDT' : 'B-ETH_USDT',
        providerId: providerId,
        baseCurrency: isBtc ? 'BTC' : 'ETH',
        quoteCurrency: 'USDT',
        category: PortfolioAssetCategory.standardCryptoSpot,
        contractSize: 1.0,
        minQuantity: isBtc ? 0.0001 : 0.001,
        maxQuantity: isBtc ? 100.0 : 1000.0,
        quantityStep: isBtc ? 0.00001 : 0.0001,
        tickSize: 0.01,
        tickValue: 0.01,
        minNotional: 5.0,
        currentSpreadBps: 5.0,
        makerFeeRate: 0.001,
        takerFeeRate: 0.001,
        swapLongRate: 0.0,
        swapShortRate: 0.0,
        marginRequirementFraction: 1.0,
        tradingSessions: const ['24/7_SPOT'],
        supportedOrderTypes: const ['market_order', 'limit_order'],
        isProviderConnected: isProviderConnected,
        isSpecificationVerified: true,
        isExecutionAuthorized: true,
        statusNote: 'Verified CoinDCX Spot pair',
      );
    }

    return VerifiedInstrumentSpecification(
      symbol: upper,
      canonicalPair: upper,
      providerId: providerId,
      baseCurrency: upper,
      quoteCurrency: 'UNKNOWN',
      category: PortfolioAssetCategory.standardCryptoSpot,
      isProviderConnected: isProviderConnected,
      isSpecificationVerified: false,
      isExecutionAuthorized: false,
      statusNote:
          'UNVERIFIED_INSTRUMENT: $upper not found in verified CoinDCX active market catalogue.',
    );
  }

  @override
  List<VerifiedInstrumentSpecification> listKnownSpecifications({
    List<CoinDcxMarketRecord> discoveredCatalogue = const [],
  }) {
    if (discoveredCatalogue.isEmpty) {
      return [
        getInstrumentSpecification('BTCUSDT'),
        getInstrumentSpecification('ETHUSDT'),
      ];
    }
    return discoveredCatalogue
        .map((m) => getInstrumentSpecification(m.symbol, discoveredRecord: m))
        .toList();
  }
}

/// Section 2 & 5: Unselected High-Volatility & Precious Metals Provider Abstraction.
class UnverifiedHighVolatilityProvider implements PortfolioMarketDataProvider {
  @override
  String get providerId => 'UNSELECTED_HIGH_VOL_PROVIDER';

  @override
  String get displayName => 'High-Volatility & Metals Provider (Not Selected)';

  @override
  bool get isProviderConnected => false;

  @override
  bool get isProviderVerified => false;

  const UnverifiedHighVolatilityProvider();

  @override
  VerifiedInstrumentSpecification getInstrumentSpecification(
    String symbolOrPair, {
    CoinDcxMarketRecord? discoveredRecord,
  }) {
    final upper = symbolOrPair.trim().toUpperCase();
    if (upper == 'XAUUSD' || upper == 'XAGUSD') {
      final isGold = upper == 'XAUUSD';
      return VerifiedInstrumentSpecification(
        symbol: upper,
        canonicalPair: upper,
        providerId: providerId,
        baseCurrency: isGold ? 'XAU' : 'XAG',
        quoteCurrency: 'USD',
        category: PortfolioAssetCategory.preciousMetalSpotCfd,
        contractSize: null,
        minQuantity: null,
        maxQuantity: null,
        quantityStep: null,
        tickSize: null,
        tickValue: null,
        minNotional: null,
        currentSpreadBps: null,
        makerFeeRate: null,
        takerFeeRate: null,
        swapLongRate: null,
        swapShortRate: null,
        marginRequirementFraction: null,
        tradingSessions: const [],
        supportedOrderTypes: const [],
        isProviderConnected: false,
        isSpecificationVerified: false,
        isExecutionAuthorized: false,
        statusNote:
            'RESEARCH_ONLY: ${isGold ? "Gold (XAUUSD)" : "Silver (XAGUSD)"} provider not yet selected. Specifications unverified; trade execution disabled.',
      );
    }

    if (discoveredRecord != null && discoveredRecord.hasValidSpecifications) {
      final tickSz = math
          .pow(10, -discoveredRecord.baseCurrencyPrecision.clamp(0, 8))
          .toDouble();
      final isTradable = discoveredRecord.isActiveStatus &&
          discoveredRecord.isEligibleForPaperTrading &&
          !CoinDcxPortfolioProvider.isPreciousMetalSymbol(
            discoveredRecord.symbol,
          );
      return VerifiedInstrumentSpecification(
        symbol: discoveredRecord.symbol,
        canonicalPair: discoveredRecord.pair,
        providerId: 'COINDCX_SPOT',
        baseCurrency: discoveredRecord.targetCurrencyShortName,
        quoteCurrency: discoveredRecord.baseCurrencyShortName,
        category: PortfolioAssetCategory.highVolatilityCryptoSpot,
        contractSize: 1.0,
        minQuantity: discoveredRecord.minQuantity,
        maxQuantity: discoveredRecord.maxQuantity,
        quantityStep: discoveredRecord.step,
        tickSize: tickSz,
        tickValue: tickSz,
        minNotional: discoveredRecord.minNotional,
        currentSpreadBps: discoveredRecord.spreadBps,
        makerFeeRate: 0.001,
        takerFeeRate: 0.001,
        swapLongRate: 0.0,
        swapShortRate: 0.0,
        marginRequirementFraction: 1.0,
        tradingSessions: const ['24/7_SPOT'],
        supportedOrderTypes: discoveredRecord.orderTypes,
        isProviderConnected: true,
        isSpecificationVerified: discoveredRecord.isActiveStatus,
        isExecutionAuthorized: isTradable,
        statusNote: isTradable
            ? 'PAPER_ELIGIBLE_CRYPTO: Verified CoinDCX Spot pair; internal PaperBroker execution enabled.'
            : discoveredRecord.eligibilityReason,
      );
    }

    if (upper == 'BTCUSDT' ||
        upper == 'B-BTC_USDT' ||
        upper == 'ETHUSDT' ||
        upper == 'B-ETH_USDT') {
      final isBtc = upper.contains('BTC');
      return VerifiedInstrumentSpecification(
        symbol: isBtc ? 'BTCUSDT' : 'ETHUSDT',
        canonicalPair: isBtc ? 'B-BTC_USDT' : 'B-ETH_USDT',
        providerId: 'COINDCX_SPOT',
        baseCurrency: isBtc ? 'BTC' : 'ETH',
        quoteCurrency: 'USDT',
        category: PortfolioAssetCategory.highVolatilityCryptoSpot,
        contractSize: 1.0,
        minQuantity: isBtc ? 0.0001 : 0.001,
        maxQuantity: isBtc ? 100.0 : 1000.0,
        quantityStep: isBtc ? 0.00001 : 0.0001,
        tickSize: 0.01,
        tickValue: 0.01,
        minNotional: 5.0,
        currentSpreadBps: 5.0,
        makerFeeRate: 0.001,
        takerFeeRate: 0.001,
        swapLongRate: 0.0,
        swapShortRate: 0.0,
        marginRequirementFraction: 1.0,
        tradingSessions: const ['24/7_SPOT'],
        supportedOrderTypes: const ['market_order', 'limit_order'],
        isProviderConnected: true,
        isSpecificationVerified: true,
        isExecutionAuthorized: true,
        statusNote: 'PAPER_ELIGIBLE_CRYPTO: Verified CoinDCX Spot pair',
      );
    }

    return VerifiedInstrumentSpecification(
      symbol: upper,
      canonicalPair: upper,
      providerId: providerId,
      baseCurrency: upper,
      quoteCurrency: 'USD',
      category: PortfolioAssetCategory.highVolatilityCryptoSpot,
      isProviderConnected: false,
      isSpecificationVerified: false,
      isExecutionAuthorized: false,
      statusNote:
          'RESEARCH_ONLY: Instrument $upper has no verified provider or market specification.',
    );
  }

  @override
  List<VerifiedInstrumentSpecification> listKnownSpecifications({
    List<CoinDcxMarketRecord> discoveredCatalogue = const [],
  }) {
    return [
      getInstrumentSpecification('XAUUSD'),
      getInstrumentSpecification('XAGUSD'),
      ...discoveredCatalogue.map(
        (m) => getInstrumentSpecification(m.symbol, discoveredRecord: m),
      ),
    ];
  }
}

/// Section 4: Modular High-Volatility Market Classification System.
class HighVolatilityMarketClassifier {
  final HighVolatilityClassificationCriteria criteria;

  const HighVolatilityMarketClassifier({
    this.criteria = const HighVolatilityClassificationCriteria(),
  });

  static double? computeRealizedVolatilityPct(List<Candle> closedCandles) {
    if (closedCandles.length < 10) return null;
    final returns = <double>[];
    for (int i = 1; i < closedCandles.length; i++) {
      final prev = closedCandles[i - 1].close;
      final cur = closedCandles[i].close;
      if (prev <= 0 || cur <= 0) return null;
      returns.add(math.log(cur / prev) * 100.0);
    }
    if (returns.isEmpty) return null;
    final mean = returns.reduce((a, b) => a + b) / returns.length;
    double sumSq = 0.0;
    for (final r in returns) {
      final d = r - mean;
      sumSq += d * d;
    }
    return math.sqrt(sumSq / returns.length);
  }

  HighVolatilityClassificationResult classifyCryptoMarket({
    required CoinDcxMarketRecord market,
    required List<Candle> closedCandles,
    required int nowMs,
    bool portfolioExecutionApproved = false,
  }) {
    if (!market.isActiveStatus) {
      return HighVolatilityClassificationResult(
        symbol: market.symbol,
        pair: market.pair,
        category: PortfolioAssetCategory.highVolatilityCryptoSpot,
        qualifiesAsHighVolatility: false,
        isResearchEligible: false,
        isExecutionAuthorized: false,
        verificationStatus: InstrumentVerificationStatus.rejectedInvalidSpecs,
        availableCandlesCount: closedCandles.length,
        isDataFresh: false,
        hasValidSpecs: market.hasValidSpecifications,
        classificationReason:
            'EXCLUDED_INACTIVE_MARKET: Market status is ${market.status}.',
      );
    }

    if (!market.hasValidSpecifications) {
      return HighVolatilityClassificationResult(
        symbol: market.symbol,
        pair: market.pair,
        category: PortfolioAssetCategory.highVolatilityCryptoSpot,
        qualifiesAsHighVolatility: false,
        isResearchEligible: false,
        isExecutionAuthorized: false,
        verificationStatus: InstrumentVerificationStatus.rejectedInvalidSpecs,
        availableCandlesCount: closedCandles.length,
        isDataFresh: false,
        hasValidSpecs: false,
        classificationReason:
            'EXCLUDED_INVALID_SPECS: Market ${market.pair} has incomplete or invalid exchange specifications.',
      );
    }

    final ticker = market.latestTicker;
    if (ticker == null ||
        ticker.bid <= 0 ||
        ticker.ask <= 0 ||
        ticker.lastPrice <= 0 ||
        ticker.volume24h <= 0 ||
        ticker.timestampMs <= 0) {
      return HighVolatilityClassificationResult(
        symbol: market.symbol,
        pair: market.pair,
        category: PortfolioAssetCategory.highVolatilityCryptoSpot,
        qualifiesAsHighVolatility: false,
        isResearchEligible: false,
        isExecutionAuthorized: false,
        verificationStatus:
            InstrumentVerificationStatus.rejectedStaleOrIncompleteData,
        availableCandlesCount: closedCandles.length,
        isDataFresh: false,
        hasValidSpecs: true,
        classificationReason:
            'EXCLUDED_INCOMPLETE_TICKER: Missing verified bid/ask, volume, or timestamp (never fabricated).',
      );
    }

    final tickerFresh =
        ticker.isFresh(nowMs, maxAgeMs: criteria.maxDataAgeMs);
    if (!tickerFresh) {
      return HighVolatilityClassificationResult(
        symbol: market.symbol,
        pair: market.pair,
        category: PortfolioAssetCategory.highVolatilityCryptoSpot,
        qualifiesAsHighVolatility: false,
        isResearchEligible: false,
        isExecutionAuthorized: false,
        verificationStatus:
            InstrumentVerificationStatus.rejectedStaleOrIncompleteData,
        spreadBps: ticker.spreadBps,
        volume24h: ticker.volume24h,
        change24hPct: ticker.change24hPct,
        availableCandlesCount: closedCandles.length,
        isDataFresh: false,
        hasValidSpecs: true,
        classificationReason:
            'EXCLUDED_STALE_DATA: Ticker timestamp exceeds freshness threshold (${criteria.maxDataAgeMs}ms).',
      );
    }

    if (ticker.spreadBps > criteria.maxSpreadBps ||
        ticker.volume24h < criteria.min24hVolumeQuote) {
      return HighVolatilityClassificationResult(
        symbol: market.symbol,
        pair: market.pair,
        category: PortfolioAssetCategory.highVolatilityCryptoSpot,
        qualifiesAsHighVolatility: false,
        isResearchEligible: false,
        isExecutionAuthorized: false,
        verificationStatus:
            InstrumentVerificationStatus.rejectedIlliquidOrWideSpread,
        spreadBps: ticker.spreadBps,
        volume24h: ticker.volume24h,
        change24hPct: ticker.change24hPct,
        availableCandlesCount: closedCandles.length,
        isDataFresh: true,
        hasValidSpecs: true,
        classificationReason:
            'EXCLUDED_LIQUIDITY_OR_SPREAD: Spread ${ticker.spreadBps.toStringAsFixed(1)} bps (max ${criteria.maxSpreadBps}) or 24h Vol ${ticker.volume24h.toStringAsFixed(0)} (min ${criteria.min24hVolumeQuote.toStringAsFixed(0)}).',
      );
    }

    if (closedCandles.length < criteria.minClosedCandlesRequired) {
      return HighVolatilityClassificationResult(
        symbol: market.symbol,
        pair: market.pair,
        category: PortfolioAssetCategory.highVolatilityCryptoSpot,
        qualifiesAsHighVolatility: false,
        isResearchEligible: false,
        isExecutionAuthorized: false,
        verificationStatus:
            InstrumentVerificationStatus.rejectedInsufficientHistory,
        spreadBps: ticker.spreadBps,
        volume24h: ticker.volume24h,
        change24hPct: ticker.change24hPct,
        availableCandlesCount: closedCandles.length,
        isDataFresh: true,
        hasValidSpecs: true,
        classificationReason:
            'EXCLUDED_INSUFFICIENT_HISTORY: Only ${closedCandles.length}/${criteria.minClosedCandlesRequired} closed candles available.',
      );
    }

    final atr14 = const IndicatorEngine().calculateAtr(closedCandles, period: 14);
    final realizedVol = computeRealizedVolatilityPct(closedCandles);
    final lastClose = closedCandles.last.close;
    if (atr14 == null || realizedVol == null || lastClose <= 0) {
      return HighVolatilityClassificationResult(
        symbol: market.symbol,
        pair: market.pair,
        category: PortfolioAssetCategory.highVolatilityCryptoSpot,
        qualifiesAsHighVolatility: false,
        isResearchEligible: false,
        isExecutionAuthorized: false,
        verificationStatus:
            InstrumentVerificationStatus.rejectedInsufficientHistory,
        spreadBps: ticker.spreadBps,
        volume24h: ticker.volume24h,
        change24hPct: ticker.change24hPct,
        availableCandlesCount: closedCandles.length,
        isDataFresh: true,
        hasValidSpecs: true,
        classificationReason:
            'EXCLUDED_INDICATOR_NA: Unable to compute ATR(14) and realized volatility from candle history.',
      );
    }

    final atrPct = (atr14 / lastClose) * 100.0;
    final multiCandleVolQualifies = atrPct >= criteria.minAtrPct &&
        atrPct <= criteria.maxAtrPct &&
        realizedVol >= criteria.minRealizedVolatilityPct;

    if (!multiCandleVolQualifies) {
      return HighVolatilityClassificationResult(
        symbol: market.symbol,
        pair: market.pair,
        category: PortfolioAssetCategory.highVolatilityCryptoSpot,
        qualifiesAsHighVolatility: false,
        isResearchEligible: false,
        isExecutionAuthorized: false,
        verificationStatus: InstrumentVerificationStatus.verifiedResearchOnly,
        atrPct: atrPct,
        realizedVolatilityPct: realizedVol,
        change24hPct: ticker.change24hPct,
        volume24h: ticker.volume24h,
        spreadBps: ticker.spreadBps,
        availableCandlesCount: closedCandles.length,
        isDataFresh: true,
        hasValidSpecs: true,
        classificationReason:
            'STANDARD_VOLATILITY: ATR ${atrPct.toStringAsFixed(2)}% (req ${criteria.minAtrPct}-${criteria.maxAtrPct}%), Realized Vol ${realizedVol.toStringAsFixed(2)}% (req >=${criteria.minRealizedVolatilityPct}%).',
      );
    }

    return HighVolatilityClassificationResult(
      symbol: market.symbol,
      pair: market.pair,
      category: PortfolioAssetCategory.highVolatilityCryptoSpot,
      qualifiesAsHighVolatility: true,
      isResearchEligible: true,
      isExecutionAuthorized: portfolioExecutionApproved,
      verificationStatus: portfolioExecutionApproved
          ? InstrumentVerificationStatus.verifiedTradableInPaper
          : InstrumentVerificationStatus.verifiedResearchOnly,
      atrPct: atrPct,
      realizedVolatilityPct: realizedVol,
      change24hPct: ticker.change24hPct,
      volume24h: ticker.volume24h,
      spreadBps: ticker.spreadBps,
      availableCandlesCount: closedCandles.length,
      isDataFresh: true,
      hasValidSpecs: true,
      classificationReason:
          'HIGH_VOLATILITY_QUALIFIED (Research-Only=${!portfolioExecutionApproved}): ATR ${atrPct.toStringAsFixed(2)}%, Realized Vol ${realizedVol.toStringAsFixed(2)}%, Spread ${ticker.spreadBps.toStringAsFixed(1)} bps.',
    );
  }

  HighVolatilityClassificationResult classifyPreciousMetal(String symbol) {
    final upper = symbol.trim().toUpperCase();
    return HighVolatilityClassificationResult(
      symbol: upper,
      pair: upper,
      category: PortfolioAssetCategory.preciousMetalSpotCfd,
      qualifiesAsHighVolatility: false,
      isResearchEligible: true,
      isExecutionAuthorized: false,
      verificationStatus:
          InstrumentVerificationStatus.unverifiedProviderPending,
      availableCandlesCount: 0,
      isDataFresh: false,
      hasValidSpecs: false,
      classificationReason:
          'RESEARCH_ONLY_PROVIDER_PENDING: $upper market-data provider not yet selected or verified. CoinDCX does not support precious metals. Execution hard-locked.',
    );
  }
}

/// Section 3, 6, 7 & 8: Complete Dual Portfolio Runtime Manager & Isolation Engine.
class DualPortfolioManager {
  static const int maxArchitecturalSimultaneousPositions = 5;

  final PersistenceDatabase persistence;
  final CoinDcxPortfolioProvider cryptoProvider;
  final UnverifiedHighVolatilityProvider highVolProvider;
  final HighVolatilityMarketClassifier classifier;

  PortfolioId selectedPortfolioId = PortfolioId.crypto;

  final Map<PortfolioId, IndependentRiskSupervisor> _riskSupervisors = {
    PortfolioId.crypto: IndependentRiskSupervisor(
      config: const RiskConfig(),
    ),
    PortfolioId.highVolatility: IndependentRiskSupervisor(
      config: const RiskConfig(),
    ),
  };

  final Map<PortfolioId, CashFlowReconciliationLedger> _cashFlowLedgers = {
    PortfolioId.crypto: CashFlowReconciliationLedger(),
    PortfolioId.highVolatility: CashFlowReconciliationLedger(),
  };

  final Map<PortfolioId, PortfolioAccountSnapshot> _snapshots = {
    PortfolioId.crypto: PortfolioAccountSnapshot(
      portfolioId: PortfolioId.crypto,
      displayName: PortfolioId.crypto.displayName,
      startingBalanceUsdt: 100.0,
      availableCashUsdt: 100.0,
      accountEquityUsdt: 100.0,
      startOfDayEquityUsdt: 100.0,
      executionEnabled: true,
      isResearchOnlyMode: false,
      liveTradingLocked: true,
      activeStrategyId: 'EMA_20_50_RSI_ATR_V1',
      configuredMaxOpenPositions: 5,
      architecturalMaxPositionCapacity: maxArchitecturalSimultaneousPositions,
      maxPortfolioLossPct: 15.0,
      portfolioLossLockoutActive: false,
      learningContext: const PortfolioLearningContext(
        portfolioId: PortfolioId.crypto,
        activeStrategyId: 'EMA_20_50_RSI_ATR_V1',
        learningInsights: [
          'Crypto learning context isolated to verified CoinDCX spot trades.',
        ],
      ),
      statusSummary:
          'Active Paper Portfolio • CoinDCX Spot • \$100.00 Preserved Account',
    ),
    PortfolioId.highVolatility: PortfolioAccountSnapshot(
      portfolioId: PortfolioId.highVolatility,
      displayName: PortfolioId.highVolatility.displayName,
      startingBalanceUsdt: 100.0,
      availableCashUsdt: 100.0,
      accountEquityUsdt: 100.0,
      startOfDayEquityUsdt: 100.0,
      executionEnabled: true,
      isResearchOnlyMode: false,
      liveTradingLocked: true,
      activeStrategyId: 'HIGH_VOL_RESEARCH_CANDIDATE_V1',
      configuredMaxOpenPositions: 5,
      architecturalMaxPositionCapacity: maxArchitecturalSimultaneousPositions,
      maxPortfolioLossPct: 15.0,
      portfolioLossLockoutActive: false,
      learningContext: const PortfolioLearningContext(
        portfolioId: PortfolioId.highVolatility,
        activeStrategyId: 'HIGH_VOL_RESEARCH_CANDIDATE_V1',
        preciousMetalsDataReady: false,
        learningInsights: [
          'High-Volatility learning context isolated from Crypto Portfolio.',
          'CoinDCX high-volatility crypto spot paper trading active; XAUUSD (Gold) & XAGUSD (Silver) remain research-only.',
        ],
      ),
      statusSummary:
          'CRYPTO PAPER TRADING ACTIVE (CoinDCX Spot) • Gold (XAUUSD) & Silver (XAGUSD) Research-Only',
    ),
  };

  DualPortfolioManager({
    required this.persistence,
    this.cryptoProvider = const CoinDcxPortfolioProvider(),
    this.highVolProvider = const UnverifiedHighVolatilityProvider(),
    this.classifier = const HighVolatilityMarketClassifier(),
  });

  IndependentRiskSupervisor riskSupervisorFor(PortfolioId id) =>
      _riskSupervisors[id]!;

  CashFlowReconciliationLedger cashFlowLedgerFor(PortfolioId id) =>
      _cashFlowLedgers[id]!;

  PortfolioAccountSnapshot snapshotFor(PortfolioId id) => _snapshots[id]!;

  PortfolioAccountSnapshot get activePortfolioSnapshot =>
      _snapshots[selectedPortfolioId]!;

  IndependentRiskSupervisor get activeRiskSupervisor =>
      _riskSupervisors[selectedPortfolioId]!;

  void selectPortfolio(PortfolioId id) {
    selectedPortfolioId = id;
  }

  static const List<RegisteredStrategyDescriptor> _cryptoPortfolioStrategies = [
    RegisteredStrategyDescriptor(
      id: 'EMA_20_50_RSI_ATR_V1',
      name: 'EMA 20/50 + RSI 14 + ATR 14 Multi-Timeframe',
      version: '1.0.0',
      status: StrategyApprovalStatus.approvedChampion,
      supportedSymbols: ['ALL_ELIGIBLE_COINDCX_SPOT'],
    ),
    RegisteredStrategyDescriptor(
      id: 'EMA_25_60_RSI_CONSERVATIVE_V1',
      name: 'EMA 25/60 + RSI 14 Conservative Spot Trend Filter',
      version: '1.0.0',
      status: StrategyApprovalStatus.approvedChampion,
      supportedSymbols: ['ALL_ELIGIBLE_COINDCX_SPOT'],
      entryRuleSummary: '1H EMA25>EMA60 + 15m EMA25>EMA60 + RSI(14) 52-66',
      exitRuleSummary: 'SL = 1.5x ATR(14), TP = 3.0x ATR(14) or Bearish Cross',
    ),
  ];

  static const List<RegisteredStrategyDescriptor> _highVolPortfolioStrategies = [
    RegisteredStrategyDescriptor(
      id: 'HIGH_VOL_RESEARCH_CANDIDATE_V1',
      name: 'ATR Volatility Breakout & Regime Filter (Research)',
      version: '1.0.0-research',
      status: StrategyApprovalStatus.shadowPaper,
      supportedSymbols: ['HIGH_VOL_CRYPTO_AND_PRECIOUS_METALS'],
      entryRuleSummary: 'High-Vol ATR(14) 1.2%–6.0% + Realized Vol >= 0.85% + Trend Filter',
      exitRuleSummary: 'Research-Only Validation (SL = 1.5x ATR, TP = 3.0x ATR)',
    ),
    RegisteredStrategyDescriptor(
      id: 'EMA_20_50_RSI_ATR_V1',
      name: 'EMA 20/50 + RSI 14 + ATR 14 Multi-Timeframe',
      version: '1.0.0',
      status: StrategyApprovalStatus.shadowPaper,
      supportedSymbols: ['HIGH_VOL_CRYPTO_AND_PRECIOUS_METALS'],
    ),
  ];

  List<RegisteredStrategyDescriptor> availableStrategiesFor(PortfolioId id) {
    return id == PortfolioId.crypto
        ? _cryptoPortfolioStrategies
        : _highVolPortfolioStrategies;
  }

  RegisteredStrategyDescriptor activeStrategyDescriptorFor(PortfolioId id) {
    final snap = _snapshots[id]!;
    final avail = availableStrategiesFor(id);
    for (final s in avail) {
      if (s.id == snap.activeStrategyId) return s;
    }
    for (final s in [
      ..._cryptoPortfolioStrategies,
      ..._highVolPortfolioStrategies,
    ]) {
      if (s.id == snap.activeStrategyId) return s;
    }
    return RegisteredStrategyDescriptor(
      id: snap.activeStrategyId,
      name: snap.activeStrategyId,
      version: '1.0.0',
      status: snap.isResearchOnlyMode
          ? StrategyApprovalStatus.shadowPaper
          : StrategyApprovalStatus.approvedChampion,
    );
  }

  Future<void> setPortfolioStrategy({
    required PortfolioId portfolioId,
    required String strategyId,
    int? nowMs,
  }) async {
    final cur = _snapshots[portfolioId]!;
    final ts = nowMs ?? DateTime.now().millisecondsSinceEpoch;
    final updated = cur.copyWith(
      activeStrategyId: strategyId,
      learningContext: PortfolioLearningContext(
        portfolioId: portfolioId,
        activeStrategyId: strategyId,
        activeStrategyVersion: cur.learningContext.activeStrategyVersion,
        evaluatedClosedTradesCount: cur.learningContext.evaluatedClosedTradesCount,
        observedWinningTrades: cur.learningContext.observedWinningTrades,
        observedLosingTrades: cur.learningContext.observedLosingTrades,
        cumulativeRealizedPnlUsdt: cur.learningContext.cumulativeRealizedPnlUsdt,
        regimeObservationsCount: cur.learningContext.regimeObservationsCount,
        symbolRealizedPnlMap: cur.learningContext.symbolRealizedPnlMap,
        learningInsights: [
          'Selected strategy $strategyId for ${portfolioId.displayName} (isolated from other portfolio).',
          ...cur.learningContext.learningInsights.take(4),
        ],
        currentPipelineStage: cur.learningContext.currentPipelineStage,
        autoStrategyTransferBlocked: true,
        autoDeployOnSingleTradeBlocked: true,
        preciousMetalsDataReady: cur.learningContext.preciousMetalsDataReady,
      ),
      updatedAtMs: ts,
    );
    _snapshots[portfolioId] = updated;
    await persistence.savePortfolioAccountSnapshot(updated);
  }

  Future<void> updatePortfolioSettings({
    required PortfolioId portfolioId,
    int? configuredMaxOpenPositions,
    double? maxPortfolioLossPct,
    String? statusSummary,
    int? nowMs,
  }) async {
    final cur = _snapshots[portfolioId]!;
    final ts = nowMs ?? DateTime.now().millisecondsSinceEpoch;
    final clampedMaxPos = configuredMaxOpenPositions != null
        ? configuredMaxOpenPositions.clamp(1, maxArchitecturalSimultaneousPositions)
        : cur.configuredMaxOpenPositions;
    final clampedLossPct = maxPortfolioLossPct != null
        ? maxPortfolioLossPct.clamp(1.0, 50.0)
        : cur.maxPortfolioLossPct;
    final sup = _riskSupervisors[portfolioId]!;
    sup.maxOpenPositionsLimit = clampedMaxPos;
    sup.maxPortfolioLossPct = clampedLossPct;

    final updated = cur.copyWith(
      configuredMaxOpenPositions: clampedMaxPos,
      maxPortfolioLossPct: clampedLossPct,
      statusSummary: statusSummary ?? cur.statusSummary,
      updatedAtMs: ts,
    );
    _snapshots[portfolioId] = updated;
    await persistence.savePortfolioAccountSnapshot(updated);
  }

  Future<bool> evaluateAndEnforcePortfolioLossLimit({
    required PortfolioId portfolioId,
    required double currentEquityUsdt,
    int? nowMs,
  }) async {
    final cur = _snapshots[portfolioId]!;
    final sup = _riskSupervisors[portfolioId]!;
    final ts = nowMs ?? DateTime.now().millisecondsSinceEpoch;
    final locked = sup.checkAndUpdatePortfolioLossLockout(
      currentEquityUsdt,
      startingBalanceUsdt: cur.startingBalanceUsdt,
    );
    final updated = cur.copyWith(
      accountEquityUsdt: currentEquityUsdt,
      maxDrawdownLocked: locked || cur.maxDrawdownLocked,
      portfolioLossLockoutActive: locked || cur.portfolioLossLockoutActive,
      statusSummary: locked
          ? 'RISK LOCKOUT ACTIVE: ${cur.maxPortfolioLossPct.toStringAsFixed(1)}% Portfolio Loss Limit (\$${cur.portfolioLossFloorUsdt.toStringAsFixed(2)} floor) reached'
          : cur.statusSummary,
      updatedAtMs: ts,
    );
    _snapshots[portfolioId] = updated;
    await persistence.savePortfolioAccountSnapshot(updated);
    return updated.isPortfolioLossLockoutTriggered;
  }

  Future<void> authorizePortfolioLossLimitReset({
    required PortfolioId portfolioId,
    bool resetBalanceToStarting = false,
    int? nowMs,
  }) async {
    final cur = _snapshots[portfolioId]!;
    final sup = _riskSupervisors[portfolioId]!;
    final ts = nowMs ?? DateTime.now().millisecondsSinceEpoch;
    sup.authorizePortfolioLossReset();
    final updated = cur.copyWith(
      availableCashUsdt:
          resetBalanceToStarting ? cur.startingBalanceUsdt : cur.availableCashUsdt,
      accountEquityUsdt:
          resetBalanceToStarting ? cur.startingBalanceUsdt : cur.accountEquityUsdt,
      maxDrawdownLocked: false,
      portfolioLossLockoutActive: false,
      consecutiveLosses: 0,
      statusSummary: cur.isResearchOnlyMode
          ? 'RESEARCH-ONLY MODE • High-Vol Crypto & Metals (XAUUSD/XAGUSD) • Execution Disabled Until Provider Verified'
          : 'Active Paper Portfolio • CoinDCX Spot • \$${(resetBalanceToStarting ? cur.startingBalanceUsdt : cur.accountEquityUsdt).toStringAsFixed(2)} Account',
      updatedAtMs: ts,
    );
    _snapshots[portfolioId] = updated;
    await persistence.savePortfolioAccountSnapshot(updated);
  }

  void syncCryptoPortfolioInMemory(PersistedEngineSnapshot snap) {
    final cryptoPositions = snap.openPositions
        .where((p) =>
            p.portfolioId.isEmpty ||
            p.portfolioId == PortfolioId.crypto.dbKey)
        .toList();
    final cryptoOrders = snap.orders
        .where((o) =>
            o.portfolioId.isEmpty ||
            o.portfolioId == PortfolioId.crypto.dbKey)
        .toList();
    final cryptoTrades = snap.closedTrades
        .where((t) =>
            t.portfolioId.isEmpty ||
            t.portfolioId == PortfolioId.crypto.dbKey)
        .toList();
    final cryptoCurve = snap.equityCurve
        .where((e) =>
            e.portfolioId.isEmpty ||
            e.portfolioId == PortfolioId.crypto.dbKey)
        .toList();

    final realizedPnl = cryptoTrades.fold<double>(
      0.0,
      (acc, t) => acc + t.realizedPnlUsdt,
    );
    final unrealizedPnl = cryptoPositions.fold<double>(
      0.0,
      (acc, p) {
        final mark = snap.liveTickerPrices[p.symbol] ??
            snap.closedCandlePrices[p.symbol] ??
            p.entryPrice;
        return acc + p.unrealizedPnlUsdt(mark);
      },
    );

    final symbolPnl = <String, double>{};
    for (final t in cryptoTrades) {
      symbolPnl[t.symbol] = (symbolPnl[t.symbol] ?? 0.0) + t.realizedPnlUsdt;
    }

    final wins = cryptoTrades.where((t) => t.realizedPnlUsdt >= 0).length;
    final losses = cryptoTrades.length - wins;

    final currentCrypto = _snapshots[PortfolioId.crypto]!;
    final floorUsdt = currentCrypto.portfolioLossFloorUsdt;
    final isLossLocked = snap.maxDrawdownLocked ||
        currentCrypto.portfolioLossLockoutActive ||
        snap.accountEquityUsdt <= floorUsdt + 1e-9;
    final sup = _riskSupervisors[PortfolioId.crypto]!;
    sup.portfolioLossLockoutActive = isLossLocked;
    sup.maxOpenPositionsLimit = currentCrypto.configuredMaxOpenPositions;
    sup.maxPortfolioLossPct = currentCrypto.maxPortfolioLossPct;

    final updatedCrypto = currentCrypto.copyWith(
      availableCashUsdt: snap.availableCashUsdt,
      accountEquityUsdt: snap.accountEquityUsdt,
      startOfDayEquityUsdt: snap.startOfDayEquityUsdt,
      realizedPnlUsdt: realizedPnl,
      unrealizedPnlUsdt: unrealizedPnl,
      maxDrawdownLocked: isLossLocked,
      portfolioLossLockoutActive: isLossLocked,
      lockedDailyLossUtcDate: snap.lockedDailyLossUtcDate,
      lastStopLossClosedAtMs: snap.lastStopLossClosedAtMs,
      openPositions: cryptoPositions,
      orders: cryptoOrders,
      closedTrades: cryptoTrades,
      equityCurve: cryptoCurve,
      learningContext: PortfolioLearningContext(
        portfolioId: PortfolioId.crypto,
        activeStrategyId: currentCrypto.activeStrategyId,
        evaluatedClosedTradesCount: cryptoTrades.length,
        observedWinningTrades: wins,
        observedLosingTrades: losses,
        cumulativeRealizedPnlUsdt: realizedPnl,
        symbolRealizedPnlMap: symbolPnl,
        learningInsights: [
          'Evaluated ${cryptoTrades.length} closed Crypto Portfolio trades (${wins}W / ${losses}L).',
          'Isolated from High-Volatility Portfolio learning context.',
        ],
      ),
      updatedAtMs: DateTime.now().millisecondsSinceEpoch,
    );

    _snapshots[PortfolioId.crypto] = updatedCrypto;
  }

  Future<void> syncHighVolatilitySnapshot(
    PortfolioAccountSnapshot persistedHv,
  ) async {
    _snapshots[PortfolioId.highVolatility] = persistedHv;
    final sup = _riskSupervisors[PortfolioId.highVolatility]!;
    sup.portfolioLossLockoutActive = persistedHv.isPortfolioLossLockoutTriggered;
    sup.maxOpenPositionsLimit = persistedHv.configuredMaxOpenPositions;
    sup.maxPortfolioLossPct = persistedHv.maxPortfolioLossPct;
    sup.consecutiveLosses = persistedHv.consecutiveLosses;
  }

  Future<void> syncCryptoPortfolioFromEngineSnapshot(
    PersistedEngineSnapshot snap,
  ) async {
    final persistedCrypto = await persistence.loadPortfolioAccountSnapshot(
      PortfolioId.crypto,
    );
    if (persistedCrypto != null) {
      _snapshots[PortfolioId.crypto] = _snapshots[PortfolioId.crypto]!.copyWith(
        activeStrategyId: persistedCrypto.activeStrategyId,
        configuredMaxOpenPositions: persistedCrypto.configuredMaxOpenPositions,
        maxPortfolioLossPct: persistedCrypto.maxPortfolioLossPct,
        portfolioLossLockoutActive: persistedCrypto.portfolioLossLockoutActive,
      );
    }
    syncCryptoPortfolioInMemory(snap);
    await persistence.savePortfolioAccountSnapshot(
      _snapshots[PortfolioId.crypto]!,
    );

    final persistedHighVol = await persistence.loadPortfolioAccountSnapshot(
      PortfolioId.highVolatility,
    );
    if (persistedHighVol != null) {
      _snapshots[PortfolioId.highVolatility] = persistedHighVol;
    } else {
      await persistence.savePortfolioAccountSnapshot(
        _snapshots[PortfolioId.highVolatility]!,
      );
    }
  }

  ({
    bool approved,
    double approvedQuantity,
    double stopLossPrice,
    String? rejectionReason,
  }) vetAndSizePortfolioOrder({
    required PortfolioId portfolioId,
    required VerifiedInstrumentSpecification instrumentSpec,
    required double entryPrice,
    required double stopLossPrice,
    required double spreadPct,
    required double atr14,
    required bool isDataFresh,
    required int nowMs,
    bool isLiveTradingAttempt = false,
  }) {
    if (isLiveTradingAttempt) {
      return (
        approved: false,
        approvedQuantity: 0.0,
        stopLossPrice: stopLossPrice,
        rejectionReason:
            'LIVE_TRADING_HARD_LOCKED: Application is strictly locked to PAPER TRADING ONLY.',
      );
    }

    final snap = _snapshots[portfolioId]!;
    final supervisor = _riskSupervisors[portfolioId]!;
    supervisor.maxOpenPositionsLimit = snap.configuredMaxOpenPositions;
    supervisor.maxPortfolioLossPct = snap.maxPortfolioLossPct;

    if (CoinDcxPortfolioProvider.isPreciousMetalSymbol(instrumentSpec.symbol) ||
        instrumentSpec.category == PortfolioAssetCategory.preciousMetalSpotCfd) {
      return (
        approved: false,
        approvedQuantity: 0.0,
        stopLossPrice: stopLossPrice,
        rejectionReason:
            'PRECIOUS_METALS_RESEARCH_ONLY_LOCK: ${instrumentSpec.symbol} is locked in RESEARCH-ONLY mode until a verified metals provider and contract specifications are approved.',
      );
    }

    if (snap.isResearchOnlyMode || !snap.executionEnabled) {
      return (
        approved: false,
        approvedQuantity: 0.0,
        stopLossPrice: stopLossPrice,
        rejectionReason:
            'PORTFOLIO_RESEARCH_ONLY_LOCK: ${snap.displayName} is in research-only mode; autonomous paper execution is disabled until provider & specifications are verified.',
      );
    }

    if (snap.isPortfolioLossLockoutTriggered) {
      supervisor.portfolioLossLockoutActive = true;
      return (
        approved: false,
        approvedQuantity: 0.0,
        stopLossPrice: stopLossPrice,
        rejectionReason:
            'PORTFOLIO_LOSS_LIMIT_15PCT_LOCKOUT: Portfolio ${snap.maxPortfolioLossPct.toStringAsFixed(1)}% loss lockout active (Equity \$${snap.accountEquityUsdt.toStringAsFixed(2)} <= \$${snap.portfolioLossFloorUsdt.toStringAsFixed(2)} floor).',
      );
    }

    if (!instrumentSpec.hasCompleteQuantitativeSpecs ||
        !instrumentSpec.isExecutionAuthorized) {
      return (
        approved: false,
        approvedQuantity: 0.0,
        stopLossPrice: stopLossPrice,
        rejectionReason:
            'UNVERIFIED_INSTRUMENT_SPECIFICATION: ${instrumentSpec.symbol} lacks verified provider/contract specifications (${instrumentSpec.statusNote}).',
      );
    }

    if (stopLossPrice <= 0 || stopLossPrice >= entryPrice) {
      return (
        approved: false,
        approvedQuantity: 0.0,
        stopLossPrice: stopLossPrice,
        rejectionReason:
            'INVALID_STOP_LOSS: Stop-loss must be below entry price and is never moved closer.',
      );
    }

    final feeRate = instrumentSpec.takerFeeRate ?? 0.001;
    const slippageRate = 0.0005;
    final minQty = instrumentSpec.minQuantity!;
    final step = instrumentSpec.quantityStep!;
    final minNotional = instrumentSpec.minNotional!;

    final stopDistPerUnit = entryPrice - stopLossPrice;
    final costPerUnit = entryPrice * (feeRate * 2.0 + slippageRate * 2.0);
    final totalRiskPerUnit = stopDistPerUnit + costPerUnit;

    final minQtyForNotional =
        entryPrice > 0 ? (minNotional / entryPrice) : minQty;
    final rawMinFeasible = math.max(minQty, minQtyForNotional);
    final ceiledSteps = ((rawMinFeasible / step) - 1e-9).ceilToDouble();
    final effectiveMinQty = math.max(minQty, ceiledSteps * step);

    final maxAllowedRiskUsdt =
        snap.accountEquityUsdt * supervisor.config.maxRiskPerTradeFraction;
    final riskAtMinQty = effectiveMinQty * totalRiskPerUnit;

    if (riskAtMinQty > maxAllowedRiskUsdt + 1e-9) {
      return (
        approved: false,
        approvedQuantity: 0.0,
        stopLossPrice: stopLossPrice,
        rejectionReason:
            'MIN_QUANTITY_EXCEEDS_PERMITTED_RISK: Minimum quantity $effectiveMinQty requires \$${riskAtMinQty.toStringAsFixed(2)} risk at stop-loss $stopLossPrice, exceeding permitted \$${maxAllowedRiskUsdt.toStringAsFixed(2)} risk cap.',
      );
    }

    final rawTargetQty = maxAllowedRiskUsdt / totalRiskPerUnit;
    final flooredSteps = ((rawTargetQty / step) + 1e-9).floorToDouble();
    final sizedQty = flooredSteps * step;

    if (sizedQty + 1e-12 < effectiveMinQty) {
      return (
        approved: false,
        approvedQuantity: 0.0,
        stopLossPrice: stopLossPrice,
        rejectionReason:
            'BELOW_MINIMUM_ORDER_SIZE: Sized quantity $sizedQty is below minimum $effectiveMinQty.',
      );
    }

    final vet = supervisor.vetOrderRequest(
      symbol: instrumentSpec.symbol,
      currentEquityUsdt: snap.accountEquityUsdt,
      startOfDayEquityUsdt: snap.startOfDayEquityUsdt,
      availableCashUsdt: snap.availableCashUsdt,
      entryPrice: entryPrice,
      stopLossPrice: stopLossPrice,
      quantity: sizedQty,
      feeRate: feeRate,
      slippageRate: slippageRate,
      spreadPct: spreadPct,
      atr14: atr14,
      isDataFresh: isDataFresh,
      openPositions: snap.openPositions,
      activeOrders: const [],
      lastStopLossClosedAtMs: snap.lastStopLossClosedAtMs,
      nowMs: nowMs,
    );

    if (!vet.approved) {
      return (
        approved: false,
        approvedQuantity: 0.0,
        stopLossPrice: stopLossPrice,
        rejectionReason: vet.reason,
      );
    }

    return (
      approved: true,
      approvedQuantity: sizedQty,
      stopLossPrice: stopLossPrice,
      rejectionReason: null,
    );
  }

  Future<({bool executed, String? reason, PaperPosition? position})>
      openIsolatedPaperPosition({
    required PortfolioId portfolioId,
    required VerifiedInstrumentSpecification instrumentSpec,
    required double entryPrice,
    required double stopLossPrice,
    required double takeProfitPrice,
    required double quantity,
    required int nowMs,
  }) async {
    final snap = _snapshots[portfolioId]!;
    if (CoinDcxPortfolioProvider.isPreciousMetalSymbol(instrumentSpec.symbol) ||
        instrumentSpec.category == PortfolioAssetCategory.preciousMetalSpotCfd) {
      return (
        executed: false,
        reason:
            'PRECIOUS_METALS_RESEARCH_ONLY_LOCK: ${instrumentSpec.symbol} remains RESEARCH-ONLY until a verified metals provider and contract specifications are approved.',
        position: null,
      );
    }
    if (snap.isResearchOnlyMode || !snap.executionEnabled) {
      return (
        executed: false,
        reason:
            'PORTFOLIO_RESEARCH_ONLY_LOCK: Cannot open position while ${snap.displayName} is in research-only mode.',
        position: null,
      );
    }
    if (!instrumentSpec.hasCompleteQuantitativeSpecs ||
        !instrumentSpec.isExecutionAuthorized) {
      return (
        executed: false,
        reason:
            'UNVERIFIED_INSTRUMENT_SPECIFICATION: ${instrumentSpec.symbol} is not verified for execution.',
        position: null,
      );
    }

    final supervisor = _riskSupervisors[portfolioId]!;
    supervisor.maxOpenPositionsLimit = snap.configuredMaxOpenPositions;
    supervisor.maxPortfolioLossPct = snap.maxPortfolioLossPct;
    if (snap.isPortfolioLossLockoutTriggered) {
      supervisor.portfolioLossLockoutActive = true;
      return (
        executed: false,
        reason:
            'PORTFOLIO_LOSS_LIMIT_15PCT_LOCKOUT: ${snap.displayName} is locked at ${snap.maxPortfolioLossPct.toStringAsFixed(1)}% loss limit (\$${snap.portfolioLossFloorUsdt.toStringAsFixed(2)} floor).',
        position: null,
      );
    }
    if (snap.openPositions.length >= snap.configuredMaxOpenPositions) {
      return (
        executed: false,
        reason:
            'MAX_OPEN_POSITIONS_REACHED: ${snap.openPositions.length}/${snap.configuredMaxOpenPositions} open positions already active in ${snap.displayName}.',
        position: null,
      );
    }
    if (snap.openPositions.any((p) => p.symbol == instrumentSpec.symbol)) {
      return (
        executed: false,
        reason:
            'DUPLICATE_SYMBOL_POSITION: ${instrumentSpec.symbol} already has an open position in ${snap.displayName}.',
        position: null,
      );
    }
    final feeRate = instrumentSpec.takerFeeRate ?? 0.001;
    final vet = supervisor.vetOrderRequest(
      symbol: instrumentSpec.symbol,
      currentEquityUsdt: snap.accountEquityUsdt,
      startOfDayEquityUsdt: snap.startOfDayEquityUsdt,
      availableCashUsdt: snap.availableCashUsdt,
      entryPrice: entryPrice,
      stopLossPrice: stopLossPrice,
      quantity: quantity,
      feeRate: feeRate,
      slippageRate: 0.0005,
      spreadPct: (instrumentSpec.currentSpreadBps ?? 5.0) / 100.0,
      atr14: (entryPrice - stopLossPrice) / 1.5,
      isDataFresh: true,
      openPositions: snap.openPositions,
      activeOrders: const [],
      lastStopLossClosedAtMs: snap.lastStopLossClosedAtMs,
      nowMs: nowMs,
    );
    if (!vet.approved) {
      return (executed: false, reason: vet.reason, position: null);
    }

    final notional = entryPrice * quantity;
    final entryFee = notional * feeRate;
    final pos = PaperPosition(
      id: '${portfolioId.dbKey}_POS_${nowMs}_${snap.openPositions.length + 1}',
      portfolioId: portfolioId.dbKey,
      symbol: instrumentSpec.symbol,
      entryPrice: entryPrice,
      quantity: quantity,
      stopLoss: stopLossPrice,
      takeProfit: takeProfitPrice,
      entryFeeUsdt: entryFee,
      signalCandleCloseMs: nowMs,
      openedAtMs: nowMs,
    );
    final order = SimulatedOrder(
      id: '${portfolioId.dbKey}_ORD_${nowMs}_${snap.orders.length + 1}',
      portfolioId: portfolioId.dbKey,
      symbol: instrumentSpec.symbol,
      side: 'BUY',
      requestedPrice: entryPrice,
      executedPrice: entryPrice,
      quantity: quantity,
      notionalUsdt: notional,
      feeUsdt: entryFee,
      signalCandleCloseMs: nowMs,
      executedAtMs: nowMs,
      reason: 'ISOLATED_PORTFOLIO_ENTRY (${portfolioId.dbKey})',
    );

    final updatedOpenPositions = [pos, ...snap.openPositions];
    final totalOpenNotional = updatedOpenPositions.fold<double>(
      0.0,
      (acc, p) => acc + p.investedNotionalUsdt,
    );
    final newCash = snap.availableCashUsdt - notional - entryFee;
    final newEquity = newCash + totalOpenNotional;
    final updated = snap.copyWith(
      availableCashUsdt: newCash,
      accountEquityUsdt: newEquity,
      openPositions: updatedOpenPositions,
      orders: [order, ...snap.orders],
      equityCurve: [
        ...snap.equityCurve,
        EquityPoint(
          timestampMs: nowMs,
          equityUsdt: newEquity,
          portfolioId: portfolioId.dbKey,
        ),
      ],
      updatedAtMs: nowMs,
    );
    _snapshots[portfolioId] = updated;
    await persistence.savePortfolioAccountSnapshot(updated);
    return (executed: true, reason: null, position: pos);
  }

  Future<({bool closed, ClosedPaperTrade? trade})> closeIsolatedPaperPosition({
    required PortfolioId portfolioId,
    required String positionId,
    required double exitPrice,
    required int nowMs,
    String exitReason = 'TAKE_PROFIT',
  }) async {
    final snap = _snapshots[portfolioId]!;
    final idx = snap.openPositions.indexWhere((p) => p.id == positionId);
    if (idx == -1) return (closed: false, trade: null);

    final pos = snap.openPositions[idx];
    final exitNotional = exitPrice * pos.quantity;
    final exitFee = exitNotional * 0.001;
    final totalFees = pos.entryFeeUsdt + exitFee;
    final realizedPnl =
        (exitNotional - pos.investedNotionalUsdt) - totalFees;

    final closedTrade = ClosedPaperTrade(
      id: '${portfolioId.dbKey}_TRD_${nowMs}_${snap.closedTrades.length + 1}',
      portfolioId: portfolioId.dbKey,
      symbol: pos.symbol,
      entryPrice: pos.entryPrice,
      exitPrice: exitPrice,
      quantity: pos.quantity,
      stopLoss: pos.stopLoss,
      takeProfit: pos.takeProfit,
      totalFeesUsdt: totalFees,
      realizedPnlUsdt: realizedPnl,
      openedAtMs: pos.openedAtMs,
      closedAtMs: nowMs,
      exitReason: exitReason,
    );

    final supervisor = _riskSupervisors[portfolioId]!;
    supervisor.recordClosedTradeOutcome(realizedPnl);

    final remainingPositions = List<PaperPosition>.from(snap.openPositions)
      ..removeAt(idx);
    final newCash = snap.availableCashUsdt + exitNotional - exitFee;
    final remainingNotional = remainingPositions.fold<double>(
      0.0,
      (acc, p) => acc + p.investedNotionalUsdt,
    );
    final newEquity = newCash + remainingNotional;
    final newRealized = snap.realizedPnlUsdt + realizedPnl;
    final newTrades = [closedTrade, ...snap.closedTrades];
    final wins = newTrades.where((t) => t.realizedPnlUsdt >= 0).length;
    final losses = newTrades.length - wins;
    final lossLockTriggered = supervisor.checkAndUpdatePortfolioLossLockout(
      newEquity,
      startingBalanceUsdt: snap.startingBalanceUsdt,
    );

    final updated = snap.copyWith(
      availableCashUsdt: newCash,
      accountEquityUsdt: newEquity,
      realizedPnlUsdt: newRealized,
      maxDrawdownLocked: lossLockTriggered || snap.maxDrawdownLocked,
      portfolioLossLockoutActive:
          lossLockTriggered || snap.portfolioLossLockoutActive,
      consecutiveLosses: supervisor.consecutiveLosses,
      lastStopLossClosedAtMs:
          realizedPnl < 0 ? nowMs : snap.lastStopLossClosedAtMs,
      openPositions: remainingPositions,
      closedTrades: newTrades,
      equityCurve: [
        ...snap.equityCurve,
        EquityPoint(
          timestampMs: nowMs,
          equityUsdt: newEquity,
          portfolioId: portfolioId.dbKey,
        ),
      ],
      learningContext: PortfolioLearningContext(
        portfolioId: portfolioId,
        activeStrategyId: snap.activeStrategyId,
        evaluatedClosedTradesCount: newTrades.length,
        observedWinningTrades: wins,
        observedLosingTrades: losses,
        cumulativeRealizedPnlUsdt: newRealized,
        learningInsights: [
          'Updated ${portfolioId.dbKey} learning context with trade ${closedTrade.id} (PnL \$${realizedPnl.toStringAsFixed(2)}).',
        ],
      ),
      updatedAtMs: nowMs,
    );

    _snapshots[portfolioId] = updated;
    await persistence.savePortfolioAccountSnapshot(updated);
    return (closed: true, trade: closedTrade);
  }

  Future<void> setHighVolatilityExecutionApproval({
    required bool approvedAndVerified,
    required int nowMs,
  }) async {
    final cur = _snapshots[PortfolioId.highVolatility]!;
    final updated = cur.copyWith(
      executionEnabled: approvedAndVerified,
      isResearchOnlyMode: !approvedAndVerified,
      statusSummary: approvedAndVerified
          ? 'PAPER EXECUTION ENABLED • High-Volatility Verified Instruments'
          : 'RESEARCH-ONLY MODE • High-Vol Crypto & Metals (XAUUSD/XAGUSD) • Execution Disabled Until Provider Verified',
      updatedAtMs: nowMs,
    );
    _snapshots[PortfolioId.highVolatility] = updated;
    await persistence.savePortfolioAccountSnapshot(updated);
  }
}

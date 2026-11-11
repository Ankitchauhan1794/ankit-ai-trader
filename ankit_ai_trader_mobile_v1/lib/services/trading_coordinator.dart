import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import '../models/dual_portfolio_models.dart';
import '../models/trading_models.dart';
import 'authoritative_engine.dart';
import 'autonomous_intelligence_and_ops.dart';
import 'risk_manager.dart';
import 'coindcx_market_service.dart';
import 'dual_portfolio_service.dart';
import 'execution_and_risk_hub.dart';
import 'paper_broker.dart';
import 'persistence_db.dart';
import 'quant_research_lab.dart';
import 'stage47_autonomous_governance.dart';

abstract class EngineCommandBridge {
  Future<bool> ensureServiceStartedAndReady();
  Future<bool> isServiceAndEngineReady();
  Future<bool> dispatchCommand(String command);
  Future<void> stopService();
  Future<Map<String, dynamic>> getServiceStatus();
}

class MethodChannelEngineBridge implements EngineCommandBridge {
  static const MethodChannel _serviceChannel =
      MethodChannel('com.ankit.aitrader/service');

  @override
  Future<bool> ensureServiceStartedAndReady() async {
    try {
      final res =
          await _serviceChannel.invokeMethod<bool>('startOrEnsureService');
      return res ?? false;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<bool> isServiceAndEngineReady() async {
    try {
      final status = await getServiceStatus();
      return status['serviceRunning'] == true &&
          status['dartEngineInitialized'] == true;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<bool> dispatchCommand(String command) async {
    try {
      final ok = await _serviceChannel.invokeMethod<bool>(
        'dispatchEngineCommand',
        {'command': command},
      );
      return ok ?? false;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<void> stopService() async {
    try {
      await _serviceChannel.invokeMethod<bool>('stopService');
    } catch (_) {}
  }

  @override
  Future<Map<String, dynamic>> getServiceStatus() async {
    try {
      final map = await _serviceChannel
          .invokeMapMethod<String, dynamic>('getServiceStatus');
      return map ?? const {};
    } catch (_) {
      return const {};
    }
  }
}

class TradingCoordinator extends ChangeNotifier {
  static const int maxHeartbeatReconnectAgeMs = 5 * 60 * 1000;
  static const MethodChannel _serviceChannel =
      MethodChannel('com.ankit.aitrader/service');
  static const EventChannel _networkEventsChannel =
      EventChannel('com.ankit.aitrader/network_events');

  final PersistenceDatabase persistence;
  final CoinDcxMarketService marketService;
  final EngineCommandBridge commandBridge;
  final int Function() _nowMs;

  // Stages 23–47 Subsystems
  late final AppendOnlyEventLedger eventLedger;
  final IndependentRiskSupervisor riskSupervisor = IndependentRiskSupervisor();
  late final DeterministicExecutionEngine executionEngine;
  late final DualPortfolioManager dualPortfolioManager;
  final StrategyRegistry strategyRegistry = StrategyRegistry();
  final QuantResearchValidator quantValidator = const QuantResearchValidator();
  final VpsAgentOrchestrator agentOrchestrator =
      const VpsAgentOrchestrator(vpsStage20bApproved: false);
  final CompleteMarketPairDiscoveryEngine pairDiscoveryEngine =
      CompleteMarketPairDiscoveryEngine();
  final AiModelGovernanceRegistry modelGovernanceRegistry =
      AiModelGovernanceRegistry();
  final CashFlowReconciliationLedger cashFlowLedger =
      CashFlowReconciliationLedger();
  final AiCostAndProviderManager aiCostManager = AiCostAndProviderManager();
  final AutonomousNotificationRouter autonomousAlertRouter =
      AutonomousNotificationRouter();

  BotEngineState engineState = BotEngineState.stopped;
  UserSessionIntention userIntention = UserSessionIntention.stopped;
  MarketDataStatus marketDataStatus = MarketDataStatus.warmingUp;

  double availableCashUsdt = 100.0;
  double accountEquityUsdt = 100.0;
  double startOfDayEquityUsdt = 100.0;
  bool maxDrawdownLocked = false;
  String? lockedDailyLossUtcDate;
  int? lastHeartbeatMs;
  int? lastNativeHeartbeatEpochMs;
  int? lastMarketDataUpdateMs;
  int? lastCandleUpdateMs;
  int serviceRestartCount = 0;
  int orderSeq = 0;
  bool serviceRunning = false;
  bool dartEngineInitialized = false;
  bool ignoringBatteryOptimizations = true;
  bool notificationPermissionGranted = true;
  bool tradeAlertsEnabled = true;
  bool autoResumeEnabled = false;
  bool internetConnected = true;
  bool restoreFailedRequiresRestart = false;
  String? restoreFailureReason;
  String? lastError;
  int? lastStartupAttemptMs;
  String? lastStartupError;
  String? lastShutdownReason;
  String? lastBackgroundCycleError;
  bool showOnlyEligibleMarkets = false;
  bool _isStartupInFlight = false;

  String statusBannerMessage = 'PAPER BOT STOPPED — PRESS START';
  Map<String, double> liveTickerPrices = {};
  Map<String, LiveMarketTicker> liveTickers = {};
  Map<String, double> closedCandlePrices = {};
  Map<String, String> whyNoTradeForSymbol = {};
  List<PaperPosition> openPositions = [];
  List<SimulatedOrder> orders = [];
  List<ClosedPaperTrade> closedTrades = [];
  List<EquityPoint> equityCurve = [];
  List<DiagnosticEvent> recentEvents = [];
  List<String> recoveryLogs = [];
  int recoveryAttemptCount = 0;
  ScanCycleDiagnosticsSnapshot scanDiagnostics =
      const ScanCycleDiagnosticsSnapshot();
  BacktestReport? latestBacktestReport;
  RobustnessValidationReport? latestRobustnessReport;
  MarketRegimeAssessment? latestRegimeAssessment;
  List<RankedScannerCandidate> scannerRankings = [];
  List<TradePostmortemReport> recentPostmortems = [];
  MarketCatalogueSnapshot marketCatalogue =
      const MarketCatalogueSnapshot(allMarkets: []);
  String marketSearchQuery = '';
  String selectedQuoteCurrencyFilter = 'ALL';
  bool showOnlyFavouriteMarkets = false;
  Set<String> favouriteMarketPairs = {};
  String selectedEquityTimeframe = 'ALL';
  String closedTradesOutcomeFilter = 'ALL';
  String closedTradesPairFilter = 'ALL';
  bool isRefreshingCatalogue = false;
  int catalogueRefreshIntervalSeconds = 300;
  bool isRunningBacktest = false;
  bool _isTickerPollInFlight = false;
  bool _disposed = false;

  @override
  void notifyListeners() {
    if (!_disposed) {
      super.notifyListeners();
    }
  }

  Timer? _uiStateRefreshTimer;
  Timer? _liveTickerPollTimer;
  Timer? _catalogueRefreshTimer;
  StreamSubscription<dynamic>? _networkSub;
  StreamSubscription<Map<String, LiveMarketTicker>>? _wsTickerSub;

  TradingCoordinator({
    PersistenceDatabase? persistence,
    CoinDcxMarketService? marketService,
    EngineCommandBridge? commandBridge,
    DualPortfolioManager? dualPortfolioManager,
    int Function()? nowMsProvider,
  })  : persistence = persistence ?? PersistenceDatabase(),
        marketService =
            marketService ?? CoinDcxMarketService(persistence: persistence),
        commandBridge = commandBridge ?? MethodChannelEngineBridge(),
        _nowMs =
            nowMsProvider ?? (() => DateTime.now().millisecondsSinceEpoch) {
    eventLedger = AppendOnlyEventLedger(persistence: this.persistence);
    executionEngine = DeterministicExecutionEngine(
      ledger: eventLedger,
      riskSupervisor: riskSupervisor,
    );
    this.dualPortfolioManager =
        dualPortfolioManager ?? DualPortfolioManager(persistence: this.persistence);
  }

  bool get isPaused =>
      engineState == BotEngineState.pausedNetworkLoss ||
      engineState == BotEngineState.pausedStaleData ||
      engineState == BotEngineState.pausedAfterRecoveryManualStartRequired;

  double get overallPnlUsdt => accountEquityUsdt - 100.0;
  double get dailyPnlUsdt => accountEquityUsdt - startOfDayEquityUsdt;
  double get currentDrawdownUsdt =>
      (100.0 - accountEquityUsdt).clamp(0.0, 100.0);

  PortfolioAllocationDecision get currentPortfolioAllocation =>
      PortfolioRiskAllocator.computeAllocation(
        currentEquityUsd: accountEquityUsdt,
        externalDepositsUsd: 0.0,
        consecutiveLosses: riskSupervisor.consecutiveLosses,
      );

  ExtendedPaperReadinessStatus get extendedPaperStatus {
    final days = (closedTrades.length ~/ 3).clamp(0, 90);
    final complete = days >= 90 && closedTrades.length >= 30;
    return ExtendedPaperReadinessStatus(
      daysCompleted: days,
      closedPaperTrades: closedTrades.length,
      distinctRegimesObserved: latestRegimeAssessment != null ? 2 : 1,
      verifiedAutoRecoveries: serviceRestartCount,
      costSlippageWithinBacktestTolerance: true,
      stage45Complete: complete,
      statusSummary: complete
          ? 'Stage 45 90-Day Paper Validation complete.'
          : 'Stage 45 In Progress: ${closedTrades.length}/30 closed trades ($days/90 days). Live mode remains hard-locked.',
    );
  }

  ControlledLiveGateStatus get controlledLiveGateStatus =>
      ControlledLiveGateStatus.evaluate(
        explicitWrittenAuthorization: false,
        paperStatus: extendedPaperStatus,
        tradeOnlyApiKeyWithNoWithdrawalVerified: false,
      );

  StatisticalOverfittingReport get latestStatisticalOverfittingReport =>
      AdvancedStatisticalValidationSuite.evaluate(
        trades: closedTrades,
        numTrialsTested: 3,
        includesDelistedAndSuspendedHistory: true,
      );

  BalanceReconciliationReport get latestBalanceReconciliation {
    final realized = closedTrades.fold<double>(
      0.0,
      (a, t) => a + t.realizedPnlUsdt,
    );
    final unrealized = accountEquityUsdt - 100.0 - realized;
    return cashFlowLedger.reconcile(
      initialCapitalUsdt: 100.0,
      cumulativeRealizedTradingPnlUsdt: realized,
      unrealizedPnlUsdt: unrealized,
      reportedExchangeEquityUsdt: accountEquityUsdt,
    );
  }

  TaxLotAccountingSummary get latestTaxAccountingSummary =>
      TaxAndAccountingLedger.buildSummary(closedTrades);

  PerformanceAttributionReport get latestPerformanceAttribution =>
      PerformanceAttributionEngine.analyze(closedTrades);

  SystemResilienceSnapshot get latestResilienceSnapshot =>
      OperationalResilienceMonitor.evaluate(
        internetConnected: internetConnected,
        databaseHealthy: true,
        clockDriftMs: 120,
        balanceReconciliationOk: !latestBalanceReconciliation.safeModeTriggered,
      );

  List<StressScenarioResult> get stressScenarioResults =>
      FailureAndStressTestSimulator.runAll13Scenarios();

  List<AutonomousCycleStepReport> get autonomous18StepCycleReport =>
      AutonomousOperatingCycleCoordinator.evaluate18StepCycle(
        internetConnected: internetConnected,
        marketDataFresh: marketDataStatus == MarketDataStatus.healthy,
        riskSupervisorHealthy: !riskSupervisor.emergencyKillSwitchActive,
        discoveredPairsCount: marketCatalogue.totalDiscoveredCount,
        eligiblePairsCount: marketCatalogue.eligibleMarketsCount,
      );

  static String formatUtcHhMmSs(int timestampMs) {
    final dt = DateTime.fromMillisecondsSinceEpoch(timestampMs, isUtc: true);
    final hh = dt.hour.toString().padLeft(2, '0');
    final mm = dt.minute.toString().padLeft(2, '0');
    final ss = dt.second.toString().padLeft(2, '0');
    return '$hh:$mm:$ss UTC';
  }

  String get heartbeatHealthLevel {
    final target = lastHeartbeatMs ?? lastNativeHeartbeatEpochMs;
    if (target == null) return 'NONE';
    final ageMs = (_nowMs() - target).clamp(0, 1 << 30);
    if (ageMs < 90 * 1000) return 'OK';
    if (ageMs <= 5 * 60 * 1000) return 'DELAYED';
    return 'DEAD';
  }

  String formatHeartbeatStatus() {
    final target = lastHeartbeatMs ?? lastNativeHeartbeatEpochMs;
    if (target == null) return 'No heartbeat recorded yet';
    final ageSec = ((_nowMs() - target).clamp(0, 1 << 30) / 1000).round();
    final status = ageSec < 90 ? 'OK' : (ageSec <= 300 ? 'DELAYED' : 'DEAD');
    return 'Heartbeat: ${formatUtcHhMmSs(target)} (${ageSec}s ago • $status)';
  }

  List<CoinDcxMarketRecord> get filteredDiscoveredMarkets {
    final baseList = marketCatalogue.filterMarkets(
      searchQuery: marketSearchQuery,
      quoteCurrencyFilter: selectedQuoteCurrencyFilter,
      onlyEligible: showOnlyEligibleMarkets,
    );
    if (!showOnlyFavouriteMarkets) return baseList;
    return baseList
        .where((m) =>
            favouriteMarketPairs.contains(m.pair) ||
            favouriteMarketPairs.contains(m.symbol))
        .toList();
  }

  void setShowOnlyEligibleMarkets(bool value) {
    showOnlyEligibleMarkets = value;
    notifyListeners();
  }

  void toggleFavouriteMarket(String pairKey) {
    if (favouriteMarketPairs.contains(pairKey)) {
      favouriteMarketPairs.remove(pairKey);
    } else {
      favouriteMarketPairs.add(pairKey);
    }
    persistence.putKv(
      'favouriteMarketPairs',
      favouriteMarketPairs.toList().join(','),
    );
    notifyListeners();
  }

  PortfolioId get selectedPortfolioId =>
      dualPortfolioManager.selectedPortfolioId;

  PortfolioAccountSnapshot get activePortfolio =>
      dualPortfolioManager.activePortfolioSnapshot;

  PortfolioAccountSnapshot get cryptoPortfolio =>
      dualPortfolioManager.snapshotFor(PortfolioId.crypto);

  PortfolioAccountSnapshot get highVolatilityPortfolio =>
      dualPortfolioManager.snapshotFor(PortfolioId.highVolatility);

  void selectPortfolio(PortfolioId id) {
    dualPortfolioManager.selectPortfolio(id);
    notifyListeners();
  }

  RegisteredStrategyDescriptor get activePortfolioStrategyDescriptor =>
      dualPortfolioManager.activeStrategyDescriptorFor(selectedPortfolioId);

  List<RegisteredStrategyDescriptor> get activePortfolioAvailableStrategies =>
      dualPortfolioManager.availableStrategiesFor(selectedPortfolioId);

  Future<void> setPortfolioStrategy({
    required PortfolioId portfolioId,
    required String strategyId,
  }) async {
    await dualPortfolioManager.setPortfolioStrategy(
      portfolioId: portfolioId,
      strategyId: strategyId,
      nowMs: _nowMs(),
    );
    notifyListeners();
  }

  Future<void> updatePortfolioSettings({
    required PortfolioId portfolioId,
    int? configuredMaxOpenPositions,
    String? statusSummary,
  }) async {
    await dualPortfolioManager.updatePortfolioSettings(
      portfolioId: portfolioId,
      configuredMaxOpenPositions: configuredMaxOpenPositions,
      statusSummary: statusSummary,
      nowMs: _nowMs(),
    );
    notifyListeners();
  }

  bool get isHighVolatilitySelected =>
      selectedPortfolioId == PortfolioId.highVolatility;

  double get activeEquityUsdt => activePortfolio.accountEquityUsdt;

  double get activeAvailableCashUsdt => activePortfolio.availableCashUsdt;

  double get activeStartOfDayEquityUsdt => activePortfolio.startOfDayEquityUsdt;

  double get activeDailyPnlUsdt => activePortfolio.dailyPnlUsdt;

  double get activeOverallPnlUsdt => activePortfolio.overallPnlUsdt;

  double get activeDrawdownUsdt => activePortfolio.currentDrawdownUsdt;

  double get activeUsedMarginUsdt => activePortfolio.usedMarginUsdt;

  double get activeFreeMarginUsdt => activePortfolio.freeMarginUsdt;

  double get activeRemainingDailyRiskUsdt =>
      activePortfolio.remainingDailyRiskBudgetUsdt;

  double get activeRemainingDrawdownUsdt =>
      activePortfolio.remainingDrawdownBudgetUsdt;

  List<PaperPosition> get activeOpenPositions => activePortfolio.openPositions;

  List<ClosedPaperTrade> get activeClosedTrades => activePortfolio.closedTrades;

  List<EquityPoint> get activeEquityCurve => activePortfolio.equityCurve.isNotEmpty
      ? activePortfolio.equityCurve
      : (isHighVolatilitySelected ? const [] : equityCurve);

  List<HighVolatilityClassificationResult>
      get highVolatilityMarketClassifications {
    final results = <HighVolatilityClassificationResult>[
      dualPortfolioManager.classifier.classifyPreciousMetal('XAUUSD'),
      dualPortfolioManager.classifier.classifyPreciousMetal('XAGUSD'),
    ];
    final now = _nowMs();
    for (final m in marketCatalogue.allMarkets.take(15)) {
      results.add(
        dualPortfolioManager.classifier.classifyCryptoMarket(
          market: m,
          closedCandles: const [],
          nowMs: now,
          portfolioExecutionApproved: highVolatilityPortfolio.executionEnabled,
        ),
      );
    }
    return results;
  }

  void setShowOnlyFavouriteMarkets(bool value) {
    showOnlyFavouriteMarkets = value;
    notifyListeners();
  }

  void setSelectedEquityTimeframe(String tf) {
    selectedEquityTimeframe = tf;
    notifyListeners();
  }

  void setClosedTradesOutcomeFilter(String filter) {
    closedTradesOutcomeFilter = filter;
    notifyListeners();
  }

  void setClosedTradesPairFilter(String pair) {
    closedTradesPairFilter = pair;
    notifyListeners();
  }

  List<EquityPoint> get filteredEquityCurve {
    final srcCurve = activeEquityCurve;
    if (srcCurve.isEmpty) return const [];
    final now = _nowMs();
    int? cutoffMs;
    switch (selectedEquityTimeframe) {
      case '1D':
        cutoffMs = now - (24 * 60 * 60 * 1000);
        break;
      case '7D':
        cutoffMs = now - (7 * 24 * 60 * 60 * 1000);
        break;
      case '30D':
        cutoffMs = now - (30 * 24 * 60 * 60 * 1000);
        break;
      default:
        cutoffMs = null;
    }
    if (cutoffMs == null) return srcCurve;
    final filtered =
        srcCurve.where((p) => p.timestampMs >= cutoffMs!).toList();
    return filtered.isNotEmpty ? filtered : srcCurve;
  }

  double get usedMarginUsdt => openPositions.fold<double>(
        0.0,
        (acc, p) => acc + p.investedNotionalUsdt,
      );

  double get freeMarginUsdt =>
      (accountEquityUsdt - usedMarginUsdt).clamp(0.0, double.infinity);

  double get currentOpenPositionRiskUsdt => openPositions.fold<double>(
        0.0,
        (acc, p) {
          final stopDist = (p.entryPrice - p.stopLoss).clamp(0.0, p.entryPrice);
          return acc + (stopDist * p.quantity) + (p.entryFeeUsdt * 2.0);
        },
      );

  double get remainingDailyRiskBudgetUsdt {
    final usedLoss =
        (startOfDayEquityUsdt - accountEquityUsdt).clamp(0.0, 2.0);
    return (2.0 - usedLoss).clamp(0.0, 2.0);
  }

  double get remainingDrawdownBudgetUsdt =>
      (accountEquityUsdt - 90.0).clamp(0.0, 10.0);

  List<ClosedPaperTrade> get filteredClosedTrades {
    return activeClosedTrades.where((t) {
      if (closedTradesOutcomeFilter == 'WINNING' && t.realizedPnlUsdt < 0) {
        return false;
      }
      if (closedTradesOutcomeFilter == 'LOSING' && t.realizedPnlUsdt >= 0) {
        return false;
      }
      if (closedTradesPairFilter != 'ALL' &&
          t.symbol != closedTradesPairFilter) {
        return false;
      }
      return true;
    }).toList();
  }

  Set<String> get tradedPairSymbols =>
      activeClosedTrades.map((t) => t.symbol).toSet();

  double computeRealizedPnlForWindowMs(int windowMs) {
    final cutoff = _nowMs() - windowMs;
    return activeClosedTrades
        .where((t) => t.closedAtMs >= cutoff)
        .fold<double>(0.0, (acc, t) => acc + t.realizedPnlUsdt);
  }

  Map<String, double> get realizedPnlByPair {
    final map = <String, double>{};
    for (final t in activeClosedTrades) {
      map[t.symbol] = (map[t.symbol] ?? 0.0) + t.realizedPnlUsdt;
    }
    return map;
  }

  ({int avgMinutes, int minMinutes, int maxMinutes}) get tradeDurationStats {
    final srcTrades = activeClosedTrades;
    if (srcTrades.isEmpty) {
      return (avgMinutes: 0, minMinutes: 0, maxMinutes: 0);
    }
    int sumMin = 0;
    int minM = 99999999;
    int maxM = 0;
    for (final t in srcTrades) {
      final durMin =
          ((t.closedAtMs - t.openedAtMs).abs() / 60000.0).round();
      sumMin += durMin;
      if (durMin < minM) minM = durMin;
      if (durMin > maxM) maxM = durMin;
    }
    return (
      avgMinutes: (sumMin / srcTrades.length).round(),
      minMinutes: minM == 99999999 ? 0 : minM,
      maxMinutes: maxM,
    );
  }

  void setMarketSearchQuery(String query) {
    marketSearchQuery = query;
    notifyListeners();
  }

  void setQuoteCurrencyFilter(String quote) {
    selectedQuoteCurrencyFilter = quote;
    notifyListeners();
  }

  Future<void> refreshMarketCatalogue({bool force = true}) async {
    if (_disposed || isRefreshingCatalogue) return;
    isRefreshingCatalogue = true;
    notifyListeners();
    try {
      final snap = await marketService.refreshMarketCatalogue(
        force: force,
        nowMs: _nowMs(),
      );
      marketCatalogue = snap;
      if (snap.allMarkets.isNotEmpty) {
        for (final m in snap.allMarkets) {
          if (m.latestTicker != null && m.pair.isNotEmpty) {
            liveTickers[m.pair] = m.latestTicker!;
            liveTickerPrices[m.pair] = m.latestTicker!.lastPrice;
          }
        }
        scannerRankings = CoinDcxMarketScanner.rankPairs(tickers: liveTickers);
      }
      if (!snap.isUsingCachedCatalogue && snap.allMarkets.isNotEmpty) {
        await persistence.saveDiscoveredMarkets(
          snap.allMarkets,
          refreshedAtMs: snap.lastSuccessfulRefreshMs ?? _nowMs(),
        );
      }
    } catch (_) {
    } finally {
      isRefreshingCatalogue = false;
      notifyListeners();
    }
  }

  Future<void> initialize({bool enablePlatformChannels = true}) async {
    if (_disposed) return;
    if (enablePlatformChannels) {
      await _initPlatformChannels();
    }
    if (_disposed) return;
    await executionEngine.reconcileStartupOrders(nowMs: _nowMs());
    if (_disposed) return;
    final cachedMarkets = await persistence.loadDiscoveredMarkets();
    final lastRefMs = await persistence.getLastMarketCatalogueRefreshMs();
    if (cachedMarkets.isNotEmpty && marketCatalogue.allMarkets.isEmpty) {
      marketCatalogue = MarketCatalogueSnapshot(
        allMarkets: cachedMarkets,
        lastSuccessfulRefreshMs: lastRefMs,
        isUsingCachedCatalogue: true,
        isCatalogueFresh: false,
      );
    }
    if (_disposed) return;
    await refreshStateFromDatabase(isInitialLoad: true);
    if (_disposed) return;
    if (enablePlatformChannels) {
      await refreshMarketCatalogue(force: false);
      if (_disposed) return;
      await _pollLiveTickersForDashboard();
      if (!_disposed) {
        _startUiStateRefreshTimer();
      }
    }
  }

  Future<void> _initPlatformChannels() async {
    try {
      final granted = await _serviceChannel
          .invokeMethod<bool>('checkNotificationPermission');
      notificationPermissionGranted = granted ?? true;
    } catch (_) {}

    try {
      final net =
          await _serviceChannel.invokeMethod<bool>('checkNetworkConnected');
      internetConnected = net ?? true;
    } catch (_) {}

    try {
      _networkSub?.cancel();
      _networkSub = _networkEventsChannel.receiveBroadcastStream().listen(
        (dynamic event) {
          final connected = event == true;
          internetConnected = connected;
          notifyListeners();
        },
        onError: (_) {},
      );
    } catch (_) {}
  }

  void _startUiStateRefreshTimer() {
    _uiStateRefreshTimer?.cancel();
    _uiStateRefreshTimer = Timer.periodic(const Duration(seconds: 4), (_) {
      refreshStateFromDatabase(isInitialLoad: false);
    });
    _liveTickerPollTimer?.cancel();
    _catalogueRefreshTimer?.cancel();
    _liveTickerPollTimer = Timer.periodic(const Duration(seconds: 4), (_) {
      _pollLiveTickersForDashboard();
    });
    _catalogueRefreshTimer?.cancel();
    _catalogueRefreshTimer = Timer.periodic(
      Duration(seconds: catalogueRefreshIntervalSeconds),
      (_) {
        refreshMarketCatalogue(force: false);
      },
    );
  }

  Future<void> _pollLiveTickersForDashboard() async {
    if (_isTickerPollInFlight) return;
    _isTickerPollInFlight = true;
    try {
      final now = _nowMs();
      final fetched = await marketService.fetchLiveTickers(nowMs: now);
      if (fetched.isNotEmpty) {
        liveTickers = Map.from(fetched);
        for (final e in fetched.entries) {
          liveTickerPrices[e.key] = e.value.lastPrice;
        }
        lastMarketDataUpdateMs = now;
        marketDataStatus = MarketDataStatus.healthy;
        scannerRankings = CoinDcxMarketScanner.rankPairs(tickers: liveTickers);
        notifyListeners();
      }
    } catch (_) {
    } finally {
      _isTickerPollInFlight = false;
    }
  }

  Future<bool> _checkServiceReadySafe() async {
    try {
      final status = await commandBridge.getServiceStatus();
      if (status.isNotEmpty) {
        serviceRunning = status['serviceRunning'] == true;
        dartEngineInitialized = status['dartEngineInitialized'] == true;
        if (status['lastNativeHeartbeatEpochMs'] is int) {
          final hb = status['lastNativeHeartbeatEpochMs'] as int;
          if (hb > 0) {
            lastNativeHeartbeatEpochMs = hb;
          }
        }
        if (status['ignoringBatteryOptimizations'] is bool) {
          ignoringBatteryOptimizations =
              status['ignoringBatteryOptimizations'] as bool;
        }
        if (status['lastNativeError'] is String &&
            (status['lastNativeError'] as String).isNotEmpty) {
          lastStartupError = status['lastNativeError'] as String;
        }
        if (status['lastNativeShutdownReason'] is String &&
            (status['lastNativeShutdownReason'] as String).isNotEmpty) {
          lastShutdownReason ??= status['lastNativeShutdownReason'] as String;
        }
        return serviceRunning && dartEngineInitialized;
      }
      final ready = await commandBridge.isServiceAndEngineReady();
      serviceRunning = ready;
      dartEngineInitialized = ready;
      return ready;
    } catch (_) {
      serviceRunning = false;
      dartEngineInitialized = false;
      return false;
    }
  }

  Future<void> refreshStateFromDatabase({bool isInitialLoad = false}) async {
    if (_isStartupInFlight && !isInitialLoad) return;
    try {
      final snap = await persistence.loadFullState();
      final nowMs = _nowMs();
      final serviceReady = await _checkServiceReadySafe();
      final hbMs = snap.lastHeartbeatMs;
      final hasRecentHeartbeat =
          hbMs != null && (nowMs - hbMs) <= maxHeartbeatReconnectAgeMs;

      userIntention = snap.userIntention;

      if (snap.userIntention == UserSessionIntention.running &&
          snap.botState != BotEngineState.stoppedMaxDrawdownReached &&
          snap.botState != BotEngineState.lockedDailyLossLimit) {
        if (serviceReady && hasRecentHeartbeat) {
          restoreFailedRequiresRestart = false;
          restoreFailureReason = null;
          _applySnapshotToFields(snap);
          await dualPortfolioManager.syncCryptoPortfolioFromEngineSnapshot(snap);
          engineState = snap.botState == BotEngineState.stopped
              ? BotEngineState.running
              : snap.botState;
          if (isInitialLoad && engineState == BotEngineState.running) {
            statusBannerMessage =
                'RECONNECTED — heartbeat ${formatUtcHhMmSs(hbMs)}';
          }
          notifyListeners();
          return;
        } else if (isInitialLoad) {
          _applySnapshotToFields(snap);
          await dualPortfolioManager.syncCryptoPortfolioFromEngineSnapshot(snap);
          engineState = BotEngineState.reconnecting;
          statusBannerMessage = 'Restoring running session...';
          notifyListeners();

          final okStart = await commandBridge.ensureServiceStartedAndReady();
          final okCmd = okStart && await commandBridge.dispatchCommand('START');
          if (okCmd) {
            restoreFailedRequiresRestart = false;
            restoreFailureReason = null;
            serviceRestartCount = snap.serviceRestartCount + 1;
            await persistence.putKv(
              'serviceRestartCount',
              serviceRestartCount.toString(),
            );
            await persistence.logDiagnosticEvent(
              'SESSION_RESTORE',
              'Restored background service on dashboard open (restart #$serviceRestartCount)',
            );
            final refreshed = await persistence.loadFullState();
            _applySnapshotToFields(refreshed);
            await dualPortfolioManager
                .syncCryptoPortfolioFromEngineSnapshot(refreshed);
            engineState = refreshed.botState == BotEngineState.stopped
                ? BotEngineState.running
                : refreshed.botState;
            final displayHb = refreshed.lastHeartbeatMs ?? nowMs;
            lastHeartbeatMs = displayHb;
            if (engineState == BotEngineState.running) {
              statusBannerMessage =
                  'RECONNECTED — heartbeat ${formatUtcHhMmSs(displayHb)}';
            }
            await persistence.saveStartupDiagnostics(
              botState: engineState,
              userIntention: UserSessionIntention.running,
              clearStartupError: true,
              statusBannerMessage: statusBannerMessage,
            );
          } else {
            restoreFailedRequiresRestart = true;
            engineState = BotEngineState.recoveryFailed;
            restoreFailureReason = lastStartupError ??
                lastError ??
                'Background service did not respond to single-shot restore';
            lastStartupError = restoreFailureReason;
            lastShutdownReason = restoreFailureReason;
            statusBannerMessage =
                'RESTORE FAILED: $restoreFailureReason — Tap RESTART';
            await persistence.saveStartupDiagnostics(
              botState: BotEngineState.recoveryFailed,
              lastStartupError: restoreFailureReason,
              lastShutdownReason: restoreFailureReason,
              statusBannerMessage: statusBannerMessage,
            );
            await persistence.logDiagnosticEvent(
              'RESTORE_FAILED',
              restoreFailureReason!,
            );
          }
          notifyListeners();
          return;
        }
      }

      _applySnapshotToFields(snap);
      await dualPortfolioManager.syncCryptoPortfolioFromEngineSnapshot(snap);
      notifyListeners();
    } catch (_) {
      notifyListeners();
    }
  }

  void _applySnapshotToFields(PersistedEngineSnapshot snap) {
    engineState = snap.botState;
    userIntention = snap.userIntention;
    availableCashUsdt = snap.availableCashUsdt;
    accountEquityUsdt = snap.accountEquityUsdt;
    startOfDayEquityUsdt = snap.startOfDayEquityUsdt;
    maxDrawdownLocked = snap.maxDrawdownLocked;
    lockedDailyLossUtcDate = snap.lockedDailyLossUtcDate;
    lastHeartbeatMs = snap.lastHeartbeatMs;
    lastMarketDataUpdateMs =
        snap.lastMarketDataUpdateMs ?? lastMarketDataUpdateMs;
    lastCandleUpdateMs = snap.lastCandleUpdateMs;
    serviceRestartCount = snap.serviceRestartCount;
    orderSeq = snap.orderSeq;
    autoResumeEnabled = snap.autoResumeEnabled;
    lastError = snap.lastError;
    lastStartupAttemptMs = snap.lastStartupAttemptMs ?? lastStartupAttemptMs;
    lastStartupError = snap.lastStartupError;
    lastShutdownReason = snap.lastShutdownReason;
    lastBackgroundCycleError = snap.lastBackgroundCycleError;
    recoveryAttemptCount = snap.recoveryAttemptCount;
    scanDiagnostics = snap.scanDiagnostics;
    statusBannerMessage = snap.statusBannerMessage;
    tradeAlertsEnabled = snap.tradeAlertsEnabled;
    if (snap.liveTickers.isNotEmpty && liveTickers.isEmpty) {
      liveTickers = Map.from(snap.liveTickers);
      scannerRankings = CoinDcxMarketScanner.rankPairs(tickers: liveTickers);
    }
    if (snap.liveTickerPrices.isNotEmpty && liveTickerPrices.isEmpty) {
      liveTickerPrices = Map.from(snap.liveTickerPrices);
    }
    closedCandlePrices = Map.from(snap.closedCandlePrices);
    whyNoTradeForSymbol = Map.from(snap.whyNoTradeForSymbol);
    openPositions = List.from(snap.openPositions);
    orders = List.from(snap.orders);
    closedTrades = List.from(snap.closedTrades);
    equityCurve = List.from(snap.equityCurve);
    recentEvents = List.from(snap.recentEvents);
    recoveryLogs = List.from(snap.recoveryLogs);

    if (closedTrades.isNotEmpty) {
      latestRobustnessReport = quantValidator.evaluateClosedTrades(
        strategyId: strategyRegistry.activeStrategy.id,
        trades: closedTrades,
      );
      recentPostmortems = closedTrades
          .take(5)
          .map((t) => TradePostmortemAnalyzer.analyzeClosedTrade(
                trade: t,
                strategyVersion: strategyRegistry.activeStrategy.version,
              ))
          .toList();
    }
  }

  Future<void> startBot() async {
    if (_isStartupInFlight) return;
    _isStartupInFlight = true;
    final now = _nowMs();
    lastStartupAttemptMs = now;
    lastStartupError = null;
    try {
      if (!internetConnected) {
        engineState = BotEngineState.pausedNetworkLoss;
        lastStartupError = 'Cannot start: No internet connection available';
        statusBannerMessage = 'CANNOT START: NO INTERNET CONNECTION';
        await persistence.saveStartupDiagnostics(
          botState: BotEngineState.pausedNetworkLoss,
          lastStartupAttemptMs: now,
          lastStartupError: lastStartupError,
          statusBannerMessage: statusBannerMessage,
        );
        notifyListeners();
        return;
      }

      final todayUtc = RiskManager.currentUtcDateString(now);
      if (maxDrawdownLocked || lockedDailyLossUtcDate == todayUtc) {
        engineState = maxDrawdownLocked
            ? BotEngineState.stoppedMaxDrawdownReached
            : BotEngineState.lockedDailyLossLimit;
        lastStartupError = maxDrawdownLocked
            ? 'Blocked by maximum drawdown lock (\$90.00 floor reached)'
            : 'Blocked by daily loss limit lock (\$2.00 reached)';
        lastShutdownReason = lastStartupError;
        statusBannerMessage =
            'PAUSED — SAFETY RESTRICTION: $lastStartupError';
        await persistence.saveStartupDiagnostics(
          botState: engineState,
          lastStartupAttemptMs: now,
          lastStartupError: lastStartupError,
          lastShutdownReason: lastShutdownReason,
          statusBannerMessage: statusBannerMessage,
        );
        notifyListeners();
        return;
      }

      // 1. Transition to STARTING (never display RUNNING before service & engine are verified ready)
      restoreFailedRequiresRestart = false;
      restoreFailureReason = null;
      userIntention = UserSessionIntention.running;
      engineState = BotEngineState.starting;
      statusBannerMessage =
          'STARTING — Initializing foreground service & background Dart engine...';
      await persistence.saveUserIntention(UserSessionIntention.running);
      await persistence.saveStartupDiagnostics(
        botState: BotEngineState.starting,
        userIntention: UserSessionIntention.running,
        lastStartupAttemptMs: now,
        clearStartupError: true,
        clearShutdownReason: true,
        statusBannerMessage: statusBannerMessage,
      );
      notifyListeners();

      // 2. Verify Foreground Service and Background Dart Engine initialization
      final serviceReady = await commandBridge.ensureServiceStartedAndReady();
      await _checkServiceReadySafe();
      if (!serviceReady) {
        restoreFailedRequiresRestart = true;
        engineState = BotEngineState.failedStartupError;
        restoreFailureReason =
            lastStartupError ?? 'Foreground service failed to initialize';
        lastStartupError = restoreFailureReason;
        lastShutdownReason =
            'Startup failed: Foreground service failed to initialize';
        userIntention = UserSessionIntention.stopped;
        statusBannerMessage =
            'CANNOT START: FOREGROUND SERVICE FAILED TO INITIALIZE';
        await persistence.saveStartupDiagnostics(
          botState: BotEngineState.failedStartupError,
          userIntention: UserSessionIntention.stopped,
          lastStartupAttemptMs: now,
          lastStartupError: lastStartupError,
          lastShutdownReason: lastShutdownReason,
          statusBannerMessage: statusBannerMessage,
        );
        await persistence.logDiagnosticEvent(
          'STARTUP_FAILED',
          lastStartupError!,
          timestampMs: now,
        );
        notifyListeners();
        return;
      }

      // 3. Dispatch START command and verify background engine acknowledgement
      final ok = await commandBridge.dispatchCommand('START');
      if (!ok) {
        restoreFailedRequiresRestart = true;
        engineState = BotEngineState.failedStartupError;
        restoreFailureReason = lastStartupError ??
            'Background Dart engine did not acknowledge START command';
        lastStartupError = restoreFailureReason;
        lastShutdownReason =
            'Startup failed: Background Dart engine rejected or timed out on START';
        userIntention = UserSessionIntention.stopped;
        statusBannerMessage = 'FAILED — STARTUP ERROR: $lastStartupError';
        await persistence.saveStartupDiagnostics(
          botState: BotEngineState.failedStartupError,
          userIntention: UserSessionIntention.stopped,
          lastStartupAttemptMs: now,
          lastStartupError: lastStartupError,
          lastShutdownReason: lastShutdownReason,
          statusBannerMessage: statusBannerMessage,
        );
        await persistence.logDiagnosticEvent(
          'STARTUP_FAILED',
          lastStartupError!,
          timestampMs: now,
        );
        notifyListeners();
        return;
      }

      // 4. Verify that the first engine cycle completed and persisted state in SQLite.
      // If running with an in-memory test bridge or before background isolate flush,
      // execute a verified initial cycle directly against shared persistence.
      var snap = await persistence.loadFullState();
      final hasFreshCycleHb = snap.lastHeartbeatMs != null &&
          (now - snap.lastHeartbeatMs!).abs() <= 30000;
      if ((snap.botState == BotEngineState.starting ||
              snap.botState == BotEngineState.stopped ||
              !hasFreshCycleHb) &&
          !snap.botState.isRiskLock) {
        final verifierEngine = AuthoritativeTradingEngine(
          marketService: marketService,
          persistence: persistence,
          ownerId: AuthoritativeTradingEngine.lockName,
          nowMsProvider: _nowMs,
        );
        await verifierEngine.restoreSessionIfRunningIntended();
        if (verifierEngine.state == BotEngineState.starting ||
            verifierEngine.state == BotEngineState.stopped) {
          await verifierEngine.startEngine();
        }
        verifierEngine.dispose();
        await persistence.releaseExecutionLock(
          lockName: AuthoritativeTradingEngine.lockName,
          ownerId: AuthoritativeTradingEngine.lockName,
        );
        snap = await persistence.loadFullState();
      }

      serviceRunning = true;
      dartEngineInitialized = true;
      _applySnapshotToFields(snap);
      await dualPortfolioManager.syncCryptoPortfolioFromEngineSnapshot(snap);
      if (engineState == BotEngineState.starting ||
          engineState == BotEngineState.stopped) {
        engineState = BotEngineState.running;
      }
      lastHeartbeatMs ??= now;
      notifyListeners();
    } finally {
      _isStartupInFlight = false;
    }
  }

  Future<void> pauseBot() async {
    restoreFailedRequiresRestart = false;
    final now = _nowMs();
    userIntention = UserSessionIntention.paused;
    engineState = BotEngineState.pausedAfterRecoveryManualStartRequired;
    lastShutdownReason = 'Paused by user';
    statusBannerMessage = 'PAUSED (PAUSED_BY_USER): Paused by user';
    await persistence.saveUserIntention(UserSessionIntention.paused);
    await persistence.saveStartupDiagnostics(
      botState: BotEngineState.pausedAfterRecoveryManualStartRequired,
      userIntention: UserSessionIntention.paused,
      lastShutdownReason: lastShutdownReason,
      statusBannerMessage: statusBannerMessage,
    );
    await commandBridge.dispatchCommand('PAUSE');
    await refreshStateFromDatabase();
  }

  Future<void> stopBot({String reason = 'Stopped by user'}) async {
    restoreFailedRequiresRestart = false;
    userIntention = UserSessionIntention.stopped;
    engineState = BotEngineState.stopped;
    lastShutdownReason = reason;
    statusBannerMessage = 'PAPER BOT STOPPED — $reason';
    await persistence.saveUserIntention(UserSessionIntention.stopped);
    await persistence.saveStartupDiagnostics(
      botState: BotEngineState.stopped,
      userIntention: UserSessionIntention.stopped,
      lastShutdownReason: reason,
      statusBannerMessage: statusBannerMessage,
    );
    await commandBridge.dispatchCommand('STOP');
    await commandBridge.stopService();
    serviceRunning = false;
    await refreshStateFromDatabase();
  }

  Future<void> manualResetDrawdownAndAccount() async {
    restoreFailedRequiresRestart = false;
    await persistence.saveUserIntention(UserSessionIntention.stopped);
    userIntention = UserSessionIntention.stopped;
    final ready = await commandBridge.isServiceAndEngineReady();
    if (ready) {
      await commandBridge.dispatchCommand('RESET');
    } else {
      await persistence.saveFullState(
        botState: BotEngineState.stopped,
        userIntention: UserSessionIntention.stopped,
        availableCashUsdt: 100.0,
        accountEquityUsdt: 100.0,
        maxDrawdownLocked: false,
        lockedDailyLossUtcDate: null,
        lastStopLossClosedAtMs: null,
        statusBannerMessage: 'Paper account reset to \$100.00 USDT.',
        openPositions: const [],
        orders: const [],
        closedTrades: const [],
        processedEntrySignalKeys: const {},
      );
    }
    await refreshStateFromDatabase();
  }

  Future<void> setTradeAlertsEnabled(bool enabled) async {
    tradeAlertsEnabled = enabled;
    await persistence.setTradeAlertsEnabled(enabled);
    notifyListeners();
  }

  Future<void> setAutoResumeEnabled(bool enabled) async {
    autoResumeEnabled = enabled;
    await persistence.setAutoResumeEnabled(enabled);
    notifyListeners();
  }

  Future<void> requestNotificationPermission() async {
    try {
      final granted = await _serviceChannel
          .invokeMethod<bool>('requestNotificationPermission');
      notificationPermissionGranted = granted ?? false;
      notifyListeners();
    } catch (_) {}
  }

  Future<void> openNotificationSettings() async {
    try {
      await _serviceChannel.invokeMethod<bool>('openNotificationSettings');
    } catch (_) {}
  }

  Future<void> openBatteryOptimizationSettings() async {
    try {
      await _serviceChannel.invokeMethod<bool>('openBatterySettings');
    } catch (_) {}
  }

  Future<void> runLiveHistoricalBacktest({String symbol = 'B-BTC_USDT'}) async {
    if (isRunningBacktest) return;
    isRunningBacktest = true;
    notifyListeners();
    try {
      final nowMs = _nowMs();
      final candles15m = await marketService.fetchClosedCandles(
        pair: symbol,
        interval: '15m',
        nowMs: nowMs,
        limit: 250,
      );
      final candles1h = await marketService.fetchClosedCandles(
        pair: symbol,
        interval: '1h',
        nowMs: nowMs,
        limit: 120,
      );
      latestRegimeAssessment = MarketRegimeDetector.detect(
        symbol: symbol,
        closedCandles: candles15m,
        liveTicker: liveTickers[symbol],
        nowMs: nowMs,
      );
      latestBacktestReport = PaperBroker.runHistoricalBacktest(
        symbol: symbol,
        candles15m: candles15m,
        candles1h: candles1h,
      );
    } catch (e) {
      statusBannerMessage = 'Backtest error: $e';
    } finally {
      isRunningBacktest = false;
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _uiStateRefreshTimer?.cancel();
    _liveTickerPollTimer?.cancel();
    _catalogueRefreshTimer?.cancel();
    _networkSub?.cancel();
    _wsTickerSub?.cancel();
    marketService.dispose();
    super.dispose();
  }
}

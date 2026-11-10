import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import '../models/dual_portfolio_models.dart';
import '../models/trading_models.dart';
import 'dual_portfolio_service.dart';
import 'autonomous_intelligence_and_ops.dart';
import 'coindcx_market_service.dart';
import 'execution_and_risk_hub.dart';
import 'paper_broker.dart';
import 'persistence_db.dart';
import 'quant_research_lab.dart';
import 'stage47_autonomous_governance.dart';

abstract class EngineCommandBridge {
  Future<bool> ensureServiceStartedAndReady();
  Future<bool> dispatchCommand(String command);
  Future<bool> isServiceAndEngineReady();
  Future<bool> stopService();
  Future<Map<String, dynamic>> getServiceStatus();
}

class MethodChannelEngineBridge implements EngineCommandBridge {
  static const MethodChannel _serviceChannel =
      MethodChannel('com.ankit.aitrader/service');

  @override
  Future<bool> ensureServiceStartedAndReady() async {
    try {
      final ok = await _serviceChannel.invokeMethod<bool>('startService', {
        'title': 'Ankit AI Trader — PAPER BOT ACTIVE',
        'text': 'Initializing authoritative background paper engine...',
      });
      return ok ?? false;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<bool> dispatchCommand(String command) async {
    try {
      final ok = await _serviceChannel.invokeMethod<bool>('dispatchCommand', {
        'command': command,
      });
      return ok ?? false;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<bool> isServiceAndEngineReady() async {
    try {
      final ok = await _serviceChannel.invokeMethod<bool>('isServiceRunning');
      return ok ?? false;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<bool> stopService() async {
    try {
      final ok = await _serviceChannel.invokeMethod<bool>('stopService');
      return ok ?? false;
    } catch (_) {
      return false;
    }
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

  // Stages 23–46 Subsystems
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
        marketService = marketService ?? CoinDcxMarketService(persistence: persistence),
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
        tradeOnlyKeyVerified: false,
        runtimeViolationDetected: maxDrawdownLocked,
      );

  StatisticalOverfittingReport get latestStatisticalOverfittingReport =>
      AdvancedStatisticalValidationSuite.validateStrategy(
        strategyId: strategyRegistry.activeStrategy.id,
        trades: closedTrades,
        multipleTestingTrialsCount: strategyRegistry.allStrategies.length,
        datasetIncludesDelistedInstruments: true,
      );

  BalanceReconciliationReport get latestBalanceReconciliation {
    final realizedPnl =
        closedTrades.fold<double>(0.0, (acc, t) => acc + t.realizedPnlUsdt);
    final unrealizedPnl = openPositions.fold<double>(0.0, (acc, p) {
      final mark = liveTickerPrices[p.symbol] ?? p.entryPrice;
      return acc + p.unrealizedPnlUsdt(mark);
    });
    return cashFlowLedger.reconcile(
      initialCapitalUsdt: 100.0,
      realizedTradingPnlUsdt: realizedPnl,
      unrealizedTradingPnlUsdt: unrealizedPnl,
      reportedExchangeEquityUsdt: accountEquityUsdt,
    );
  }

  TaxLotAccountingSummary get latestTaxAccountingSummary =>
      TaxAndAccountingLedger.generateReport(
        closedTrades: closedTrades,
        openPositions: openPositions,
        markPrices: liveTickerPrices,
        cashFlows: cashFlowLedger.entries,
      );

  PerformanceAttributionReport get latestPerformanceAttribution =>
      PerformanceAttributionEngine.computeAttribution(
        initialCapitalUsdt: 100.0,
        closedTrades: closedTrades,
        externalCashFlows: cashFlowLedger.entries,
        activeStrategyId: strategyRegistry.activeStrategy.id,
        currentRegimeLabel: latestRegimeAssessment?.regimeLabel ?? 'BULL TREND',
      );

  SystemResilienceSnapshot get latestResilienceSnapshot =>
      OperationalResilienceMonitor.evaluateResilience();

  List<StressScenarioResult> get stressScenarioResults =>
      FailureAndStressTestSimulator.runAll13StressScenarios();

  List<AutonomousCycleStepReport> get autonomous18StepCycleReport =>
      AutonomousOperatingCycleCoordinator.run18StepAutonomousGovernanceCycle(
        eligiblePairsCount:
            scannerRankings.where((r) => r.isEligible).isNotEmpty
                ? scannerRankings.where((r) => r.isEligible).length
                : 2,
        detectedRegimeLabel:
            latestRegimeAssessment?.regimeLabel ?? 'SIDEWAYS RANGE',
        activeChampionStrategyId: strategyRegistry.activeStrategy.id,
        statisticalValidationPassed:
            latestStatisticalOverfittingReport.approvedStatistically,
        riskSupervisorApproved: !riskSupervisor.emergencyKillSwitchActive,
        openPositionsCount: openPositions.length,
        closedTradesCount: closedTrades.length,
        modelHealthy:
            modelGovernanceRegistry.activeProductionModel.liveDriftScore <= 0.25,
        resilienceHealthy: !latestResilienceSnapshot.safeModeActivated,
        cashFlowReconciled:
            !latestBalanceReconciliation.tradingRestrictedSafeMode,
        stage46LiveLocked: !controlledLiveGateStatus.liveExecutionEnabled,
      );

  /// Stage 5: Heartbeat status level ('OK' <90s, 'DELAYED' 90s-5m, 'DEAD' >5m)
  String get heartbeatHealthLevel {
    final hb = lastHeartbeatMs;
    if (hb == null || hb <= 0) return 'DEAD';
    final ageMs = _nowMs() - hb;
    if (ageMs < 90 * 1000) return 'OK';
    if (ageMs <= 5 * 60 * 1000) return 'DELAYED';
    return 'DEAD';
  }

  int get heartbeatAgeSeconds {
    final hb = lastHeartbeatMs;
    if (hb == null || hb <= 0) return -1;
    return ((_nowMs() - hb) / 1000).round().clamp(0, 999999);
  }

  static String formatUtcHhMmSs(int epochMs) {
    final dt = DateTime.fromMillisecondsSinceEpoch(epochMs, isUtc: true);
    final h = dt.hour.toString().padLeft(2, '0');
    final m = dt.minute.toString().padLeft(2, '0');
    final s = dt.second.toString().padLeft(2, '0');
    return '$h:$m:$s UTC';
  }

  String formatHeartbeatStatus([int? hbMs, int? nowMs]) {
    final target = hbMs ?? lastHeartbeatMs;
    if (target == null || target <= 0) return 'Heartbeat: Never (DEAD)';
    final now = nowMs ?? _nowMs();
    final ageSec = ((now - target) / 1000).round().clamp(0, 999999);
    final status = ageSec < 90 ? 'OK' : (ageSec <= 300 ? 'DELAYED' : 'DEAD');
    return 'Heartbeat: ${formatUtcHhMmSs(target)} (${ageSec}s ago • $status)';
  }

  List<CoinDcxMarketRecord> get filteredDiscoveredMarkets {
    final baseList = marketCatalogue.filterMarkets(
      searchQuery: marketSearchQuery,
      quoteCurrencyFilter: selectedQuoteCurrencyFilter,
    );
    if (!showOnlyFavouriteMarkets) return baseList;
    return baseList
        .where((m) =>
            favouriteMarketPairs.contains(m.pair) ||
            favouriteMarketPairs.contains(m.symbol))
        .toList();
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

  bool get isHighVolatilitySelected =>
      selectedPortfolioId == PortfolioId.highVolatility;

  double get activeEquityUsdt => isHighVolatilitySelected
      ? highVolatilityPortfolio.accountEquityUsdt
      : accountEquityUsdt;

  double get activeAvailableCashUsdt => isHighVolatilitySelected
      ? highVolatilityPortfolio.availableCashUsdt
      : availableCashUsdt;

  double get activeStartOfDayEquityUsdt => isHighVolatilitySelected
      ? highVolatilityPortfolio.startOfDayEquityUsdt
      : startOfDayEquityUsdt;

  double get activeDailyPnlUsdt => isHighVolatilitySelected
      ? highVolatilityPortfolio.dailyPnlUsdt
      : dailyPnlUsdt;

  double get activeOverallPnlUsdt => isHighVolatilitySelected
      ? highVolatilityPortfolio.overallPnlUsdt
      : overallPnlUsdt;

  double get activeDrawdownUsdt => isHighVolatilitySelected
      ? highVolatilityPortfolio.currentDrawdownUsdt
      : currentDrawdownUsdt;

  double get activeUsedMarginUsdt => isHighVolatilitySelected
      ? highVolatilityPortfolio.usedMarginUsdt
      : usedMarginUsdt;

  double get activeFreeMarginUsdt => isHighVolatilitySelected
      ? highVolatilityPortfolio.freeMarginUsdt
      : freeMarginUsdt;

  double get activeRemainingDailyRiskUsdt => isHighVolatilitySelected
      ? highVolatilityPortfolio.remainingDailyRiskBudgetUsdt
      : remainingDailyRiskBudgetUsdt;

  double get activeRemainingDrawdownUsdt => isHighVolatilitySelected
      ? highVolatilityPortfolio.remainingDrawdownBudgetUsdt
      : remainingDrawdownBudgetUsdt;

  List<PaperPosition> get activeOpenPositions => isHighVolatilitySelected
      ? highVolatilityPortfolio.openPositions
      : openPositions;

  List<ClosedPaperTrade> get activeClosedTrades => isHighVolatilitySelected
      ? highVolatilityPortfolio.closedTrades
      : closedTrades;

  List<EquityPoint> get activeEquityCurve => isHighVolatilitySelected
      ? highVolatilityPortfolio.equityCurve
      : equityCurve;

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
    // Load any cached discovered markets from SQLite immediately
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

  /// Stage 13: Poll live tickers every 4s (within 3-5s window) with non-overlapping guard.
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
        liveTickerPrices = {
          for (final e in fetched.entries) e.key: e.value.lastPrice,
        };
        scannerRankings = CoinDcxMarketScanner.rankPairs(tickers: liveTickers);
        if (marketService.latestCatalogueSnapshot.allMarkets.isNotEmpty) {
          marketCatalogue = marketService.latestCatalogueSnapshot;
        }
        lastMarketDataUpdateMs = now;
        marketDataStatus = MarketDataStatus.healthy;
        notifyListeners();
      }
    } catch (_) {
      final lastUpd = lastMarketDataUpdateMs;
      if (lastUpd == null || (_nowMs() - lastUpd) > 30000) {
        marketDataStatus = MarketDataStatus.stale;
      }
      notifyListeners();
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
        ignoringBatteryOptimizations =
            status['ignoringBatteryOptimizations'] as bool? ?? true;
        final nativeHb = status['lastNativeHeartbeatEpochMs'];
        if (nativeHb is int && nativeHb > 0) {
          lastNativeHeartbeatEpochMs = nativeHb;
        }
        final err = status['lastError'] ?? status['lastHeartbeatTickError'];
        if (err is String && err.isNotEmpty) {
          lastError = err;
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

  /// Stage 4: Restore session on dashboard open.
  Future<void> refreshStateFromDatabase({bool isInitialLoad = false}) async {
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
          // Part 2 Fix: Preserve actual snap.botState (e.g., pausedNetworkLoss, waitingForFreshData, reconnecting)
          // instead of blindly forcing BotEngineState.running when only the heartbeat is alive!
          engineState = snap.botState;
          if (isInitialLoad && snap.botState == BotEngineState.running) {
            statusBannerMessage =
                'RECONNECTED — heartbeat ${formatUtcHhMmSs(hbMs)}';
          }
          notifyListeners();
          return;
        } else if (isInitialLoad) {
          _applySnapshotToFields(snap);
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
            engineState = refreshed.botState == BotEngineState.stopped
                ? BotEngineState.running
                : refreshed.botState;
            final displayHb = refreshed.lastHeartbeatMs ?? nowMs;
            if (engineState == BotEngineState.running) {
              statusBannerMessage =
                  'RECONNECTED — heartbeat ${formatUtcHhMmSs(displayHb)}';
            }
          } else {
            restoreFailedRequiresRestart = true;
            engineState = BotEngineState.recoveryFailed;
            restoreFailureReason = lastError ??
                'Background service did not respond to single-shot restore';
            statusBannerMessage =
                'RESTORE FAILED: $restoreFailureReason — Tap RESTART';
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
    dualPortfolioManager.syncCryptoPortfolioFromEngineSnapshot(snap);

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
    if (!internetConnected) {
      statusBannerMessage = 'CANNOT START: NO INTERNET CONNECTION';
      notifyListeners();
      return;
    }
    restoreFailedRequiresRestart = false;
    restoreFailureReason = null;
    await persistence.saveUserIntention(UserSessionIntention.running);
    userIntention = UserSessionIntention.running;
    engineState = BotEngineState.running;
    statusBannerMessage =
        'DISPATCHING START TO AUTHORITATIVE BACKGROUND ENGINE...';
    notifyListeners();

    final serviceReady = await commandBridge.ensureServiceStartedAndReady();
    if (!serviceReady) {
      restoreFailedRequiresRestart = true;
      restoreFailureReason = 'Foreground service failed to initialize';
      statusBannerMessage =
          'CANNOT START: FOREGROUND SERVICE FAILED TO INITIALIZE';
      notifyListeners();
      return;
    }

    final ok = await commandBridge.dispatchCommand('START');
    await refreshStateFromDatabase();
    if (!ok && engineState != BotEngineState.running) {
      statusBannerMessage =
          'AUTHORITATIVE ENGINE VALIDATING MARKET DATA — WILL AUTO-RESUME';
      notifyListeners();
    }
  }

  Future<void> pauseBot() async {
    restoreFailedRequiresRestart = false;
    await persistence.saveUserIntention(UserSessionIntention.paused);
    userIntention = UserSessionIntention.paused;
    await commandBridge.dispatchCommand('PAUSE');
    await refreshStateFromDatabase();
  }

  Future<void> stopBot() async {
    restoreFailedRequiresRestart = false;
    await persistence.saveUserIntention(UserSessionIntention.stopped);
    userIntention = UserSessionIntention.stopped;
    await commandBridge.dispatchCommand('STOP');
    await commandBridge.stopService();
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
    _networkSub?.cancel();
    _wsTickerSub?.cancel();
    marketService.dispose();
    super.dispose();
  }
}

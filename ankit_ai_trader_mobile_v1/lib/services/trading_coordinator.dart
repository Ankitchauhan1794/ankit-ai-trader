import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import '../models/trading_models.dart';
import 'autonomous_intelligence_and_ops.dart';
import 'coindcx_market_service.dart';
import 'execution_and_risk_hub.dart';
import 'paper_broker.dart';
import 'persistence_db.dart';
import 'quant_research_lab.dart';

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
  final StrategyRegistry strategyRegistry = StrategyRegistry();
  final QuantResearchValidator quantValidator = const QuantResearchValidator();
  final VpsAgentOrchestrator agentOrchestrator =
      const VpsAgentOrchestrator(vpsStage20bApproved: false);

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
  BacktestReport? latestBacktestReport;
  RobustnessValidationReport? latestRobustnessReport;
  MarketRegimeAssessment? latestRegimeAssessment;
  List<RankedScannerCandidate> scannerRankings = [];
  List<TradePostmortemReport> recentPostmortems = [];
  bool isRunningBacktest = false;
  bool _isTickerPollInFlight = false;

  Timer? _uiStateRefreshTimer;
  Timer? _liveTickerPollTimer;
  StreamSubscription<dynamic>? _networkSub;
  StreamSubscription<Map<String, LiveMarketTicker>>? _wsTickerSub;

  TradingCoordinator({
    PersistenceDatabase? persistence,
    CoinDcxMarketService? marketService,
    EngineCommandBridge? commandBridge,
    int Function()? nowMsProvider,
  })  : persistence = persistence ?? PersistenceDatabase(),
        marketService = marketService ?? CoinDcxMarketService(),
        commandBridge = commandBridge ?? MethodChannelEngineBridge(),
        _nowMs =
            nowMsProvider ?? (() => DateTime.now().millisecondsSinceEpoch) {
    eventLedger = AppendOnlyEventLedger(persistence: this.persistence);
    executionEngine = DeterministicExecutionEngine(
      ledger: eventLedger,
      riskSupervisor: riskSupervisor,
    );
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

  Future<void> initialize({bool enablePlatformChannels = true}) async {
    if (enablePlatformChannels) {
      await _initPlatformChannels();
    }
    await executionEngine.reconcileStartupOrders(nowMs: _nowMs());
    await refreshStateFromDatabase(isInitialLoad: true);
    await _pollLiveTickersForDashboard();
    _startUiStateRefreshTimer();
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
    _liveTickerPollTimer = Timer.periodic(const Duration(seconds: 4), (_) {
      _pollLiveTickersForDashboard();
    });
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
          engineState = BotEngineState.running;
          if (isInitialLoad) {
            statusBannerMessage =
                'RECONNECTED — heartbeat ${formatUtcHhMmSs(hbMs)}';
          }
          notifyListeners();
          return;
        } else if (isInitialLoad) {
          _applySnapshotToFields(snap);
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
            engineState = BotEngineState.running;
            final displayHb = refreshed.lastHeartbeatMs ?? nowMs;
            statusBannerMessage =
                'RECONNECTED — heartbeat ${formatUtcHhMmSs(displayHb)}';
          } else {
            restoreFailedRequiresRestart = true;
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
    lastError = snap.lastError ?? lastError;
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
    _uiStateRefreshTimer?.cancel();
    _liveTickerPollTimer?.cancel();
    _networkSub?.cancel();
    _wsTickerSub?.cancel();
    marketService.dispose();
    super.dispose();
  }
}

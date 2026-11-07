import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import '../models/trading_models.dart';
import 'coindcx_market_service.dart';
import 'paper_broker.dart';
import 'persistence_db.dart';

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
      final ok =
          await _serviceChannel.invokeMethod<bool>('isServiceRunning');
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

  BotEngineState engineState = BotEngineState.stopped;
  UserSessionIntention userIntention = UserSessionIntention.stopped;
  MarketDataStatus marketDataStatus = MarketDataStatus.warmingUp;

  double availableCashUsdt = 100.0;
  double accountEquityUsdt = 100.0;
  bool maxDrawdownLocked = false;
  String? lockedDailyLossUtcDate;
  int? lastHeartbeatMs;
  int? lastNativeHeartbeatEpochMs;
  int? lastMarketDataUpdateMs;
  bool serviceRunning = false;
  bool dartEngineInitialized = false;
  bool ignoringBatteryOptimizations = true;
  bool notificationPermissionGranted = true;
  bool tradeAlertsEnabled = true;
  bool internetConnected = true;

  String statusBannerMessage = 'PAPER BOT STOPPED — PRESS START';
  Map<String, double> liveTickerPrices = {};
  Map<String, LiveMarketTicker> liveTickers = {};
  Map<String, double> closedCandlePrices = {};
  Map<String, String> whyNoTradeForSymbol = {};
  List<PaperPosition> openPositions = [];
  List<SimulatedOrder> orders = [];
  List<ClosedPaperTrade> closedTrades = [];
  List<String> recoveryLogs = [];
  BacktestReport? latestBacktestReport;
  bool isRunningBacktest = false;

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
            nowMsProvider ?? (() => DateTime.now().millisecondsSinceEpoch);

  bool get isPaused =>
      engineState == BotEngineState.pausedNetworkLoss ||
      engineState == BotEngineState.pausedStaleData ||
      engineState == BotEngineState.pausedAfterRecoveryManualStartRequired;

  double get currentDrawdownUsdt =>
      (100.0 - accountEquityUsdt).clamp(0.0, 100.0);

  static String formatUtcHhMmSs(int epochMs) {
    final dt = DateTime.fromMillisecondsSinceEpoch(epochMs, isUtc: true);
    final h = dt.hour.toString().padLeft(2, '0');
    final m = dt.minute.toString().padLeft(2, '0');
    final s = dt.second.toString().padLeft(2, '0');
    return '$h:$m:$s UTC';
  }

  String formatHeartbeatStatus([int? hbMs, int? nowMs]) {
    final target = hbMs ?? lastHeartbeatMs;
    if (target == null || target <= 0) return 'Heartbeat: Never';
    final now = nowMs ?? _nowMs();
    final ageSec = ((now - target) / 1000).round().clamp(0, 999999);
    return 'Heartbeat: ${formatUtcHhMmSs(target)} (${ageSec}s ago)';
  }

  Future<void> initialize({bool enablePlatformChannels = true}) async {
    if (enablePlatformChannels) {
      await _initPlatformChannels();
    }
    await refreshStateFromDatabase(isInitialLoad: true);
    await _pollLiveTickersForDashboard();
    await marketService.connectWebSocketFeed();
    _wsTickerSub?.cancel();
    _wsTickerSub = marketService.tickerStream.listen((tickers) {
      if (tickers.isEmpty) return;
      liveTickers = Map.from(tickers);
      liveTickerPrices = {
        for (final e in tickers.entries) e.key: e.value.lastPrice,
      };
      lastMarketDataUpdateMs = _nowMs();
      marketDataStatus = MarketDataStatus.healthy;
      notifyListeners();
    });
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

  void _startUiStateRefreshTimer() {
    _uiStateRefreshTimer?.cancel();
    _uiStateRefreshTimer = Timer.periodic(const Duration(seconds: 4), (_) {
      refreshStateFromDatabase(isInitialLoad: false);
    });
    _liveTickerPollTimer?.cancel();
    _liveTickerPollTimer = Timer.periodic(const Duration(seconds: 10), (_) {
      _pollLiveTickersForDashboard();
    });
  }

  Future<void> _pollLiveTickersForDashboard() async {
    try {
      final fetched = await marketService.fetchLiveTickers(nowMs: _nowMs());
      if (fetched.isNotEmpty) {
        liveTickers = Map.from(fetched);
        liveTickerPrices = {
          for (final e in fetched.entries) e.key: e.value.lastPrice,
        };
        lastMarketDataUpdateMs = _nowMs();
        marketDataStatus = MarketDataStatus.healthy;
        notifyListeners();
      }
    } catch (_) {
      if (liveTickers.isEmpty) {
        marketDataStatus = MarketDataStatus.disconnected;
        notifyListeners();
      }
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
        return serviceRunning && dartEngineInitialized;
      }
      return await commandBridge.isServiceAndEngineReady();
    } catch (_) {
      return false;
    }
  }

  /// Stage 3 & 4: Restore previous session when dashboard opens without overwriting running intention!
  Future<void> refreshStateFromDatabase({bool isInitialLoad = false}) async {
    try {
      final snap = await persistence.loadFullState();
      final nowMs = _nowMs();
      final serviceReady = await _checkServiceReadySafe();
      final hbMs = snap.lastHeartbeatMs;
      final hasRecentHeartbeat =
          hbMs != null && (nowMs - hbMs) <= maxHeartbeatReconnectAgeMs;

      userIntention = snap.userIntention;

      // Stage 3 Fix: If the user intended the bot to be RUNNING (and no hard risk lock was hit),
      // automatically self-heal and restart the background service if either !serviceReady OR !hasRecentHeartbeat.
      if (snap.userIntention == UserSessionIntention.running &&
          snap.botState != BotEngineState.stoppedMaxDrawdownReached &&
          snap.botState != BotEngineState.lockedDailyLossLimit) {
        if (!serviceReady || !hasRecentHeartbeat) {
          _applySnapshotToFields(snap);
          engineState = BotEngineState.running;
          statusBannerMessage =
              'RESTORING RUNNING SESSION — SELF-HEALING BACKGROUND ENGINE...';
          notifyListeners();

          final okService = await commandBridge.ensureServiceStartedAndReady();
          if (okService) {
            await commandBridge.dispatchCommand('START');
            final updated = await persistence.loadFullState();
            _applySnapshotToFields(updated);
            engineState = BotEngineState.running;
            final displayHb = updated.lastHeartbeatMs ?? nowMs;
            statusBannerMessage =
                'RECONNECTED – heartbeat ${formatUtcHhMmSs(displayHb)}';
          } else {
            engineState = BotEngineState.pausedNetworkLoss;
            statusBannerMessage =
                'SESSION INTENTION: RUNNING — WAITING FOR SERVICE / NETWORK AUTO-RECOVERY';
          }
          notifyListeners();
          return;
        } else if (isInitialLoad) {
          _applySnapshotToFields(snap);
          engineState = BotEngineState.running;
          statusBannerMessage =
              'RECONNECTED – heartbeat ${formatUtcHhMmSs(hbMs)}';
          notifyListeners();
          return;
        }
      }

      _applySnapshotToFields(snap);
      notifyListeners();
    } catch (_) {
      // Stage 3 Fix: Do not overwrite engineState to pausedStaleData on transient SQLite read error
      notifyListeners();
    }
  }

  void _applySnapshotToFields(PersistedEngineSnapshot snap) {
    engineState = snap.botState;
    userIntention = snap.userIntention;
    availableCashUsdt = snap.availableCashUsdt;
    accountEquityUsdt = snap.accountEquityUsdt;
    maxDrawdownLocked = snap.maxDrawdownLocked;
    lockedDailyLossUtcDate = snap.lockedDailyLossUtcDate;
    lastHeartbeatMs = snap.lastHeartbeatMs;
    lastMarketDataUpdateMs = snap.lastMarketDataUpdateMs;
    statusBannerMessage = snap.statusBannerMessage;
    tradeAlertsEnabled = snap.tradeAlertsEnabled;
    if (snap.liveTickers.isNotEmpty) {
      liveTickers = Map.from(snap.liveTickers);
    }
    if (snap.liveTickerPrices.isNotEmpty) {
      liveTickerPrices = Map.from(snap.liveTickerPrices);
    }
    closedCandlePrices = Map.from(snap.closedCandlePrices);
    whyNoTradeForSymbol = Map.from(snap.whyNoTradeForSymbol);
    openPositions = List.from(snap.openPositions);
    orders = List.from(snap.orders);
    closedTrades = List.from(snap.closedTrades);
    recoveryLogs = List.from(snap.recoveryLogs);
  }

  Future<void> startBot() async {
    if (!internetConnected) {
      statusBannerMessage = 'CANNOT START: NO INTERNET CONNECTION';
      notifyListeners();
      return;
    }
    await persistence.saveUserIntention(UserSessionIntention.running);
    userIntention = UserSessionIntention.running;
    engineState = BotEngineState.running;
    statusBannerMessage =
        'DISPATCHING START TO AUTHORITATIVE BACKGROUND ENGINE...';
    notifyListeners();

    final serviceReady = await commandBridge.ensureServiceStartedAndReady();
    if (!serviceReady) {
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
    await persistence.saveUserIntention(UserSessionIntention.paused);
    userIntention = UserSessionIntention.paused;
    await commandBridge.dispatchCommand('PAUSE');
    await refreshStateFromDatabase();
  }

  Future<void> stopBot() async {
    await persistence.saveUserIntention(UserSessionIntention.stopped);
    userIntention = UserSessionIntention.stopped;
    await commandBridge.dispatchCommand('STOP');
    await commandBridge.stopService();
    await refreshStateFromDatabase();
  }

  Future<void> manualResetDrawdownAndAccount() async {
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

import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import '../models/trading_models.dart';
import 'authoritative_engine.dart';
import 'coindcx_market_service.dart';
import 'paper_broker.dart';
import 'persistence_db.dart';
import 'strategy_engine.dart';

class MethodChannelEngineBridge implements EngineCommandBridge {
  static const MethodChannel _serviceChannel =
      MethodChannel('com.ankit.aitrader/service');

  @override
  Future<bool> ensureServiceStartedAndReady() async {
    final ok = await _serviceChannel.invokeMethod<bool>('startService', {
      'title': 'Ankit AI Trader — PAPER BOT ACTIVE',
      'text': 'Initializing authoritative background paper engine...',
    });
    return ok ?? false;
  }

  @override
  Future<bool> dispatchCommand(String command) async {
    final ok = await _serviceChannel.invokeMethod<bool>('dispatchCommand', {
      'command': command,
    });
    return ok ?? false;
  }

  @override
  Future<void> notifyNetworkChanged(bool isConnected) async {
    try {
      await _serviceChannel.invokeMethod<bool>('notifyNetworkChanged', {
        'connected': isConnected,
      });
    } catch (_) {}
  }

  @override
  Future<bool> isServiceAndEngineReady() async {
    final ok =
        await _serviceChannel.invokeMethod<bool>('isServiceRunning') ?? false;
    return ok;
  }
}

/// UI Dashboard state reader and command dispatcher.
///
/// STRICT SINGLE-ENGINE ARCHITECTURE:
/// `TradingCoordinator` NEVER executes `broker.processClosedCandleStream`, NEVER places
/// orders, and NEVER runs a second trading engine as a fallback.
/// It only:
/// 1. Sends `START`, `PAUSE`, `STOP`, `RESET`, and `REFRESH_QUOTES` commands to the
///    single authoritative background engine via `EngineCommandBridge`.
/// 2. Reads committed state snapshots from `PersistenceDatabase` to render the UI.
/// 3. Persists the "Trade alert notifications" ON/OFF toggle in SQLite `engine_kv_state`
///    without ever stopping the bot or hiding the persistent foreground service notification.
class TradingCoordinator extends ChangeNotifier {
  static const MethodChannel _serviceChannel =
      MethodChannel('com.ankit.aitrader/service');
  static const EventChannel _networkEventChannel =
      EventChannel('com.ankit.aitrader/network_events');

  /// Maximum heartbeat age (5 minutes = 300,000 ms) considered alive on reopen.
  static const int maxHeartbeatReconnectAgeMs = 5 * 60 * 1000;

  final CoinDcxMarketService marketService;
  final PaperBroker broker;
  final PersistenceDatabase persistence;
  final EngineCommandBridge commandBridge;
  final Future<bool> Function()? customInternetProbe;
  final int Function()? nowMsProvider;

  bool foregroundServiceActive = false;
  bool internetConnected = true;
  bool tradeAlertsEnabled = true;
  bool notificationPermissionGranted = true;
  MarketDataStatus marketDataStatus = MarketDataStatus.disconnected;
  BotEngineState engineState = BotEngineState.stopped;

  final Map<String, double> latestPrices = {
    'BTCUSDT': 0.0,
    'ETHUSDT': 0.0,
  };
  final Map<String, double> closedCandlePrices = {
    'BTCUSDT': 0.0,
    'ETHUSDT': 0.0,
  };
  final Map<String, double> liveTickerPrices = {
    'BTCUSDT': 0.0,
    'ETHUSDT': 0.0,
  };
  final Map<String, StrategyEvaluationResult> latestEvaluations = {};
  DateTime? lastMarketDataUpdateUtc;
  int? lastHeartbeatMs;
  String statusBannerMessage = 'ENGINE STOPPED — PRESS START TO RUN PAPER BOT';
  int? runningSinceMs;
  int totalActiveMs = 0;
  int lastSessionDurationMs = 0;
  BacktestReport? lastBacktestReport;

  Timer? _uiStateRefreshTimer;
  StreamSubscription<dynamic>? _networkSub;

  TradingCoordinator({
    CoinDcxMarketService? marketService,
    PaperBroker? broker,
    PersistenceDatabase? persistence,
    EngineCommandBridge? commandBridge,
    this.customInternetProbe,
    this.nowMsProvider,
  })  : marketService = marketService ?? CoinDcxMarketService(),
        broker = broker ?? PaperBroker(),
        persistence = persistence ?? PersistenceDatabase(),
        commandBridge = commandBridge ?? MethodChannelEngineBridge();

  int _nowMs() =>
      nowMsProvider != null
          ? nowMsProvider!()
          : DateTime.now().toUtc().millisecondsSinceEpoch;

  ActiveTimerSummary get activeTimerSummary => ActiveTimerSummary(
        runningSinceMs: runningSinceMs,
        totalActiveMs: totalActiveMs,
        lastSessionDurationMs: lastSessionDurationMs,
      );

  /// Formats a UTC epoch millisecond timestamp as `HH:MM:SS`.
  static String formatUtcHhMmSs(int timestampMs) {
    final dt = DateTime.fromMillisecondsSinceEpoch(timestampMs, isUtc: true);
    final h = dt.hour.toString().padLeft(2, '0');
    final m = dt.minute.toString().padLeft(2, '0');
    final s = dt.second.toString().padLeft(2, '0');
    return '$h:$m:$s';
  }

  /// Human-readable heartbeat timestamp and age for the dashboard.
  String formatHeartbeatStatus({int? nowOverrideMs}) {
    final hb = lastHeartbeatMs;
    if (hb == null || hb <= 0) {
      return 'Heartbeat: Never';
    }
    final now = nowOverrideMs ?? _nowMs();
    final ageSec = now >= hb ? ((now - hb) ~/ 1000) : 0;
    final hhMmSs = formatUtcHhMmSs(hb);
    return 'Heartbeat: $hhMmSs UTC (${ageSec}s ago)';
  }

  String whyNoTradeForSymbol(String symbol) {
    final hasPosForSymbol = broker.openPositions.containsKey(symbol);
    final hasOtherPos =
        !hasPosForSymbol && broker.openPositions.isNotEmpty;
    return StrategyEngine.deriveWhyNoTradeReason(
      botState: engineState,
      marketDataStatus: marketDataStatus,
      eval: latestEvaluations[symbol],
      hasOpenPositionForSymbol: hasPosForSymbol,
      hasOtherOpenPosition: hasOtherPos,
      config: broker.strategyConfig,
    );
  }

  Future<void> initialize({bool enablePlatformChannels = true}) async {
    await refreshStateFromDatabase(isInitialLoad: true);

    if (enablePlatformChannels) {
      await _initPlatformChannels();
      _startUiStateRefreshTimer();
    } else if (customInternetProbe != null) {
      internetConnected = await customInternetProbe!();
    }
    notifyListeners();
  }

  /// Passively reads the latest committed snapshot from SQLite.
  ///
  /// Step 1(b) — Reconnect on reopen:
  /// - If the DB says `running` and either the service is alive OR the last heartbeat
  ///   is under 5 minutes old (`maxHeartbeatReconnectAgeMs`), reconnect to the existing
  ///   engine, do NOT rewrite state to paused, and show `"RECONNECTED — heartbeat HH:MM:SS"`.
  /// - Downgrade to `pausedAfterRecoveryManualStartRequired` ONLY if the service is
  ///   confirmed dead AND there is no heartbeat within the last 5 minutes.
  Future<void> refreshStateFromDatabase({bool isInitialLoad = false}) async {
    try {
      final snap = await persistence.restoreFullSnapshot(broker);
      final nowMs = _nowMs();
      tradeAlertsEnabled = snap.tradeAlertsEnabled;
      marketDataStatus = snap.marketDataStatus;
      latestPrices.addAll(snap.latestPrices);
      closedCandlePrices.addAll(snap.closedCandlePrices);
      liveTickerPrices.addAll(snap.liveTickerPrices);
      runningSinceMs = snap.runningSinceMs;
      totalActiveMs = snap.totalActiveMs;
      lastSessionDurationMs = snap.lastSessionDurationMs;
      lastHeartbeatMs = snap.lastHeartbeatMs;
      latestEvaluations
        ..clear()
        ..addAll(snap.latestEvaluations);
      if (snap.lastMarketDataUpdateMs != null) {
        lastMarketDataUpdateUtc = DateTime.fromMillisecondsSinceEpoch(
          snap.lastMarketDataUpdateMs!,
          isUtc: true,
        );
      }

      if (isInitialLoad && snap.botState == BotEngineState.running) {
        final serviceReady = await _checkServiceReadySafe();
        final hbMs = snap.lastHeartbeatMs;
        final hasRecentHeartbeat = hbMs != null &&
            hbMs > 0 &&
            (nowMs - hbMs) >= 0 &&
            (nowMs - hbMs) < maxHeartbeatReconnectAgeMs;

        if (serviceReady || hasRecentHeartbeat) {
          if (!serviceReady && hasRecentHeartbeat) {
            // Re-attach to existing background service without overwriting RUNNING state
            foregroundServiceActive =
                await commandBridge.ensureServiceStartedAndReady();
          } else {
            foregroundServiceActive = true;
          }
          engineState = BotEngineState.running;
          final displayHbMs = hbMs ?? snap.lastMarketDataUpdateMs ?? nowMs;
          statusBannerMessage =
              'RECONNECTED — heartbeat ${formatUtcHhMmSs(displayHbMs)}';
          notifyListeners();
          return;
        } else {
          // Service is confirmed dead AND there is no heartbeat within 5 minutes
          engineState = BotEngineState.pausedAfterRecoveryManualStartRequired;
          statusBannerMessage =
              'STATE RESTORED — MANUAL START REQUIRED TO RESUME BOT';
          await persistence.saveFullState(
            broker: broker,
            botState: engineState,
            latestPrices: latestPrices,
            closedCandlePrices: closedCandlePrices,
            liveTickerPrices: liveTickerPrices,
            marketDataStatus: marketDataStatus,
            statusBannerMessage: statusBannerMessage,
            lastMarketDataUpdateMs: snap.lastMarketDataUpdateMs,
            lastHeartbeatMs: snap.lastHeartbeatMs,
            latestEvaluations: latestEvaluations,
            nowOverrideMs: nowMs,
          );
          notifyListeners();
          return;
        }
      }

      engineState = snap.botState;
      statusBannerMessage = snap.statusBannerMessage;
    } catch (e) {
      // Never silently reset an existing account on DB read error: pause safely
      engineState = BotEngineState.pausedStaleData;
      statusBannerMessage =
          'DATABASE RESTORATION ERROR — ACCOUNT PRESERVED (TRADING PAUSED)';
    }
    notifyListeners();
  }

  /// Updates the "Trade alert notifications" ON/OFF toggle in SQLite (`engine_kv_state`).
  /// Takes effect immediately in the authoritative background engine without restarting
  /// or stopping the bot, and never hides or disables the persistent foreground notification.
  Future<void> setTradeAlertsEnabled(bool enabled) async {
    tradeAlertsEnabled = enabled;
    await persistence.setTradeAlertsEnabled(enabled);
    notifyListeners();
  }

  Future<void> checkNotificationPermissionStatus() async {
    try {
      final granted = await _serviceChannel
              .invokeMethod<bool>('checkNotificationPermission') ??
          true;
      notificationPermissionGranted = granted;
    } catch (_) {
      notificationPermissionGranted = true;
    }
    notifyListeners();
  }

  Future<void> openNotificationSettings() async {
    try {
      await _serviceChannel.invokeMethod('openNotificationSettings');
    } catch (_) {}
  }

  Future<bool> _checkServiceReadySafe() async {
    try {
      final ready = await commandBridge.isServiceAndEngineReady();
      foregroundServiceActive = ready;
      return ready;
    } catch (_) {
      foregroundServiceActive = false;
      return false;
    }
  }

  void _startUiStateRefreshTimer() {
    _uiStateRefreshTimer?.cancel();
    // Passive SQLite reader timer (only reads state; NEVER executes trades)
    _uiStateRefreshTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      unawaited(refreshStateFromDatabase());
      unawaited(checkNotificationPermissionStatus());
    });
  }

  Future<void> _initPlatformChannels() async {
    try {
      final ready = await commandBridge.isServiceAndEngineReady();
      if (ready || engineState != BotEngineState.running) {
        foregroundServiceActive = ready;
      }
      final net =
          await _serviceChannel.invokeMethod<bool>('checkNetworkConnected') ??
              true;
      internetConnected = net;
      final notifPerm = await _serviceChannel
              .invokeMethod<bool>('requestNotificationPermission') ??
          true;
      notificationPermissionGranted = notifPerm;
    } catch (_) {
      if (engineState != BotEngineState.running) {
        foregroundServiceActive = false;
      }
    }

    try {
      _networkSub = _networkEventChannel.receiveBroadcastStream().listen(
        (dynamic event) {
          if (event is bool) {
            unawaited(handleConnectivityTransition(event));
          }
        },
        onError: (_) {},
      );
    } catch (_) {}
  }

  /// Handles connectivity events from Android `EventChannel`.
  /// Note: On reopen, the initial `onListen` callback emits `true` while `wasConnected`
  /// is already `true` — that is NOT a disconnect->reconnect transition and never
  /// rewrites a running engine to paused.
  Future<void> handleConnectivityTransition(bool isConnected) async {
    final wasConnected = internetConnected;
    internetConnected = isConnected;

    if (!isConnected) {
      marketDataStatus = MarketDataStatus.disconnected;
      await commandBridge.notifyNetworkChanged(false);
      await refreshStateFromDatabase();
      if (engineState == BotEngineState.running) {
        engineState = BotEngineState.pausedNetworkLoss;
        statusBannerMessage =
            'INTERNET DISCONNECTED — BOT PAUSED FOR SAFETY';
      }
    } else if (!wasConnected && isConnected) {
      await commandBridge.notifyNetworkChanged(true);
      await refreshStateFromDatabase();
      if (engineState == BotEngineState.pausedNetworkLoss ||
          engineState == BotEngineState.running) {
        engineState = BotEngineState.pausedAfterRecoveryManualStartRequired;
        statusBannerMessage =
            'INTERNET RECONNECTED — BOT PAUSED (MANUAL START REQUIRED)';
      }
    }
    notifyListeners();
  }

  /// Starts the Android Foreground Service and waits up to 15s for both Android service
  /// creation and headless Dart engine initialization acknowledgement before reporting active.
  /// Shows `"starting…"` during initialization or slow cold start instead of raw `SERVICE_INIT_TIMEOUT`.
  Future<bool> startForegroundService() async {
    statusBannerMessage = 'starting…';
    notifyListeners();
    try {
      final startedAndAcked =
          await commandBridge.ensureServiceStartedAndReady();
      foregroundServiceActive = startedAndAcked;
      if (!startedAndAcked) {
        statusBannerMessage =
            'SERVICE START ERROR: BACKGROUND ENGINE DID NOT ACKNOWLEDGE READY';
      }
      notifyListeners();
      return startedAndAcked;
    } on PlatformException catch (e) {
      foregroundServiceActive = false;
      if (e.code == 'SERVICE_INIT_TIMEOUT') {
        statusBannerMessage = 'starting…';
      } else {
        statusBannerMessage = 'SERVICE START ERROR: ${e.message ?? e.code}';
      }
      notifyListeners();
      return false;
    } catch (e) {
      foregroundServiceActive = false;
      statusBannerMessage = 'SERVICE START ERROR: $e';
      notifyListeners();
      return false;
    }
  }

  Future<void> stopForegroundService() async {
    try {
      await _serviceChannel.invokeMethod('stopService');
    } catch (_) {}
    foregroundServiceActive = false;
    notifyListeners();
  }

  Future<void> openBatteryOptimizationSettings() async {
    try {
      await _serviceChannel.invokeMethod('openBatterySettings');
    } catch (_) {}
  }

  /// Sends the `START` command to the single authoritative background engine.
  /// Never runs a fallback local engine if the service or background isolate fails.
  Future<void> manualStartBot() async {
    if (customInternetProbe != null) {
      internetConnected = await customInternetProbe!();
    }
    if (!internetConnected) {
      engineState = BotEngineState.pausedNetworkLoss;
      statusBannerMessage = 'CANNOT START: NO INTERNET CONNECTION';
      notifyListeners();
      return;
    }

    final serviceReady = await startForegroundService();
    if (!serviceReady || !foregroundServiceActive) {
      engineState = BotEngineState.stopped;
      if (!statusBannerMessage.startsWith('SERVICE START ERROR') &&
          statusBannerMessage != 'starting…') {
        statusBannerMessage =
            'CANNOT START: FOREGROUND SERVICE FAILED TO INITIALIZE';
      }
      notifyListeners();
      return;
    }

    statusBannerMessage =
        'DISPATCHING START TO AUTHORITATIVE BACKGROUND ENGINE...';
    notifyListeners();

    try {
      final ok = await commandBridge.dispatchCommand('START');
      await refreshStateFromDatabase();
      if (!ok && engineState == BotEngineState.stopped) {
        statusBannerMessage =
            'AUTHORITATIVE ENGINE REJECTED START OR MARKET DATA INVALID';
      }
    } on PlatformException catch (e) {
      foregroundServiceActive = false;
      engineState = BotEngineState.stopped;
      statusBannerMessage =
          'ENGINE COMMAND ERROR: ${e.message ?? e.code}';
    } catch (e) {
      engineState = BotEngineState.stopped;
      statusBannerMessage = 'ENGINE COMMAND ERROR: $e';
    }
    notifyListeners();
  }

  Future<void> manualPauseBot() async {
    try {
      await commandBridge.dispatchCommand('PAUSE');
    } catch (_) {}
    await refreshStateFromDatabase();
  }

  /// Step 1(f): Explicit STOP must stop the bot and must NOT be auto-restarted.
  Future<void> manualStopBot() async {
    try {
      await commandBridge.dispatchCommand('STOP');
    } catch (_) {}
    await stopForegroundService();
    await refreshStateFromDatabase();
  }

  Future<void> manualResetDrawdownAndAccount() async {
    try {
      final ready = await commandBridge.isServiceAndEngineReady();
      if (ready) {
        await commandBridge.dispatchCommand('RESET');
      } else {
        broker.manualResetPaperAccount();
        await persistence.clearAllTables();
        await persistence.saveFullState(
          broker: broker,
          botState: BotEngineState.stopped,
          latestPrices: const {'BTCUSDT': 0.0, 'ETHUSDT': 0.0},
          marketDataStatus: MarketDataStatus.disconnected,
          statusBannerMessage: 'PAPER ACCOUNT RESET TO \$100.00 USDT',
        );
      }
    } catch (_) {}
    await refreshStateFromDatabase();
  }

  Future<void> requestPassiveQuoteRefresh() async {
    try {
      final ready = await startForegroundService();
      if (ready) {
        await commandBridge.dispatchCommand('REFRESH_QUOTES');
      }
    } catch (_) {}
    await refreshStateFromDatabase();
  }

  Future<BacktestReport?> runLiveHistoricalBacktest(String symbol) async {
    try {
      final pairs = marketService.discoveredPairs.isNotEmpty
          ? marketService.discoveredPairs
          : await marketService.discoverActiveUsdtPairs();
      final meta = pairs[symbol];
      if (meta == null) return null;

      final candles15m = await marketService.fetchClosedCandles(
        symbol: symbol,
        pair: meta.pair,
        interval: '15m',
        limit: 300,
      );
      final candles1h = await marketService.fetchClosedCandles(
        symbol: symbol,
        pair: meta.pair,
        interval: '1h',
        limit: 200,
      );

      final report = PaperBroker.runHistoricalBacktest(
        symbol: symbol,
        candles15m: candles15m,
        candles1h: candles1h,
        strategyConfig: broker.strategyConfig,
        riskConfig: broker.riskConfig,
      );
      lastBacktestReport = report;
      notifyListeners();
      return report;
    } catch (_) {
      return null;
    }
  }

  @override
  void dispose() {
    _uiStateRefreshTimer?.cancel();
    _networkSub?.cancel();
    super.dispose();
  }
}

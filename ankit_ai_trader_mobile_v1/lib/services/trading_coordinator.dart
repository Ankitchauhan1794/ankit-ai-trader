import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import '../models/trading_models.dart';
import 'coindcx_market_service.dart';
import 'paper_broker.dart';
import 'persistence_db.dart';

class TradingCoordinator extends ChangeNotifier {
  static const MethodChannel _serviceChannel =
      MethodChannel('com.ankit.aitrader/service');
  static const EventChannel _networkEventChannel =
      EventChannel('com.ankit.aitrader/network_events');

  final CoinDcxMarketService marketService;
  final PaperBroker broker;
  final PersistenceDatabase persistence;
  final Future<bool> Function()? customInternetProbe;

  bool foregroundServiceActive = false;
  bool internetConnected = true;
  MarketDataStatus marketDataStatus = MarketDataStatus.disconnected;
  BotEngineState engineState = BotEngineState.stopped;

  final Map<String, double> latestPrices = {
    'BTCUSDT': 0.0,
    'ETHUSDT': 0.0,
  };
  final Map<String, StrategyEvaluationResult> latestEvaluations = {};
  DateTime? lastMarketDataUpdateUtc;
  String statusBannerMessage = 'ENGINE STOPPED — PRESS START TO RUN PAPER BOT';
  BacktestReport? lastBacktestReport;

  Timer? _pollingTimer;
  StreamSubscription<dynamic>? _networkSub;
  bool _isPollingCycleActive = false;

  TradingCoordinator({
    CoinDcxMarketService? marketService,
    PaperBroker? broker,
    PersistenceDatabase? persistence,
    this.customInternetProbe,
  })  : marketService = marketService ?? CoinDcxMarketService(),
        broker = broker ?? PaperBroker(),
        persistence = persistence ?? PersistenceDatabase();

  Future<void> initialize({bool enablePlatformChannels = true}) async {
    try {
      final restoredState = await persistence.restoreIntoBroker(broker);
      if (broker.maxDrawdownLocked) {
        engineState = BotEngineState.stoppedMaxDrawdownReached;
        statusBannerMessage = 'MAXIMUM DRAWDOWN REACHED — MANUAL RESET REQUIRED';
      } else if (broker.isDailyLockedAt(
          DateTime.now().toUtc().millisecondsSinceEpoch)) {
        engineState = BotEngineState.lockedDailyLossLimit;
        statusBannerMessage = 'DAILY LOSS LIMIT REACHED';
      } else if (restoredState == BotEngineState.running) {
        // Safety requirement: After process restart or interruption, require manual START
        engineState = BotEngineState.pausedAfterRecoveryManualStartRequired;
        statusBannerMessage =
            'STATE RESTORED — MANUAL START REQUIRED TO RESUME BOT';
      } else {
        engineState = restoredState;
      }
    } catch (_) {}

    if (enablePlatformChannels) {
      await _initPlatformChannels();
    } else if (customInternetProbe != null) {
      internetConnected = await customInternetProbe!();
    }
    notifyListeners();
  }

  Future<void> _initPlatformChannels() async {
    try {
      final running =
          await _serviceChannel.invokeMethod<bool>('isServiceRunning') ?? false;
      foregroundServiceActive = running;
      final net =
          await _serviceChannel.invokeMethod<bool>('checkNetworkConnected') ??
              true;
      internetConnected = net;
    } catch (_) {}

    try {
      _networkSub = _networkEventChannel.receiveBroadcastStream().listen(
        (dynamic event) {
          if (event is bool) {
            handleConnectivityTransition(event);
          }
        },
        onError: (_) {},
      );
    } catch (_) {}
  }

  /// Enforces the mandatory safety rule:
  /// - When internet is lost, the bot pauses immediately.
  /// - When internet automatically reconnects, the app restores connectivity status
  ///   and market data, but NEVER auto-restarts the trading engine.
  /// - A fresh manual START from the user is strictly required.
  void handleConnectivityTransition(bool isConnected) {
    final wasConnected = internetConnected;
    internetConnected = isConnected;

    if (!isConnected) {
      marketDataStatus = MarketDataStatus.disconnected;
      if (engineState == BotEngineState.running) {
        engineState = BotEngineState.pausedNetworkLoss;
        statusBannerMessage =
            'INTERNET DISCONNECTED — BOT PAUSED FOR SAFETY';
        _syncServiceNotification();
        persistence.saveFullState(
          broker: broker,
          botState: engineState,
          latestPrices: latestPrices,
        );
      }
    } else if (!wasConnected && isConnected) {
      if (engineState == BotEngineState.pausedNetworkLoss ||
          engineState == BotEngineState.running) {
        engineState = BotEngineState.pausedAfterRecoveryManualStartRequired;
        statusBannerMessage =
            'INTERNET RECONNECTED — BOT PAUSED (MANUAL START REQUIRED)';
      }
      // Refresh market quotes passively without running the bot
      unawaited(pollMarketDataAndEvaluate(allowTradingExecution: false));
      _syncServiceNotification();
      persistence.saveFullState(
        broker: broker,
        botState: engineState,
        latestPrices: latestPrices,
      );
    }
    notifyListeners();
  }

  Future<void> startForegroundService() async {
    try {
      await _serviceChannel.invokeMethod('startService', {
        'title': 'Ankit AI Trader (Paper Mode)',
        'text': _notificationSummaryText(),
      });
      foregroundServiceActive = true;
    } catch (_) {
      foregroundServiceActive = true;
    }
    notifyListeners();
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

  /// Manual START button handler.
  /// The Bot RUNNING state only becomes active once valid market data is confirmed.
  Future<void> manualStartBot() async {
    if (broker.maxDrawdownLocked ||
        broker.riskManager
            .isMaxDrawdownReached(broker.accountEquity(latestPrices))) {
      engineState = BotEngineState.stoppedMaxDrawdownReached;
      statusBannerMessage = 'MAXIMUM DRAWDOWN REACHED — MANUAL RESET REQUIRED';
      notifyListeners();
      return;
    }

    final nowMs = DateTime.now().toUtc().millisecondsSinceEpoch;
    if (broker.isDailyLockedAt(nowMs)) {
      engineState = BotEngineState.lockedDailyLossLimit;
      statusBannerMessage = 'DAILY LOSS LIMIT REACHED';
      notifyListeners();
      return;
    }

    if (!internetConnected) {
      engineState = BotEngineState.pausedNetworkLoss;
      statusBannerMessage = 'CANNOT START: NO INTERNET CONNECTION';
      notifyListeners();
      return;
    }

    await startForegroundService();
    statusBannerMessage = 'VALIDATING LIVE COINDCX MARKET DATA...';
    notifyListeners();

    final ok = await pollMarketDataAndEvaluate(
      allowTradingExecution: true,
      transitionToRunningOnSuccess: true,
    );

    if (ok &&
        engineState != BotEngineState.lockedDailyLossLimit &&
        engineState != BotEngineState.stoppedMaxDrawdownReached) {
      _startPollingTimer();
    }
  }

  Future<void> manualPauseBot() async {
    _pollingTimer?.cancel();
    _pollingTimer = null;
    engineState = BotEngineState.pausedAfterRecoveryManualStartRequired;
    statusBannerMessage = 'BOT PAUSED MANUALLY — PRESS START TO RESUME';
    await persistence.saveFullState(
      broker: broker,
      botState: engineState,
      latestPrices: latestPrices,
    );
    _syncServiceNotification();
    notifyListeners();
  }

  Future<void> manualStopBot() async {
    _pollingTimer?.cancel();
    _pollingTimer = null;
    engineState = BotEngineState.stopped;
    statusBannerMessage = 'ENGINE STOPPED BY USER';
    await persistence.saveFullState(
      broker: broker,
      botState: engineState,
      latestPrices: latestPrices,
    );
    _syncServiceNotification();
    notifyListeners();
  }

  Future<void> manualResetDrawdownAndAccount() async {
    _pollingTimer?.cancel();
    _pollingTimer = null;
    broker.manualResetPaperAccount();
    await persistence.clearAllTables();
    engineState = BotEngineState.stopped;
    statusBannerMessage = 'PAPER ACCOUNT RESET TO \$100.00 USDT';
    await persistence.saveFullState(
      broker: broker,
      botState: engineState,
      latestPrices: latestPrices,
    );
    _syncServiceNotification();
    notifyListeners();
  }

  void _startPollingTimer() {
    _pollingTimer?.cancel();
    _pollingTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (engineState == BotEngineState.running && internetConnected) {
        unawaited(pollMarketDataAndEvaluate(allowTradingExecution: true));
      }
    });
  }

  /// Fetches live CoinDCX market details & closed 15m/1h candles for BTC/USDT and ETH/USDT,
  /// validates freshness, and runs the paper trading engine only when authorized.
  Future<bool> pollMarketDataAndEvaluate({
    required bool allowTradingExecution,
    bool transitionToRunningOnSuccess = false,
  }) async {
    if (_isPollingCycleActive) return false;
    _isPollingCycleActive = true;

    try {
      if (customInternetProbe != null) {
        final online = await customInternetProbe!();
        if (!online) {
          handleConnectivityTransition(false);
          return false;
        }
      }

      if (!internetConnected) {
        marketDataStatus = MarketDataStatus.disconnected;
        notifyListeners();
        return false;
      }

      marketDataStatus = MarketDataStatus.connecting;
      notifyListeners();

      final pairs = marketService.discoveredPairs.isNotEmpty
          ? marketService.discoveredPairs
          : await marketService.discoverActiveUsdtPairs();

      final nowMs = DateTime.now().toUtc().millisecondsSinceEpoch;

      for (final symbol in ['BTCUSDT', 'ETHUSDT']) {
        final meta = pairs[symbol];
        if (meta == null) continue;

        final closed15m = await marketService.fetchClosedCandles(
          symbol: symbol,
          pair: meta.pair,
          interval: '15m',
          limit: 120,
          nowEpochMs: nowMs,
        );
        final closed1h = await marketService.fetchClosedCandles(
          symbol: symbol,
          pair: meta.pair,
          interval: '1h',
          limit: 120,
          nowEpochMs: nowMs,
        );

        if (closed15m.isEmpty || closed1h.isEmpty) {
          marketDataStatus = MarketDataStatus.error;
          if (engineState == BotEngineState.running ||
              transitionToRunningOnSuccess) {
            engineState = BotEngineState.pausedStaleData;
            statusBannerMessage = 'PAUSED: EMPTY COINDCX CANDLE RESPONSE';
          }
          notifyListeners();
          return false;
        }

        if (CoinDcxMarketService.isDataStale(
              closedCandles: closed15m,
              interval: '15m',
              nowMs: nowMs,
            ) ||
            CoinDcxMarketService.hasRecentMissingCandleGap(
              closedCandles: closed15m,
              interval: '15m',
            )) {
          marketDataStatus = MarketDataStatus.stale;
          if (engineState == BotEngineState.running ||
              transitionToRunningOnSuccess) {
            engineState = BotEngineState.pausedStaleData;
            statusBannerMessage =
                'PAUSED: STALE OR MISSING 15M MARKET DATA DETECTED';
          }
          notifyListeners();
          return false;
        }

        latestPrices[symbol] = closed15m.last.close;

        if (allowTradingExecution &&
            (engineState == BotEngineState.running ||
                transitionToRunningOnSuccess)) {
          final eval = broker.processClosedCandleStep(
            symbol: symbol,
            closed15m: closed15m,
            closed1h: closed1h,
            latestPrices: latestPrices,
            minNotionalUsdt: meta.minNotional,
            minQuantity: meta.minQuantity,
          );
          latestEvaluations[symbol] = eval;
        } else {
          final passiveEval = broker.strategyEngine.evaluateClosedCandles(
            closed15m: closed15m,
            closed1h: closed1h,
            hasOpenPosition: broker.openPositions.containsKey(symbol),
          );
          latestEvaluations[symbol] = passiveEval;
        }
      }

      marketDataStatus = MarketDataStatus.connected;
      lastMarketDataUpdateUtc = DateTime.now().toUtc();

      if (broker.maxDrawdownLocked) {
        engineState = BotEngineState.stoppedMaxDrawdownReached;
        statusBannerMessage =
            'MAXIMUM DRAWDOWN REACHED — MANUAL RESET REQUIRED';
      } else if (broker.isDailyLockedAt(nowMs)) {
        engineState = BotEngineState.lockedDailyLossLimit;
        statusBannerMessage = 'DAILY LOSS LIMIT REACHED';
      } else if (transitionToRunningOnSuccess) {
        engineState = BotEngineState.running;
        statusBannerMessage =
            'BOT RUNNING — PROCESSING CLOSED 15M/1H COINDCX CANDLES';
      }

      await persistence.saveFullState(
        broker: broker,
        botState: engineState,
        latestPrices: latestPrices,
      );
      _syncServiceNotification();
      notifyListeners();
      return true;
    } catch (e) {
      marketDataStatus = MarketDataStatus.error;
      if (engineState == BotEngineState.running ||
          transitionToRunningOnSuccess) {
        engineState = BotEngineState.pausedStaleData;
        statusBannerMessage = 'MARKET DATA ERROR — BOT PAUSED';
      }
      notifyListeners();
      return false;
    } finally {
      _isPollingCycleActive = false;
    }
  }

  /// Runs a historical backtest using the currently fetched or deterministic historical candles.
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

  String _notificationSummaryText() {
    final eq = broker.accountEquity(latestPrices).toStringAsFixed(2);
    final btc = latestPrices['BTCUSDT']?.toStringAsFixed(2) ?? '--';
    return 'State: ${engineState.name.toUpperCase()} | Eq: \$$eq | BTC: \$$btc';
  }

  void _syncServiceNotification() {
    if (!foregroundServiceActive) return;
    try {
      _serviceChannel.invokeMethod('updateNotification', {
        'title': 'Ankit AI Trader — Paper Mode',
        'text': _notificationSummaryText(),
      });
    } catch (_) {}
  }

  @override
  void dispose() {
    _pollingTimer?.cancel();
    _networkSub?.cancel();
    super.dispose();
  }
}
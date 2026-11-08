import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'models/trading_models.dart';
import 'screens/dashboard_screen.dart';
import 'services/authoritative_engine.dart';
import 'services/coindcx_market_service.dart';
import 'services/persistence_db.dart';
import 'services/trading_coordinator.dart';

@pragma('vm:entry-point')
Future<void> backgroundServiceMain() async {
  WidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.ankit.aitrader/background_worker');
  final marketService = CoinDcxMarketService();
  final persistence = PersistenceDatabase();

  late final AuthoritativeTradingEngine engine;
  engine = AuthoritativeTradingEngine(
    marketService: marketService,
    persistence: persistence,
    onNotificationUpdate: (title, text) async {
      try {
        await channel.invokeMethod('updateServiceNotification', {
          'title': title,
          'text': text,
        });
      } catch (_) {}
    },
    onTradeAlert: (alert) async {
      try {
        final posted = await channel.invokeMethod<bool>(
          'postTradeAlertNotification',
          {
            'alertId': alert.alertId,
            'title': alert.title,
            'body': alert.body,
          },
        );
        return posted ?? false;
      } catch (_) {
        return false;
      }
    },
    onSyncUserIntention: (intention) async {
      try {
        await channel.invokeMethod('syncUserIntention', {
          'intention': intention.name.toUpperCase(),
        });
      } catch (_) {}
    },
  );

  channel.setMethodCallHandler((call) async {
    switch (call.method) {
      case 'onCommand':
        final cmd = (call.arguments as Map?)?['command']?.toString() ?? '';
        return await engine.handleCommand(cmd);
      case 'onBackgroundTick':
        return await engine.executeAuthoritativeCycle(
          allowTradingExecution: true,
        );
      case 'onNetworkChanged':
        final connected =
            (call.arguments as Map?)?['connected'] as bool? ?? false;
        await engine.handleNetworkTransition(connected);
        return true;
      default:
        return false;
    }
  });

  try {
    await persistence.database;
    await channel.invokeMethod('acknowledgeEngineInitialized');
    await engine.restoreSessionIfRunningIntended();
  } catch (e) {
    try {
      await channel.invokeMethod('reportEngineFatalError', {
        'error': e.toString(),
      });
    } catch (_) {}
  }
}

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const AnkitTraderApp());
}

class AnkitTraderApp extends StatelessWidget {
  final TradingCoordinator? coordinator;

  const AnkitTraderApp({super.key, this.coordinator});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Ankit AI Trader',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(useMaterial3: true).copyWith(
        scaffoldBackgroundColor: const Color(0xFF090D16),
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF00E676),
          brightness: Brightness.dark,
        ),
        cardTheme: const CardTheme(
          color: Color(0xFF121826),
          elevation: 0,
          margin: EdgeInsets.zero,
        ),
      ),
      home: DashboardPage(coordinator: coordinator),
    );
  }
}

class DashboardPage extends StatefulWidget {
  final TradingCoordinator? coordinator;

  const DashboardPage({super.key, this.coordinator});

  @override
  State<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends State<DashboardPage>
    with WidgetsBindingObserver {
  static const Color _greenProfit = Color(0xFF00E676);
  static const Color _redLoss = Color(0xFFFF5252);
  static const Color _orangeWarn = Color(0xFFFF9100);

  late final TradingCoordinator _coordinator;
  late final bool _ownsCoordinator;
  int _selectedTabIndex = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _ownsCoordinator = widget.coordinator == null;
    _coordinator = widget.coordinator ?? TradingCoordinator();
    _coordinator.addListener(_onCoordinatorChanged);
    _coordinator.initialize(enablePlatformChannels: _ownsCoordinator);
  }

  void _onCoordinatorChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _coordinator.refreshStateFromDatabase(isInitialLoad: false);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _coordinator.removeListener(_onCoordinatorChanged);
    if (_ownsCoordinator) {
      _coordinator.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final pages = <Widget>[
      _buildHomeTab(),
      _buildMarketsTab(),
      _buildTradesTab(),
      _buildAiLabTab(),
      _buildReportsTab(),
      _buildSettingsTab(),
    ];

    return Scaffold(
      appBar: AppBar(
        backgroundColor: const Color(0xFF0D1320),
        title: const Text(
          'Ankit AI Trader',
          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 17),
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: Center(
              child: _statusChip(_coordinator.engineState),
            ),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () =>
            _coordinator.refreshStateFromDatabase(isInitialLoad: false),
        child: pages[_selectedTabIndex],
      ),
      bottomNavigationBar: NavigationBar(
        backgroundColor: const Color(0xFF0D1320),
        selectedIndex: _selectedTabIndex,
        onDestinationSelected: (idx) => setState(() => _selectedTabIndex = idx),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.dashboard_outlined),
            selectedIcon: Icon(Icons.dashboard),
            label: 'Home',
          ),
          NavigationDestination(
            icon: Icon(Icons.candlestick_chart_outlined),
            selectedIcon: Icon(Icons.candlestick_chart),
            label: 'Markets',
          ),
          NavigationDestination(
            icon: Icon(Icons.swap_horiz_outlined),
            selectedIcon: Icon(Icons.swap_horiz),
            label: 'Trades',
          ),
          NavigationDestination(
            icon: Icon(Icons.psychology_outlined),
            selectedIcon: Icon(Icons.psychology),
            label: 'AI Lab',
          ),
          NavigationDestination(
            icon: Icon(Icons.analytics_outlined),
            selectedIcon: Icon(Icons.analytics),
            label: 'Reports',
          ),
          NavigationDestination(
            icon: Icon(Icons.settings_outlined),
            selectedIcon: Icon(Icons.settings),
            label: 'Settings',
          ),
        ],
      ),
    );
  }

  /// STAGE 22 — HOME TAB:
  /// Bot status, equity, available balance, daily/overall P&L, drawdown,
  /// equity curve, open positions, system health, Pause/Stop. No technical logs on Home.
  Widget _buildHomeTab() {
    final dailyPnl = _coordinator.dailyPnlUsdt;
    final overallPnl = _coordinator.overallPnlUsdt;
    final dd = _coordinator.currentDrawdownUsdt;

    return ListView(
      padding: const EdgeInsets.all(14),
      children: [
        _buildBannerCard(),
        const SizedBox(height: 12),
        _buildControlButtons(),
        const SizedBox(height: 14),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'PORTFOLIO OVERVIEW',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    color: Colors.white54,
                  ),
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: _metricTile(
                        'Equity',
                        '\$${_coordinator.accountEquityUsdt.toStringAsFixed(2)}',
                        valueColor: Colors.white,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _metricTile(
                        'Available',
                        '\$${_coordinator.availableCashUsdt.toStringAsFixed(2)}',
                        valueColor: Colors.white70,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: _metricTile(
                        'Daily P&L',
                        '${dailyPnl >= 0 ? "+" : ""}\$${dailyPnl.toStringAsFixed(2)}',
                        valueColor: dailyPnl >= 0 ? _greenProfit : _redLoss,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _metricTile(
                        'Overall P&L',
                        '${overallPnl >= 0 ? "+" : ""}\$${overallPnl.toStringAsFixed(2)}',
                        valueColor: overallPnl >= 0 ? _greenProfit : _redLoss,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _metricTile(
                        'Drawdown (Max \$10)',
                        '\$${dd.toStringAsFixed(2)}',
                        valueColor: dd >= 5.0
                            ? _redLoss
                            : (dd > 0 ? _orangeWarn : _greenProfit),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 14),
        _buildEquityCurveCard(),
        const SizedBox(height: 14),
        _buildOpenPositionsCard(),
        const SizedBox(height: 14),
        _buildSystemHealthSummaryCard(),
        const SizedBox(height: 20),
      ],
    );
  }

  /// STAGE 22 — MARKETS TAB (Stages 12, 13, 14):
  Widget _buildMarketsTab() {
    return ListView(
      padding: const EdgeInsets.all(14),
      children: [
        _buildLiveMarketCard(),
      ],
    );
  }

  /// STAGE 22 — TRADES TAB:
  Widget _buildTradesTab() {
    return ListView(
      padding: const EdgeInsets.all(14),
      children: [
        _buildOpenPositionsCard(),
        const SizedBox(height: 14),
        _buildRecentTradesCard(),
      ],
    );
  }

  /// STAGE 22 — AI LAB TAB:
  Widget _buildAiLabTab() {
    return ListView(
      padding: const EdgeInsets.all(14),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: const [
                Text(
                  'MULTI-TIMEFRAME STRATEGY RULES',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                ),
                SizedBox(height: 8),
                Text(
                  '• Trend Filter: 1h EMA 20 > 1h EMA 50 (Strict Closed Candles)\n'
                  '• Entry Trigger: 15m EMA 20 crosses above 15m EMA 50 with RSI(14) in 50–65\n'
                  '• Risk / Exit: SL = 1.5 × ATR(14), TP = 3.0 × ATR(14), 1% (\$1) Risk/Trade, 30m Cooldown',
                  style: TextStyle(fontSize: 12, color: Colors.white70, height: 1.4),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 14),
        _buildBacktestCard(),
      ],
    );
  }

  /// STAGE 22 — REPORTS TAB (Stage 5 Diagnostics + Event Journal):
  Widget _buildReportsTab() {
    final hbLevel = _coordinator.heartbeatHealthLevel;
    final hbColor = hbLevel == 'OK'
        ? _greenProfit
        : (hbLevel == 'DELAYED' ? _orangeWarn : _redLoss);
    final events = _coordinator.recentEvents;

    return ListView(
      padding: const EdgeInsets.all(14),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'STAGE 5 — ENGINE & SERVICE DIAGNOSTICS',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                ),
                const SizedBox(height: 10),
                _diagRow(
                  'Native Service Alive',
                  _coordinator.serviceRunning ? 'YES' : 'NO',
                  _coordinator.serviceRunning ? _greenProfit : _redLoss,
                ),
                _diagRow(
                  'Dart Heartbeat',
                  _coordinator.formatHeartbeatStatus(),
                  hbColor,
                ),
                _diagRow(
                  'Last Ticker Update',
                  _coordinator.lastMarketDataUpdateMs != null
                      ? TradingCoordinator.formatUtcHhMmSs(
                          _coordinator.lastMarketDataUpdateMs!)
                      : 'Never',
                  Colors.white70,
                ),
                _diagRow(
                  'Last Candle Update',
                  _coordinator.lastCandleUpdateMs != null
                      ? TradingCoordinator.formatUtcHhMmSs(
                          _coordinator.lastCandleUpdateMs!)
                      : 'Never',
                  Colors.white70,
                ),
                _diagRow(
                  'Session Intention',
                  _coordinator.userIntention.name.toUpperCase(),
                  _coordinator.userIntention == UserSessionIntention.running
                      ? _greenProfit
                      : Colors.white70,
                ),
                _diagRow(
                  'Runtime State',
                  _coordinator.engineState.name,
                  _coordinator.engineState == BotEngineState.running
                      ? _greenProfit
                      : _orangeWarn,
                ),
                _diagRow(
                  'Service Restart Count',
                  '${_coordinator.serviceRestartCount}',
                  Colors.white70,
                ),
                _diagRow(
                  'Last Error',
                  _coordinator.lastError ?? 'None',
                  _coordinator.lastError == null ? _greenProfit : _orangeWarn,
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 14),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'DIAGNOSTIC EVENT JOURNAL (LAST ${events.length}/50 • PRUNED TO 500)',
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 13,
                  ),
                ),
                const SizedBox(height: 8),
                if (events.isEmpty)
                  const Text(
                    'No diagnostic events recorded yet.',
                    style: TextStyle(fontSize: 12, color: Colors.white60),
                  )
                else
                  ...events.take(50).map(
                        (e) => Padding(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          child: Text(
                            '[${TradingCoordinator.formatUtcHhMmSs(e.timestampMs)}] ${e.eventType}: ${e.reason}',
                            style: const TextStyle(
                              fontSize: 11,
                              color: Colors.white70,
                            ),
                          ),
                        ),
                      ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  /// STAGE 22 — SETTINGS TAB (Stage 9 Auto-Resume, Stage 10 OnePlus Battery, Account Reset):
  Widget _buildSettingsTab() {
    return ListView(
      padding: const EdgeInsets.all(14),
      children: [
        OnePlusBatteryOptimizationCard(
          ignoringBatteryOptimizations:
              _coordinator.ignoringBatteryOptimizations,
          notificationPermissionGranted:
              _coordinator.notificationPermissionGranted,
          onOpenSettings: _coordinator.openBatteryOptimizationSettings,
          onOpenNotifications: _coordinator.openNotificationSettings,
        ),
        const SizedBox(height: 12),
        Card(
          child: SwitchListTile(
            title: const Text(
              'Auto-Resume After Network Recovery',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
            ),
            subtitle: const Text(
              'Default OFF. When ON, resumes automatically after fresh validated data from network/stale-data pauses only.',
              style: TextStyle(fontSize: 11),
            ),
            value: _coordinator.autoResumeEnabled,
            onChanged: (val) => _coordinator.setAutoResumeEnabled(val),
          ),
        ),
        const SizedBox(height: 12),
        _buildTradeAlertsToggleCard(),
        const SizedBox(height: 12),
        Card(
          child: ListTile(
            title: const Text(
              'Reset Paper Account (\$100.00 USDT)',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
            ),
            subtitle: const Text(
              'Clears open positions, trade history, and drawdown locks while preserving alert deduplication.',
              style: TextStyle(fontSize: 11),
            ),
            trailing: OutlinedButton(
              onPressed: _coordinator.manualResetDrawdownAndAccount,
              child: const Text('RESET \$100'),
            ),
          ),
        ),
      ],
    );
  }

  Widget _diagRow(String label, String value, Color valueColor) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: const TextStyle(fontSize: 12, color: Colors.white60),
          ),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              value,
              textAlign: TextAlign.right,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.bold,
                color: valueColor,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEquityCurveCard() {
    final points = _coordinator.equityCurve;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'EQUITY CURVE',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.bold,
                color: Colors.white54,
              ),
            ),
            const SizedBox(height: 10),
            SizedBox(
              height: 90,
              width: double.infinity,
              child: CustomPaint(
                painter: _EquityCurvePainter(
                  points: points.isEmpty
                      ? [
                          EquityPoint(
                            timestampMs: 0,
                            equityUsdt: _coordinator.accountEquityUsdt,
                          )
                        ]
                      : points,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSystemHealthSummaryCard() {
    final hbLevel = _coordinator.heartbeatHealthLevel;
    final hbColor = hbLevel == 'OK'
        ? _greenProfit
        : (hbLevel == 'DELAYED' ? _orangeWarn : _redLoss);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'SYSTEM HEALTH',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    color: Colors.white54,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  _coordinator.formatHeartbeatStatus(),
                  key: const ValueKey('heartbeat_status_text'),
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: hbColor,
                  ),
                ),
              ],
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: _coordinator.internetConnected
                    ? _greenProfit.withOpacity(0.18)
                    : _redLoss.withOpacity(0.18),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                _coordinator.internetConnected ? 'NET ONLINE' : 'NET OFFLINE',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                  color:
                      _coordinator.internetConnected ? _greenProfit : _redLoss,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _statusChip(BotEngineState state) {
    Color bg;
    String label;
    switch (state) {
      case BotEngineState.running:
        bg = _greenProfit.withOpacity(0.2);
        label = 'RUNNING';
        break;
      case BotEngineState.pausedNetworkLoss:
      case BotEngineState.pausedStaleData:
        bg = _orangeWarn.withOpacity(0.2);
        label = 'RECOVERING';
        break;
      case BotEngineState.pausedAfterRecoveryManualStartRequired:
        bg = _orangeWarn.withOpacity(0.2);
        label = 'PAUSED';
        break;
      case BotEngineState.lockedDailyLossLimit:
      case BotEngineState.stoppedMaxDrawdownReached:
        bg = _redLoss.withOpacity(0.25);
        label = 'SAFETY LOCK';
        break;
      case BotEngineState.stopped:
        bg = Colors.blueGrey.withOpacity(0.3);
        label = 'STOPPED';
        break;
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        label,
        style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold),
      ),
    );
  }

  Widget _buildBannerCard() {
    return Card(
      color: const Color(0xFF151E30),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Expanded(
              child: Text(
                _coordinator.statusBannerMessage,
                style: const TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 12,
                  color: Colors.white,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Text(
              _coordinator.userIntention.name.toUpperCase(),
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.bold,
                color: _coordinator.userIntention == UserSessionIntention.running
                    ? _greenProfit
                    : Colors.white54,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Stage 4 Control Buttons:
  /// - RUNNING + service alive -> show PAUSE and STOP (no START button)
  /// - RUNNING + restore failed -> show RESTART and STOP
  /// - PAUSED -> show RESUME and STOP
  /// - STOPPED -> show START PAPER BOT
  Widget _buildControlButtons() {
    final intention = _coordinator.userIntention;

    if (intention == UserSessionIntention.running &&
        _coordinator.restoreFailedRequiresRestart) {
      return Row(
        children: [
          Expanded(
            child: ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: _orangeWarn,
                foregroundColor: Colors.black,
                padding: const EdgeInsets.symmetric(vertical: 14),
              ),
              onPressed: _coordinator.startBot,
              icon: const Icon(Icons.refresh),
              label: const Text(
                'RESTART',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: _redLoss,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 14),
              ),
              onPressed: _coordinator.stopBot,
              icon: const Icon(Icons.stop),
              label: const Text(
                'STOP',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
          ),
        ],
      );
    }

    if (intention == UserSessionIntention.paused) {
      return Row(
        children: [
          Expanded(
            child: ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: _greenProfit,
                foregroundColor: Colors.black,
                padding: const EdgeInsets.symmetric(vertical: 14),
              ),
              onPressed: _coordinator.startBot,
              icon: const Icon(Icons.play_arrow),
              label: const Text(
                'RESUME',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: _redLoss,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 14),
              ),
              onPressed: _coordinator.stopBot,
              icon: const Icon(Icons.stop),
              label: const Text(
                'STOP',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
          ),
        ],
      );
    }

    if (intention == UserSessionIntention.running ||
        _coordinator.engineState == BotEngineState.running) {
      return Row(
        children: [
          Expanded(
            child: ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: _orangeWarn,
                foregroundColor: Colors.black,
                padding: const EdgeInsets.symmetric(vertical: 14),
              ),
              onPressed: _coordinator.pauseBot,
              icon: const Icon(Icons.pause),
              label: const Text(
                'PAUSE',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: _redLoss,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 14),
              ),
              onPressed: _coordinator.stopBot,
              icon: const Icon(Icons.stop),
              label: const Text(
                'STOP',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
          ),
        ],
      );
    }

    return Row(
      children: [
        Expanded(
          child: ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
              backgroundColor: _greenProfit,
              foregroundColor: Colors.black,
              padding: const EdgeInsets.symmetric(vertical: 14),
            ),
            onPressed: _coordinator.startBot,
            icon: const Icon(Icons.play_arrow),
            label: const Text(
              'START PAPER BOT',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildLiveMarketCard() {
    final feedHealthy =
        _coordinator.marketDataStatus == MarketDataStatus.healthy;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  'COINDCX SPOT MARKETS (4s POLL)',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                ),
                Text(
                  feedHealthy ? 'FEED: FRESH' : 'FEED: STALE',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    color: feedHealthy ? _greenProfit : _orangeWarn,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            _pairRow('B-BTC_USDT', 'BTC / USDT'),
            const Divider(height: 22),
            _pairRow('B-ETH_USDT', 'ETH / USDT'),
          ],
        ),
      ),
    );
  }

  Widget _pairRow(String symbol, String display) {
    final ticker = _coordinator.liveTickers[symbol];
    final price = ticker?.lastPrice ?? _coordinator.liveTickerPrices[symbol];
    final closed15m = _coordinator.closedCandlePrices[symbol];
    final whyNoTrade =
        _coordinator.whyNoTradeForSymbol[symbol] ?? 'Ready for next 15m close';
    final change = ticker?.change24hPct ?? 0.0;
    final changeColor = change >= 0 ? _greenProfit : _redLoss;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              display,
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
            ),
            Text(
              price != null
                  ? '\$${price.toStringAsFixed(2)} (${change >= 0 ? "+" : ""}${change.toStringAsFixed(2)}%)'
                  : 'Loading...',
              style: TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 15,
                color: changeColor,
              ),
            ),
          ],
        ),
        if (ticker != null) ...[
          const SizedBox(height: 4),
          Text(
            'Bid: \$${ticker.bid.toStringAsFixed(2)} | Ask: \$${ticker.ask.toStringAsFixed(2)} | 24h H/L: \$${ticker.high24h.toStringAsFixed(1)} / \$${ticker.low24h.toStringAsFixed(1)} | Vol: ${ticker.volume24h.toStringAsFixed(1)}',
            style: const TextStyle(fontSize: 11, color: Colors.white70),
          ),
          const SizedBox(height: 2),
          Text(
            'Ticker Time: ${TradingCoordinator.formatUtcHhMmSs(ticker.timestampMs)} | Candle Time: ${_coordinator.lastCandleUpdateMs != null ? TradingCoordinator.formatUtcHhMmSs(_coordinator.lastCandleUpdateMs!) : "--"}',
            style: const TextStyle(fontSize: 10, color: Colors.white54),
          ),
        ],
        const SizedBox(height: 4),
        Text(
          'Closed 15m: ${closed15m != null ? "\$${closed15m.toStringAsFixed(2)}" : "--"} | $whyNoTrade',
          style: const TextStyle(fontSize: 11, color: Colors.white60),
        ),
      ],
    );
  }

  Widget _buildOpenPositionsCard() {
    final positions = _coordinator.openPositions;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'OPEN POSITIONS (${positions.length}/1)',
              style: const TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 11,
                color: Colors.white54,
              ),
            ),
            const SizedBox(height: 8),
            if (positions.isEmpty)
              const Text(
                'No open paper position.',
                style: TextStyle(fontSize: 12, color: Colors.white60),
              )
            else
              ...positions.map((pos) {
                final mark =
                    _coordinator.liveTickerPrices[pos.symbol] ?? pos.entryPrice;
                final upnl = pos.unrealizedPnlUsdt(mark);
                return ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(
                    '${pos.symbol} • Qty ${pos.quantity.toStringAsFixed(5)} @ \$${pos.entryPrice.toStringAsFixed(2)}',
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 13,
                    ),
                  ),
                  subtitle: Text(
                    'SL: \$${pos.stopLoss.toStringAsFixed(2)} | TP: \$${pos.takeProfit.toStringAsFixed(2)} | Live: \$${mark.toStringAsFixed(2)}',
                    style: const TextStyle(fontSize: 11),
                  ),
                  trailing: Text(
                    '${upnl >= 0 ? "+" : ""}\$${upnl.toStringAsFixed(2)}',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      color: upnl >= 0 ? _greenProfit : _redLoss,
                    ),
                  ),
                );
              }),
          ],
        ),
      ),
    );
  }

  Widget _buildRecentTradesCard() {
    final trades = _coordinator.closedTrades;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'CLOSED TRADES (${trades.length})',
              style: const TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 11,
                color: Colors.white54,
              ),
            ),
            const SizedBox(height: 8),
            if (trades.isEmpty)
              const Text(
                'No closed paper trades yet.',
                style: TextStyle(fontSize: 12, color: Colors.white60),
              )
            else
              ...trades.take(20).map((t) {
                final win = t.realizedPnlUsdt >= 0;
                return ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(
                    '${t.symbol} (${t.exitReason})',
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 12,
                    ),
                  ),
                  subtitle: Text(
                    'Entry \$${t.entryPrice.toStringAsFixed(2)} → Exit \$${t.exitPrice.toStringAsFixed(2)} (Fees \$${t.totalFeesUsdt.toStringAsFixed(3)})',
                    style: const TextStyle(fontSize: 11),
                  ),
                  trailing: Text(
                    '${win ? "+" : ""}\$${t.realizedPnlUsdt.toStringAsFixed(2)}',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      color: win ? _greenProfit : _redLoss,
                    ),
                  ),
                );
              }),
          ],
        ),
      ),
    );
  }

  Widget _buildTradeAlertsToggleCard() {
    return Card(
      child: SwitchListTile(
        title: const Text(
          'Trade Alert Notifications',
          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
        ),
        subtitle: Text(
          _coordinator.notificationPermissionGranted
              ? 'High-priority notifications for simulated entries, exits & safety locks.'
              : 'Notification permission is blocked on Android 13+. Trade alerts cannot be shown until enabled in settings.',
          style: const TextStyle(fontSize: 11),
        ),
        value: _coordinator.tradeAlertsEnabled,
        onChanged: (val) => _coordinator.setTradeAlertsEnabled(val),
      ),
    );
  }

  Widget _buildBacktestCard() {
    final report = _coordinator.latestBacktestReport;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'HISTORICAL BACKTEST ENGINE (BTC/USDT)',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
            ),
            const SizedBox(height: 4),
            const Text(
              'Run backtest on historical candles using identical strategy, fees, slippage & risk rules.',
              style: TextStyle(fontSize: 11, color: Colors.white60),
            ),
            const SizedBox(height: 10),
            ElevatedButton(
              onPressed: _coordinator.isRunningBacktest
                  ? null
                  : () => _coordinator.runLiveHistoricalBacktest(),
              child: Text(
                _coordinator.isRunningBacktest
                    ? 'RUNNING BACKTEST...'
                    : 'RUN BACKTEST',
              ),
            ),
            if (report != null) ...[
              const SizedBox(height: 10),
              Text(
                'Trades: ${report.totalTrades} | Win Rate: ${report.winRatePct.toStringAsFixed(1)}% | Net PnL: \$${report.netPnlUsdt.toStringAsFixed(2)} | Max DD: \$${report.maxDrawdownUsdt.toStringAsFixed(2)}',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  color: report.netPnlUsdt >= 0 ? _greenProfit : _redLoss,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _metricTile(
    String label,
    String value, {
    Color valueColor = Colors.white,
  }) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: const Color(0xFF182032),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: const TextStyle(fontSize: 11, color: Colors.white54),
          ),
          const SizedBox(height: 4),
          Text(
            value,
            style: TextStyle(
              fontWeight: FontWeight.bold,
              fontSize: 14,
              color: valueColor,
            ),
          ),
        ],
      ),
    );
  }
}

class _EquityCurvePainter extends CustomPainter {
  final List<EquityPoint> points;

  const _EquityCurvePainter({required this.points});

  @override
  void paint(Canvas canvas, Size size) {
    if (points.isEmpty) return;
    final values = points.map((p) => p.equityUsdt).toList();
    final minVal = values.reduce(math.min);
    final maxVal = values.reduce(math.max);
    final range = (maxVal - minVal).abs() < 0.01 ? 1.0 : (maxVal - minVal);

    final isProfit = values.last >= 100.0;
    final lineColor =
        isProfit ? const Color(0xFF00E676) : const Color(0xFFFF5252);

    final paint = Paint()
      ..color = lineColor
      ..strokeWidth = 2.2
      ..style = PaintingStyle.stroke;

    final path = Path();
    for (int i = 0; i < values.length; i++) {
      final x = values.length == 1
          ? size.width / 2
          : (i / (values.length - 1)) * size.width;
      final normY = (values[i] - minVal) / range;
      final y = size.height - (normY * (size.height - 12)) - 6;
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    if (values.length == 1) {
      canvas.drawLine(
        Offset(0, size.height / 2),
        Offset(size.width, size.height / 2),
        paint,
      );
    } else {
      canvas.drawPath(path, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _EquityCurvePainter oldDelegate) =>
      oldDelegate.points != points;
}

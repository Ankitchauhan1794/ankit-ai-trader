import 'dart:async';
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
        await channel.invokeMethod('postTradeAlertNotification', {
          'alertId': alert.alertId,
          'title': alert.title,
          'body': alert.body,
        });
      } catch (_) {}
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
    // Stage 6: Automatically resume trading session if userIntention == running
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
        scaffoldBackgroundColor: const Color(0xFF0B0F19),
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF00E676),
          brightness: Brightness.dark,
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
  late final TradingCoordinator _coordinator;
  late final bool _ownsCoordinator;

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
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Ankit AI Trader — PAPER BOT',
          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
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
        child: ListView(
          padding: const EdgeInsets.all(12),
          children: [
            _buildBannerCard(),
            const SizedBox(height: 8),
            OnePlusBatteryOptimizationCard(
              ignoringBatteryOptimizations:
                  _coordinator.ignoringBatteryOptimizations,
              onOpenSettings: _coordinator.openBatteryOptimizationSettings,
            ),
            const SizedBox(height: 8),
            _buildControlButtons(),
            const SizedBox(height: 12),
            _buildStatusGrid(),
            const SizedBox(height: 12),
            _buildAccountMetricsCard(),
            const SizedBox(height: 12),
            _buildLiveMarketCard(),
            const SizedBox(height: 12),
            _buildOpenPositionsCard(),
            const SizedBox(height: 12),
            _buildRecentTradesCard(),
            const SizedBox(height: 12),
            _buildTradeAlertsToggleCard(),
            const SizedBox(height: 12),
            _buildBacktestCard(),
            const SizedBox(height: 24),
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
        bg = Colors.green.shade700;
        label = 'RUNNING';
        break;
      case BotEngineState.pausedNetworkLoss:
        bg = Colors.orange.shade800;
        label = 'AUTO-RECOVERY (NET)';
        break;
      case BotEngineState.pausedStaleData:
        bg = Colors.orange.shade800;
        label = 'AUTO-RECOVERY (DATA)';
        break;
      case BotEngineState.pausedAfterRecoveryManualStartRequired:
        bg = Colors.amber.shade800;
        label = 'PAUSED';
        break;
      case BotEngineState.lockedDailyLossLimit:
        bg = Colors.red.shade800;
        label = 'DAILY LOSS LOCK';
        break;
      case BotEngineState.stoppedMaxDrawdownReached:
        bg = Colors.red.shade900;
        label = 'MAX DRAWDOWN STOP';
        break;
      case BotEngineState.stopped:
        bg = Colors.blueGrey.shade700;
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
      color: const Color(0xFF161F30),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _coordinator.statusBannerMessage,
              style: const TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 13,
                color: Colors.cyanAccent,
              ),
            ),
            const SizedBox(height: 6),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  _coordinator.formatHeartbeatStatus(),
                  key: const ValueKey('heartbeat_status_text'),
                  style: const TextStyle(fontSize: 12, color: Colors.white70),
                ),
                Text(
                  'Intention: ${_coordinator.userIntention.name.toUpperCase()}',
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: Colors.greenAccent,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildControlButtons() {
    final isRunningOrRecovering =
        _coordinator.engineState == BotEngineState.running ||
        _coordinator.userIntention == UserSessionIntention.running;

    return Row(
      children: [
        if (!isRunningOrRecovering)
          Expanded(
            child: ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.green.shade700,
                foregroundColor: Colors.white,
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
        if (isRunningOrRecovering) ...[
          Expanded(
            child: ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.amber.shade800,
                foregroundColor: Colors.white,
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
                backgroundColor: Colors.red.shade800,
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
      ],
    );
  }

  Widget _buildStatusGrid() {
    return Row(
      children: [
        Expanded(
          child: _metricTile(
            'ENGINE',
            _coordinator.engineState.name.toUpperCase(),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: _metricTile(
            'NETWORK',
            _coordinator.internetConnected ? 'ONLINE' : 'OFFLINE',
          ),
        ),
      ],
    );
  }

  Widget _buildAccountMetricsCard() {
    return Card(
      color: const Color(0xFF141B29),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  'PAPER ACCOUNT (\$100 INITIAL)',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                ),
                TextButton(
                  onPressed: _coordinator.manualResetDrawdownAndAccount,
                  child: const Text('RESET \$100'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: _metricTile(
                    'Equity (USDT)',
                    '\$${_coordinator.accountEquityUsdt.toStringAsFixed(2)}',
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _metricTile(
                    'Available Cash',
                    '\$${_coordinator.availableCashUsdt.toStringAsFixed(2)}',
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _metricTile(
                    'Drawdown (Max \$10)',
                    '\$${_coordinator.currentDrawdownUsdt.toStringAsFixed(2)}',
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// Stage 12: Rich live market information card (Last, Bid, Ask, 24h High/Low, Vol, Change).
  Widget _buildLiveMarketCard() {
    return Card(
      color: const Color(0xFF141B29),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'COINDCX LIVE MARKET FEED (WS + REST FALLBACK)',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
            ),
            const SizedBox(height: 10),
            _pairRow('B-BTC_USDT', 'BTC/USDT'),
            const Divider(height: 18),
            _pairRow('B-ETH_USDT', 'ETH/USDT'),
          ],
        ),
      ),
    );
  }

  Widget _pairRow(String symbol, String display) {
    final ticker = _coordinator.liveTickers[symbol];
    final price =
        ticker?.lastPrice ?? _coordinator.liveTickerPrices[symbol];
    final closed15m = _coordinator.closedCandlePrices[symbol];
    final whyNoTrade =
        _coordinator.whyNoTradeForSymbol[symbol] ?? 'Waiting for next evaluation';
    final change = ticker?.change24hPct ?? 0.0;
    final changeColor =
        change >= 0 ? Colors.greenAccent : Colors.redAccent;

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
      color: const Color(0xFF141B29),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'OPEN PAPER POSITIONS (${positions.length}/1)',
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
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
                    '${pos.symbol} — Qty: ${pos.quantity.toStringAsFixed(5)} @ \$${pos.entryPrice.toStringAsFixed(2)}',
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 13,
                    ),
                  ),
                  subtitle: Text(
                    'SL: \$${pos.stopLoss.toStringAsFixed(2)} | TP: \$${pos.takeProfit.toStringAsFixed(2)} | Mark: \$${mark.toStringAsFixed(2)}',
                    style: const TextStyle(fontSize: 12),
                  ),
                  trailing: Text(
                    '${upnl >= 0 ? "+" : ""}\$${upnl.toStringAsFixed(2)}',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      color: upnl >= 0 ? Colors.greenAccent : Colors.redAccent,
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
      color: const Color(0xFF141B29),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'CLOSED PAPER TRADES (${trades.length})',
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
            ),
            const SizedBox(height: 8),
            if (trades.isEmpty)
              const Text(
                'No closed paper trades yet.',
                style: TextStyle(fontSize: 12, color: Colors.white60),
              )
            else
              ...trades.take(10).map((t) {
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
                    'Entry: \$${t.entryPrice.toStringAsFixed(2)} -> Exit: \$${t.exitPrice.toStringAsFixed(2)} (Fees: \$${t.totalFeesUsdt.toStringAsFixed(3)})',
                    style: const TextStyle(fontSize: 11),
                  ),
                  trailing: Text(
                    '${win ? "+" : ""}\$${t.realizedPnlUsdt.toStringAsFixed(2)}',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      color: win ? Colors.greenAccent : Colors.redAccent,
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
      color: const Color(0xFF141B29),
      child: SwitchListTile(
        title: const Text(
          'Trade alert notifications',
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
      color: const Color(0xFF141B29),
      child: Padding(
        padding: const EdgeInsets.all(12),
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
            const SizedBox(height: 8),
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
              const SizedBox(height: 8),
              Text(
                'Trades: ${report.totalTrades} | Win Rate: ${report.winRatePct.toStringAsFixed(1)}% | Net PnL: \$${report.netPnlUsdt.toStringAsFixed(2)} | Max DD: \$${report.maxDrawdownUsdt.toStringAsFixed(2)}',
                style: const TextStyle(fontSize: 12, color: Colors.greenAccent),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _metricTile(String label, String value) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: const Color(0xFF1C2536),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: const TextStyle(fontSize: 11, color: Colors.white60),
          ),
          const SizedBox(height: 4),
          Text(
            value,
            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
          ),
        ],
      ),
    );
  }
}

import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'models/trading_models.dart';
import 'screens/dashboard_screen.dart';
import 'services/authoritative_engine.dart';
import 'services/autonomous_intelligence_and_ops.dart';
import 'services/coindcx_market_service.dart';
import 'services/persistence_db.dart';
import 'services/stage47_autonomous_governance.dart';
import 'services/trading_coordinator.dart';

@pragma('vm:entry-point')
Future<void> backgroundServiceMain() async {
  WidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.ankit.aitrader/background_worker');
  final persistence = PersistenceDatabase();
  final marketService = CoinDcxMarketService(persistence: persistence);

  late final AuthoritativeTradingEngine engine;
  engine = AuthoritativeTradingEngine(
    marketService: marketService,
    persistence: persistence,
    verifyReachabilityBeforeNetworkPause: true,
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
        scaffoldBackgroundColor: const Color(0xFF080B12),
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF00E676),
          brightness: Brightness.dark,
          surface: const Color(0xFF101622),
        ),
        cardTheme: CardTheme(
          color: const Color(0xFF101622),
          elevation: 0,
          margin: EdgeInsets.zero,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: const BorderSide(color: Color(0xFF1E293B), width: 1),
          ),
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
  static const Color _mutedSlate = Color(0xFF94A3B8);
  static const Color _surfaceSubtle = Color(0xFF161F30);

  late final TradingCoordinator _coordinator;
  late final bool _ownsCoordinator;
  int _selectedTabIndex = 0;
  int _tradesSubTabIndex = 0; // 0 = Open Positions, 1 = Closed Trades

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

  String _formatDurationMs(int durationMs) {
    final totalMin = (durationMs.abs() / 60000).floor();
    if (totalMin < 60) return '${totalMin}m';
    final h = totalMin ~/ 60;
    final m = totalMin % 60;
    if (h < 24) return '${h}h ${m}m';
    final d = h ~/ 24;
    final remH = h % 24;
    return '${d}d ${remH}h';
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
        backgroundColor: const Color(0xFF0B101B),
        elevation: 0,
        titleSpacing: 12,
        title: Row(
          children: [
            Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                color: const Color(0xFF152238),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: const Color(0xFF283B5B)),
              ),
              child: const Icon(
                Icons.candlestick_chart,
                color: _greenProfit,
                size: 20,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      const Flexible(
                        child: Text(
                          'Ankit AI Trader',
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 16,
                            color: Colors.white,
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: const Color(0xFF1E293B),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: const Text(
                          'PAPER',
                          style: TextStyle(
                            fontSize: 9,
                            fontWeight: FontWeight.bold,
                            color: Colors.amberAccent,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const Text(
                    'AI-Powered Multi-Pair Trading',
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 10, color: _mutedSlate),
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          Center(child: _statusChip(_coordinator.engineState)),
          IconButton(
            tooltip: 'Notifications & Settings',
            icon: Icon(
              _coordinator.tradeAlertsEnabled
                  ? Icons.notifications_active_outlined
                  : Icons.notifications_off_outlined,
              size: 20,
              color: Colors.white70,
            ),
            onPressed: () => setState(() => _selectedTabIndex = 5),
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () =>
            _coordinator.refreshStateFromDatabase(isInitialLoad: false),
        child: pages[_selectedTabIndex],
      ),
      bottomNavigationBar: NavigationBar(
        backgroundColor: const Color(0xFF0B101B),
        indicatorColor: const Color(0xFF0D2E1E),
        selectedIndex: _selectedTabIndex,
        onDestinationSelected: (idx) => setState(() => _selectedTabIndex = idx),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.home_outlined),
            selectedIcon: Icon(Icons.home, color: _greenProfit),
            label: 'Home',
          ),
          NavigationDestination(
            icon: Icon(Icons.candlestick_chart_outlined),
            selectedIcon: Icon(Icons.candlestick_chart, color: _greenProfit),
            label: 'Markets',
          ),
          NavigationDestination(
            icon: Icon(Icons.swap_horiz_outlined),
            selectedIcon: Icon(Icons.swap_horiz, color: _greenProfit),
            label: 'Trades',
          ),
          NavigationDestination(
            icon: Icon(Icons.memory_outlined),
            selectedIcon: Icon(Icons.memory, color: _greenProfit),
            label: 'AI Lab',
          ),
          NavigationDestination(
            icon: Icon(Icons.bar_chart_outlined),
            selectedIcon: Icon(Icons.bar_chart, color: _greenProfit),
            label: 'Reports',
          ),
          NavigationDestination(
            icon: Icon(Icons.settings_outlined),
            selectedIcon: Icon(Icons.settings, color: _greenProfit),
            label: 'Settings',
          ),
        ],
      ),
    );
  }

  // ===========================================================================
  // 1. HOME DASHBOARD (Matches 01_home_dashboard_mockup.png + Sections 4 & 10)
  // Note: Start/Pause/Stop controls are kept in Settings per Section 4 & 9.
  // ===========================================================================
  Widget _buildHomeTab() {
    final dailyPnl = _coordinator.dailyPnlUsdt;
    final dailyPct = _coordinator.startOfDayEquityUsdt > 0
        ? (dailyPnl / _coordinator.startOfDayEquityUsdt) * 100.0
        : 0.0;
    final overallPnl = _coordinator.overallPnlUsdt;
    final overallPct = overallPnl; // Base capital is $100.00
    final dd = _coordinator.currentDrawdownUsdt;

    final closed = _coordinator.closedTrades;
    final totalTrades = closed.length;
    final wins = closed.where((t) => t.realizedPnlUsdt >= 0).length;
    final losses = totalTrades - wins;
    final winRateStr = totalTrades > 0
        ? '${((wins / totalTrades) * 100.0).toStringAsFixed(0)}%'
        : '—';
    final pf = _coordinator.latestRobustnessReport?.profitFactor;
    final pfStr = (totalTrades > 0 && pf != null && pf > 0)
        ? pf.toStringAsFixed(2)
        : '—';

    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        // Top Account Overview Card (Mockup Row 1)
        Card(
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text(
                      'PORTFOLIO OVERVIEW',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                        color: _mutedSlate,
                        letterSpacing: 0.4,
                      ),
                    ),
                    InkWell(
                      onTap: () => setState(() => _selectedTabIndex = 5),
                      child: Text(
                        'Bot Controls (${_coordinator.userIntention.name.toUpperCase()}) >',
                        style: const TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: _greenProfit,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      flex: 5,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Equity',
                            style: TextStyle(fontSize: 12, color: _mutedSlate),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            '\$${_coordinator.accountEquityUsdt.toStringAsFixed(2)}',
                            style: const TextStyle(
                              fontSize: 24,
                              fontWeight: FontWeight.bold,
                              color: Colors.white,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'Balance: \$100.00  |  Available: \$${_coordinator.availableCashUsdt.toStringAsFixed(2)}',
                            style: const TextStyle(
                              fontSize: 11,
                              color: Colors.white70,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            'Used Margin: \$${_coordinator.usedMarginUsdt.toStringAsFixed(2)}  |  Free Margin: \$${_coordinator.freeMarginUsdt.toStringAsFixed(2)}',
                            style: const TextStyle(
                              fontSize: 10,
                              color: _mutedSlate,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      flex: 7,
                      child: Row(
                        children: [
                          Expanded(
                            child: _metricTile(
                              'Daily P&L',
                              '${dailyPnl >= 0 ? "+" : ""}\$${dailyPnl.toStringAsFixed(2)} (${dailyPct >= 0 ? "+" : ""}${dailyPct.toStringAsFixed(2)}%)',
                              valueColor:
                                  dailyPnl >= 0 ? _greenProfit : _redLoss,
                            ),
                          ),
                          const SizedBox(width: 6),
                          Expanded(
                            child: _metricTile(
                              'Overall P&L',
                              '${overallPnl >= 0 ? "+" : ""}\$${overallPnl.toStringAsFixed(2)} (${overallPct >= 0 ? "+" : ""}${overallPct.toStringAsFixed(2)}%)',
                              valueColor:
                                  overallPnl >= 0 ? _greenProfit : _redLoss,
                            ),
                          ),
                          const SizedBox(width: 6),
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
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 10),
        // Trading Statistics Strip (Mockup Row 2)
        Card(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(
              children: [
                Expanded(
                  child: _statStripItem(
                    Icons.swap_horiz,
                    'Trades (W/L)',
                    '$totalTrades ($wins/$losses)',
                    Colors.white,
                  ),
                ),
                Expanded(
                  child: _statStripItem(
                    Icons.emoji_events_outlined,
                    'Win Rate',
                    winRateStr,
                    Colors.white,
                  ),
                ),
                Expanded(
                  child: _statStripItem(
                    Icons.memory_outlined,
                    'Profit Factor',
                    pfStr,
                    Colors.white,
                  ),
                ),
                Expanded(
                  child: _statStripItem(
                    Icons.bar_chart,
                    'Total Profit',
                    '${overallPnl >= 0 ? "+" : ""}\$${overallPnl.toStringAsFixed(2)}',
                    overallPnl >= 0 ? _greenProfit : _redLoss,
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 10),
        // Equity Curve + Market Overview (Mockup Row 3)
        _buildEquityCurveCard(),
        const SizedBox(height: 10),
        _buildHomeMarketOverviewCard(),
        const SizedBox(height: 10),
        // Open Positions + System Status (Mockup Row 4)
        _buildOpenPositionsCard(showHeaderLinkToTrades: true),
        const SizedBox(height: 10),
        _buildSystemHealthSummaryCard(),
        const SizedBox(height: 10),
        _buildRiskInformationDisplayCard(),
        const SizedBox(height: 18),
      ],
    );
  }

  Widget _statStripItem(
    IconData icon,
    String label,
    String value,
    Color valueColor,
  ) {
    return Row(
      children: [
        Icon(icon, size: 18, color: _mutedSlate),
        const SizedBox(width: 6),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 10, color: _mutedSlate),
              ),
              const SizedBox(height: 2),
              Text(
                value,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.bold,
                  color: valueColor,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildHomeMarketOverviewCard() {
    final eligible = _coordinator.marketCatalogue.eligibleMarkets;
    final displaySymbols = eligible.isNotEmpty
        ? eligible.take(4).map((m) => m.pair).toList()
        : ['B-BTC_USDT', 'B-ETH_USDT'];

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
                  'Market Overview',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                ),
                InkWell(
                  onTap: () => setState(() => _selectedTabIndex = 1),
                  child: const Text(
                    'See All >',
                    style: TextStyle(
                      fontSize: 12,
                      color: Colors.lightBlueAccent,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            const Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  flex: 4,
                  child: Text(
                    'Symbol',
                    style: TextStyle(fontSize: 11, color: _mutedSlate),
                  ),
                ),
                Expanded(
                  flex: 3,
                  child: Text(
                    'Price',
                    textAlign: TextAlign.right,
                    style: TextStyle(fontSize: 11, color: _mutedSlate),
                  ),
                ),
                Expanded(
                  flex: 3,
                  child: Text(
                    '24h % / Vol',
                    textAlign: TextAlign.right,
                    style: TextStyle(fontSize: 11, color: _mutedSlate),
                  ),
                ),
              ],
            ),
            const Divider(height: 14, color: Color(0xFF1E293B)),
            ...displaySymbols.map((sym) {
              final rec = _coordinator.marketService.catalogueByPair[sym];
              final ticker =
                  _coordinator.liveTickers[sym] ?? rec?.latestTicker;
              final px =
                  ticker?.lastPrice ?? _coordinator.liveTickerPrices[sym];
              final chg = ticker?.change24hPct ?? 0.0;
              final vol = ticker?.volume24h ?? 0.0;
              final fresh = ticker != null &&
                  (_coordinator.lastMarketDataUpdateMs != null);
              final label = rec != null ? rec.symbol : sym;
              return InkWell(
                onTap: () {
                  if (rec != null) {
                    _showMarketDetailBottomSheet(rec);
                  } else {
                    setState(() => _selectedTabIndex = 1);
                  }
                },
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Expanded(
                        flex: 4,
                        child: Row(
                          children: [
                            Container(
                              width: 8,
                              height: 8,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: fresh ? _greenProfit : _orangeWarn,
                              ),
                            ),
                            const SizedBox(width: 6),
                            Flexible(
                              child: Text(
                                label,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 12,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      Expanded(
                        flex: 3,
                        child: Text(
                          px != null ? '\$${px.toStringAsFixed(2)}' : '--',
                          textAlign: TextAlign.right,
                          style: const TextStyle(
                            fontWeight: FontWeight.w600,
                            fontSize: 12,
                          ),
                        ),
                      ),
                      Expanded(
                        flex: 3,
                        child: Text(
                          px != null
                              ? '${chg >= 0 ? "+" : ""}${chg.toStringAsFixed(2)}% • ${vol.toStringAsFixed(0)}'
                              : 'Waiting...',
                          textAlign: TextAlign.right,
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                            color: chg >= 0 ? _greenProfit : _redLoss,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              );
            }),
          ],
        ),
      ),
    );
  }

  /// Section 10: Informative Risk Information Display using current engine configuration.
  Widget _buildRiskInformationDisplayCard() {
    final openRisk = _coordinator.currentOpenPositionRiskUsdt;
    final remDaily = _coordinator.remainingDailyRiskBudgetUsdt;
    final remDd = _coordinator.remainingDrawdownBudgetUsdt;
    final isLocked = _coordinator.maxDrawdownLocked ||
        _coordinator.lockedDailyLossUtcDate != null ||
        _coordinator.engineState.isRiskLock;

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
                  'RISK SUPERVISOR & PORTFOLIO LIMITS',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    color: _mutedSlate,
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: isLocked
                        ? _redLoss.withOpacity(0.2)
                        : _greenProfit.withOpacity(0.16),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    isLocked ? 'RISK LOCK ACTIVE' : 'GUARD ACTIVE (UNLOCKED)',
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                      color: isLocked ? _redLoss : _greenProfit,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            _diagRow(
              'Individual Trade Risk Limit',
              '1.0% (\$1.00 USDT max incl. fees & slippage)',
              Colors.white,
            ),
            _diagRow(
              'Daily Loss Limit / Remaining Today',
              '\$2.00 max / \$${remDaily.toStringAsFixed(2)} remaining',
              remDaily > 0.5 ? _greenProfit : _orangeWarn,
            ),
            _diagRow(
              'Account Drawdown Limit / Remaining',
              '\$10.00 max (\$90.00 floor) / \$${remDd.toStringAsFixed(2)} remaining',
              remDd > 3.0 ? _greenProfit : _orangeWarn,
            ),
            _diagRow(
              'Max Concurrent Open Positions',
              '${_coordinator.openPositions.length} / 1',
              Colors.white,
            ),
            _diagRow(
              'Combined Open-Position Risk',
              '\$${openRisk.toStringAsFixed(2)} USDT',
              openRisk <= 1.35 ? _greenProfit : _orangeWarn,
            ),
          ],
        ),
      ),
    );
  }

  // ===========================================================================
  // 2. MARKETS SCREEN (Section 5: Dynamic Watchlist, Favourites, Search & Detail Sheet)
  // ===========================================================================
  Widget _buildMarketsTab() {
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        _buildMarketCatalogueSummaryAndFiltersCard(),
        const SizedBox(height: 12),
        _buildDiscoveredMarketCatalogueListCard(),
        const SizedBox(height: 12),
        _buildLiveMarketCard(),
        const SizedBox(height: 12),
        _buildMarketScannerCard(),
      ],
    );
  }

  void _showMarketDetailBottomSheet(CoinDcxMarketRecord market) {
    String selectedInterval = '15m';
    Future<List<Candle>>? candlesFuture = _coordinator.marketService
        .fetchClosedCandles(
          pair: market.pair.isNotEmpty ? market.pair : 'B-BTC_USDT',
          interval: selectedInterval,
          nowMs: DateTime.now().millisecondsSinceEpoch,
          limit: 60,
        );

    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF101622),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setModalState) {
            final t = market.latestTicker;
            return DraggableScrollableSheet(
              expand: false,
              initialChildSize: 0.78,
              minChildSize: 0.5,
              maxChildSize: 0.94,
              builder: (_, scrollCtrl) {
                return ListView(
                  controller: scrollCtrl,
                  padding: const EdgeInsets.all(16),
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '${market.symbol} (${market.pair})',
                              style: const TextStyle(
                                fontSize: 17,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            Text(
                              'Exchange: ${market.exchangeName} (${market.ecode}) • Asset: ${market.targetCurrencyShortName} • Quote: ${market.baseCurrencyShortName}',
                              style: const TextStyle(
                                fontSize: 11,
                                color: _mutedSlate,
                              ),
                            ),
                          ],
                        ),
                        IconButton(
                          icon: const Icon(Icons.close),
                          onPressed: () => Navigator.of(ctx).pop(),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    if (t != null)
                      Row(
                        children: [
                          Expanded(
                            child: _metricTile(
                              'Last Price',
                              '${t.lastPrice.toStringAsFixed(market.pricePrecision.clamp(2, 8))} ${market.baseCurrencyShortName}',
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: _metricTile(
                              '24h Change',
                              '${t.change24hPct >= 0 ? "+" : ""}${t.change24hPct.toStringAsFixed(2)}%',
                              valueColor: t.change24hPct >= 0
                                  ? _greenProfit
                                  : _redLoss,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: _metricTile(
                              'Spread',
                              '${t.spreadBps.toStringAsFixed(1)} bps',
                            ),
                          ),
                        ],
                      ),
                    const SizedBox(height: 12),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text(
                          'CLOSED CANDLESTICK CHART',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                            color: _mutedSlate,
                          ),
                        ),
                        Row(
                          children: ['15m', '1h'].map((tf) {
                            final active = selectedInterval == tf;
                            return Padding(
                              padding: const EdgeInsets.only(left: 6),
                              child: ChoiceChip(
                                label: Text(
                                  tf,
                                  style: const TextStyle(fontSize: 11),
                                ),
                                selected: active,
                                onSelected: (_) {
                                  setModalState(() {
                                    selectedInterval = tf;
                                    candlesFuture = _coordinator.marketService
                                        .fetchClosedCandles(
                                          pair: market.pair.isNotEmpty
                                              ? market.pair
                                              : 'B-BTC_USDT',
                                          interval: selectedInterval,
                                          nowMs: DateTime.now()
                                              .millisecondsSinceEpoch,
                                          limit: 60,
                                        );
                                  });
                                },
                              ),
                            );
                          }).toList(),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Container(
                      height: 180,
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: const Color(0xFF0B101B),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: const Color(0xFF1E293B)),
                      ),
                      child: FutureBuilder<List<Candle>>(
                        future: candlesFuture,
                        builder: (context, snapshot) {
                          if (snapshot.connectionState ==
                              ConnectionState.waiting) {
                            return const Center(
                              child: CircularProgressIndicator(),
                            );
                          }
                          final candles = snapshot.data ?? const [];
                          if (candles.isEmpty) {
                            return const Center(
                              child: Text(
                                'Closed candle history unavailable for this pair in current mode.',
                                style: TextStyle(
                                  fontSize: 11,
                                  color: _mutedSlate,
                                ),
                              ),
                            );
                          }
                          return CustomPaint(
                            size: const Size(double.infinity, 160),
                            painter: _CandlestickChartPainter(candles: candles),
                          );
                        },
                      ),
                    ),
                    const SizedBox(height: 14),
                    const Text(
                      'COINDCX MARKET SPECIFICATIONS',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                        color: _mutedSlate,
                      ),
                    ),
                    const SizedBox(height: 6),
                    _diagRow('Market Status', market.status.toUpperCase(),
                        market.isActiveStatus ? _greenProfit : _redLoss),
                    _diagRow(
                      'Eligibility',
                      '${market.eligibilityStatus.categoryLabel} (${market.eligibilityStatus.name})',
                      market.isEligibleForPaperTrading
                          ? _greenProfit
                          : _orangeWarn,
                    ),
                    _diagRow('Eligibility Reason', market.eligibilityReason,
                        Colors.white70),
                    _diagRow(
                      'Price / Quantity Precision',
                      '${market.pricePrecision} decimals / ${market.quantityPrecision} decimals',
                      Colors.white70,
                    ),
                    _diagRow(
                      'Min / Max Quantity',
                      '${market.minQuantity} / ${market.maxQuantity} ${market.targetCurrencyShortName}',
                      Colors.white70,
                    ),
                    _diagRow('Quantity Step', '${market.step}', Colors.white70),
                    _diagRow(
                      'Minimum Notional',
                      '${market.minNotional} ${market.baseCurrencyShortName}',
                      Colors.white70,
                    ),
                    _diagRow(
                      'Supported Order Types',
                      market.orderTypes.join(', '),
                      Colors.white70,
                    ),
                  ],
                );
              },
            );
          },
        );
      },
    );
  }

  // ===========================================================================
  // 3. TRADES SCREEN (Section 6: Open Positions & Filtered Closed Trades)
  // ===========================================================================
  Widget _buildTradesTab() {
    final openCount = _coordinator.openPositions.length;
    final closedCount = _coordinator.closedTrades.length;

    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Row(
              children: [
                Expanded(
                  child: ChoiceChip(
                    key: const ValueKey('trades_subtab_open'),
                    label: Text(
                      'Open Positions ($openCount)',
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                    selected: _tradesSubTabIndex == 0,
                    onSelected: (_) => setState(() => _tradesSubTabIndex = 0),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: ChoiceChip(
                    key: const ValueKey('trades_subtab_closed'),
                    label: Text(
                      'Closed Trades ($closedCount)',
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                    selected: _tradesSubTabIndex == 1,
                    onSelected: (_) => setState(() => _tradesSubTabIndex = 1),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        if (_tradesSubTabIndex == 0) ...[
          _buildOpenPositionsCard(),
          const SizedBox(height: 12),
          _buildRecentTradesCard(),
        ] else ...[
          _buildClosedTradesFilterBar(),
          const SizedBox(height: 12),
          _buildRecentTradesCard(),
        ],
      ],
    );
  }

  Widget _buildClosedTradesFilterBar() {
    final pairs = ['ALL', ..._coordinator.tradedPairSymbols];
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'FILTER CLOSED TRADES',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.bold,
                color: _mutedSlate,
              ),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: ['ALL', 'WINNING', 'LOSING'].map((mode) {
                final selected =
                    _coordinator.closedTradesOutcomeFilter == mode;
                return ChoiceChip(
                  label: Text(mode, style: const TextStyle(fontSize: 11)),
                  selected: selected,
                  onSelected: (_) =>
                      _coordinator.setClosedTradesOutcomeFilter(mode),
                );
              }).toList(),
            ),
            if (pairs.length > 1) ...[
              const SizedBox(height: 8),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: pairs.map((p) {
                  final selected = _coordinator.closedTradesPairFilter == p;
                  return ChoiceChip(
                    label: Text(
                      p == 'ALL' ? 'All Pairs' : p,
                      style: const TextStyle(fontSize: 11),
                    ),
                    selected: selected,
                    onSelected: (_) =>
                        _coordinator.setClosedTradesPairFilter(p),
                  );
                }).toList(),
              ),
            ],
          ],
        ),
      ),
    );
  }

  // ===========================================================================
  // 4. AI LAB SCREEN (Section 7: Deterministic vs External AI, Scanning & Validation)
  // ===========================================================================
  Widget _buildAiLabTab() {
    final activeStrat = _coordinator.strategyRegistry.activeStrategy;
    final expStrats = _coordinator.strategyRegistry.experimentalStrategies;
    final costEst = _coordinator.agentOrchestrator.estimateCouncilRunCost();
    final hypotheses =
        SandboxedStrategyBuilderAndOptimizer.generateSandboxedHypotheses();
    final sd = _coordinator.scanDiagnostics;
    final whyMap = _coordinator.whyNoTradeForSymbol;

    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text(
                      'ENGINE EXECUTION MODE & AI STATUS',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 13,
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(0xFF0D2E1E),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: const Text(
                        'LOCAL DETERMINISTIC ACTIVE',
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                          color: _greenProfit,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                _diagRow(
                  'Local Deterministic Engine',
                  'ACTIVE (EMA/RSI/ATR + Risk Supervisor)',
                  _greenProfit,
                ),
                _diagRow(
                  'External Cloud LLM Agents',
                  'INACTIVE (Stage 20B VPS Not Configured • \$0.00 Spend)',
                  _orangeWarn,
                ),
                _diagRow(
                  'Last Market Scan Activity',
                  '${sd.totalPairsEvaluated} pairs evaluated / ${sd.pairsSkippedCount} skipped',
                  sd.totalPairsEvaluated > 0 ? _greenProfit : _mutedSlate,
                ),
                _diagRow(
                  'Signals (Generated / Accepted / Rejected)',
                  '${sd.signalsGeneratedCount} total (${sd.buySignalsCount} BUY, ${sd.sellSignalsCount} SELL) • ${sd.acceptedOrdersCount} accepted • ${sd.rejectedSignalsCount} rejected',
                  Colors.white70,
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'STAGE 29 — STRATEGY REGISTRY (CHAMPION: ${activeStrat.id})',
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 13,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  '${activeStrat.name} (v${activeStrat.version})\n'
                  '• ${activeStrat.rulesSummary}\n'
                  '• Risk / Exit: SL = 1.5 × ATR(14), TP = 3.0 × ATR(14), 1% (\$1) Risk/Trade, 30m Cooldown\n'
                  '• Sandbox Challengers (${expStrats.length}): ${expStrats.map((s) => s.id).join(", ")}',
                  style: const TextStyle(
                    fontSize: 12,
                    color: Colors.white70,
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        _buildBacktestCard(),
        const SizedBox(height: 12),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'RECENTLY EVALUATED PAIRS & DECISION EXPLANATIONS',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                ),
                const SizedBox(height: 8),
                if (whyMap.isEmpty)
                  const Text(
                    'No pair evaluations recorded yet in current session.',
                    style: TextStyle(fontSize: 12, color: Colors.white60),
                  )
                else
                  ...whyMap.entries.take(15).map(
                        (e) => Padding(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          child: Text(
                            '• ${e.key}: ${e.value}',
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
        const SizedBox(height: 12),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'STAGES 34–37 — RESEARCH AGENTS & SANDBOX BUILDER',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                ),
                const SizedBox(height: 6),
                Text(
                  costEst.notice,
                  style: const TextStyle(fontSize: 11, color: Colors.white70),
                ),
                const SizedBox(height: 6),
                const Text(
                  '• Desks: Scanner, Technical, News/Macro, Sentiment, Bull, Bear, Quant, Chief Analyst\n'
                  '• Stage 27 Gate: Independent Risk Supervisor holds absolute deterministic veto\n'
                  '• Stage 36 Builder: Generates declarative sandbox configs only (never live code)',
                  style: TextStyle(
                    fontSize: 11,
                    color: Colors.white60,
                    height: 1.35,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  'Active Sandbox Hypotheses: ${hypotheses.map((h) => h.configId).join(", ")}',
                  style: const TextStyle(fontSize: 11, color: Colors.white54),
                ),
                const SizedBox(height: 8),
                Text(
                  'STAGE 47.2/47.3/47.10 — Champion Model: ${_coordinator.modelGovernanceRegistry.activeProductionModel.modelId} | Monthly AI Spend: \$${_coordinator.aiCostManager.currentMonthSpendUsd.toStringAsFixed(4)} / \$${_coordinator.aiCostManager.monthlyBudgetUsd.toStringAsFixed(2)} | Statistical Audit: ${_coordinator.latestStatisticalOverfittingReport.rejectionOrApprovalReason}',
                  style: const TextStyle(fontSize: 11, color: Colors.white70),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  // ===========================================================================
  // 5. REPORTS SCREEN (Section 8: Financial Analytics, Drawdown, Duration & CSV Export)
  // ===========================================================================
  Widget _buildReportsTab() {
    final hbLevel = _coordinator.heartbeatHealthLevel;
    final hbColor = hbLevel == 'OK'
        ? _greenProfit
        : (hbLevel == 'DELAYED' ? _orangeWarn : _redLoss);
    final events = _coordinator.recentEvents;
    final alloc = _coordinator.currentPortfolioAllocation;
    final paperStatus = _coordinator.extendedPaperStatus;
    final liveGate = _coordinator.controlledLiveGateStatus;

    final pnl24h =
        _coordinator.computeRealizedPnlForWindowMs(24 * 60 * 60 * 1000);
    final pnl7d =
        _coordinator.computeRealizedPnlForWindowMs(7 * 24 * 60 * 60 * 1000);
    final pnl30d =
        _coordinator.computeRealizedPnlForWindowMs(30 * 24 * 60 * 60 * 1000);
    final totalPnl = _coordinator.overallPnlUsdt;

    final pairPnlEntries = _coordinator.realizedPnlByPair.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final durStats = _coordinator.tradeDurationStats;

    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        // Financial Period Performance Card
        Card(
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text(
                      'FINANCIAL PERFORMANCE ANALYTICS',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 13,
                      ),
                    ),
                    OutlinedButton.icon(
                      onPressed: _showCsvAccountingExportDialog,
                      icon: const Icon(Icons.download_outlined, size: 15),
                      label: const Text(
                        'EXPORT CSV',
                        style: TextStyle(fontSize: 11),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: _metricTile(
                        'Daily (24H)',
                        '${pnl24h >= 0 ? "+" : ""}\$${pnl24h.toStringAsFixed(2)}',
                        valueColor: pnl24h >= 0 ? _greenProfit : _redLoss,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: _metricTile(
                        'Weekly (7D)',
                        '${pnl7d >= 0 ? "+" : ""}\$${pnl7d.toStringAsFixed(2)}',
                        valueColor: pnl7d >= 0 ? _greenProfit : _redLoss,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: _metricTile(
                        'Monthly (30D)',
                        '${pnl30d >= 0 ? "+" : ""}\$${pnl30d.toStringAsFixed(2)}',
                        valueColor: pnl30d >= 0 ? _greenProfit : _redLoss,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: _metricTile(
                        'Total P&L',
                        '${totalPnl >= 0 ? "+" : ""}\$${totalPnl.toStringAsFixed(2)}',
                        valueColor: totalPnl >= 0 ? _greenProfit : _redLoss,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                _diagRow(
                  'Best Performing Pair',
                  pairPnlEntries.isNotEmpty
                      ? '${pairPnlEntries.first.key} (\$${pairPnlEntries.first.value.toStringAsFixed(2)})'
                      : 'Insufficient trade history',
                  pairPnlEntries.isNotEmpty && pairPnlEntries.first.value >= 0
                      ? _greenProfit
                      : Colors.white60,
                ),
                _diagRow(
                  'Worst Performing Pair',
                  pairPnlEntries.isNotEmpty
                      ? '${pairPnlEntries.last.key} (\$${pairPnlEntries.last.value.toStringAsFixed(2)})'
                      : 'Insufficient trade history',
                  pairPnlEntries.isNotEmpty && pairPnlEntries.last.value < 0
                      ? _redLoss
                      : Colors.white60,
                ),
                _diagRow(
                  'Trade Duration (Avg / Min / Max)',
                  _coordinator.closedTrades.isNotEmpty
                      ? '${durStats.avgMinutes}m / ${durStats.minMinutes}m / ${durStats.maxMinutes}m'
                      : 'No completed trades yet',
                  Colors.white70,
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        // Drawdown Chart Card
        Card(
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'PORTFOLIO DRAWDOWN CURVE (MAX BUDGET \$10.00)',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    color: _mutedSlate,
                  ),
                ),
                const SizedBox(height: 8),
                SizedBox(
                  height: 75,
                  width: double.infinity,
                  child: CustomPaint(
                    painter: _DrawdownChartPainter(
                      points: _coordinator.equityCurve.isEmpty
                          ? [
                              EquityPoint(
                                timestampMs: 0,
                                equityUsdt: _coordinator.accountEquityUsdt,
                              )
                            ]
                          : _coordinator.equityCurve,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
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
                  '${_coordinator.engineState.dashboardLabel} (${_coordinator.engineState.name})',
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
        const SizedBox(height: 12),
        _buildMultiPairPipelineDiagnosticsCard(),
        const SizedBox(height: 12),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'STAGES 39, 45 & 46 — PORTFOLIO & LIVE AUTHORIZATION GATE',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                ),
                const SizedBox(height: 8),
                Text(
                  '• Portfolio Rule: ${alloc.summary}\n'
                  '• Stage 45 (90-Day Paper): ${paperStatus.statusSummary}\n'
                  '• Stage 46 (Controlled Live): ${liveGate.gateReason}\n'
                  '• Stage 47.4 Cash-Flow Recon: ${_coordinator.latestBalanceReconciliation.securityAlertMessage}\n'
                  '• Stage 47.9 Attribution: TWR ${_coordinator.latestPerformanceAttribution.timeWeightedReturnPct.toStringAsFixed(2)}% | MWR ${_coordinator.latestPerformanceAttribution.moneyWeightedReturnPct.toStringAsFixed(2)}% (Deposits excluded)\n'
                  '• Stage 47.13 & 47.15 Autonomy: ${_coordinator.stressScenarioResults.length}/13 Stress Scenarios Verified | ${_coordinator.autonomous18StepCycleReport.length}/18 Governance Cycle Steps Active',
                  style: const TextStyle(
                    fontSize: 11,
                    color: Colors.white70,
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
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

  void _showCsvAccountingExportDialog() {
    final csv = _coordinator.latestTaxAccountingSummary.csvExportContent;
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF101622),
        title: const Text(
          'CSV Accounting & Trade History Export',
          style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
        ),
        content: SizedBox(
          width: double.maxFinite,
          child: SingleChildScrollView(
            child: SelectableText(
              csv,
              style: const TextStyle(fontSize: 11, fontFamily: 'monospace'),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: csv));
              Navigator.of(ctx).pop();
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('CSV report copied to clipboard.'),
                ),
              );
            },
            child: const Text('COPY CSV'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('CLOSE'),
          ),
        ],
      ),
    );
  }

  // ===========================================================================
  // 6. SETTINGS SCREEN (Section 9: 9 Categories + Bot Controls + Confirmation Dialogs)
  // ===========================================================================
  Widget _buildSettingsTab() {
    final changelog = SoftwareMaintenanceGovernance.changelog;

    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        // Category 1: Bot Controls
        Card(
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '1. BOT CONTROLS (PAPER TRADING ENGINE)',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                ),
                const SizedBox(height: 6),
                Text(
                  _coordinator.statusBannerMessage,
                  style: const TextStyle(fontSize: 12, color: Colors.white70),
                ),
                const SizedBox(height: 12),
                _buildControlButtons(),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        // Category 2: Risk Management (Read-Only Verified Settings)
        _buildRiskInformationDisplayCard(),
        const SizedBox(height: 12),
        // Category 3: Paper Account Configuration
        Card(
          child: ListTile(
            title: const Text(
              '3. Paper Account Configuration (\$100.00 USDT)',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
            ),
            subtitle: const Text(
              'Initial Capital: \$100.00 USDT • Fee: 0.10% • Slippage: 5 bps • Paper-Only Mode (Live Locked).',
              style: TextStyle(fontSize: 11),
            ),
            trailing: OutlinedButton(
              onPressed: _confirmAndResetAccount,
              child: const Text('RESET \$100'),
            ),
          ),
        ),
        const SizedBox(height: 12),
        // Category 4: Notifications
        _buildTradeAlertsToggleCard(),
        const SizedBox(height: 12),
        // Category 5: CoinDCX Connection Status & Auto-Resume
        Card(
          child: Column(
            children: [
              ListTile(
                title: const Text(
                  '5. CoinDCX Public API Connection Status',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                ),
                subtitle: Text(
                  'REST Status: ${_coordinator.scanDiagnostics.coindcxRestStatus} | Discovered Pairs: ${_coordinator.marketCatalogue.totalDiscoveredCount}',
                  style: const TextStyle(fontSize: 11),
                ),
              ),
              SwitchListTile(
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
            ],
          ),
        ),
        const SizedBox(height: 12),
        // Category 6: OnePlus Battery & Android Background Permissions
        OnePlusBatteryOptimizationCard(
          ignoringBatteryOptimizations:
              _coordinator.ignoringBatteryOptimizations,
          notificationPermissionGranted:
              _coordinator.notificationPermissionGranted,
          onOpenSettings: _coordinator.openBatteryOptimizationSettings,
          onOpenNotifications: _coordinator.openNotificationSettings,
        ),
        const SizedBox(height: 12),
        // Category 7: VPS Configuration & Security
        const Card(
          child: ListTile(
            title: Text(
              '6. VPS Configuration & Stage 43/46 Security Lock',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
            ),
            subtitle: Text(
              'Running in Local Android Foreground Service Mode. Cloud VPS (Stage 20B) is not configured. Trade-only permissions enforced; withdrawals disabled; Stage 46 Controlled Live is HARD-LOCKED.',
              style: TextStyle(fontSize: 11),
            ),
          ),
        ),
        const SizedBox(height: 12),
        // Category 8 & 9: Backup, Restore & App Information
        Card(
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '7. BACKUP, RESTORE & APPLICATION INFORMATION',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                ),
                const SizedBox(height: 8),
                _diagRow('Package ID', 'com.ankit.aitrader', Colors.white70),
                _diagRow('Release Version', 'v1.47.1 (SQLite Schema v4)',
                    _greenProfit),
                _diagRow(
                  'Database Integrity',
                  _coordinator.latestResilienceSnapshot.databaseIntegrityOk
                      ? 'VERIFIED (ankit_ai_trader_phase1.db)'
                      : 'DEGRADED',
                  _greenProfit,
                ),
                const SizedBox(height: 6),
                ...changelog.map(
                  (c) => Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Text(
                      '• ${c.versionTag}: ${c.description}',
                      style: const TextStyle(
                        fontSize: 11,
                        color: Colors.white60,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 18),
      ],
    );
  }

  Future<void> _confirmAndStopBot() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF101622),
        title: const Text('Stop Paper Trading Bot?'),
        content: const Text(
          'Stopping the bot will set your session intention to STOPPED and halt background market scans until you press START again.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('CANCEL'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: _redLoss),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('STOP BOT'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await _coordinator.stopBot();
    }
  }

  Future<void> _confirmAndResetAccount() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF101622),
        title: const Text('Reset \$100.00 Paper Account?'),
        content: const Text(
          'This will close open paper positions, clear simulated trade history, and restore available cash to \$100.00 USDT.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('CANCEL'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: _orangeWarn),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('RESET \$100'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await _coordinator.manualResetDrawdownAndAccount();
    }
  }

  Widget _buildMarketCatalogueSummaryAndFiltersCard() {
    final cat = _coordinator.marketCatalogue;
    final lastRef = cat.lastSuccessfulRefreshMs != null
        ? TradingCoordinator.formatUtcHhMmSs(cat.lastSuccessfulRefreshMs!)
        : 'Never';
    final cacheBadgeText = cat.isUsingCachedCatalogue
        ? 'CACHED CATALOGUE (OFFLINE)'
        : (cat.isCatalogueFresh ? 'LIVE CATALOGUE' : 'AWAITING REFRESH');
    final cacheBadgeColor = cat.isUsingCachedCatalogue
        ? _orangeWarn
        : (cat.isCatalogueFresh ? _greenProfit : Colors.white54);

    const quoteOptions = ['ALL', 'USDT', 'INR', 'BTC', 'ETH', 'OTHER'];

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Expanded(
                  child: Text(
                    'STAGE 47.1 — COINDCX SPOT MARKET CATALOGUE',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                  ),
                ),
                Text(
                  cacheBadgeText,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    color: cacheBadgeColor,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: _metricTile(
                    'Discovered',
                    '${cat.totalDiscoveredCount}',
                    valueColor: Colors.white,
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: _metricTile(
                    'Active',
                    '${cat.activeMarketsCount}',
                    valueColor: _greenProfit,
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: _metricTile(
                    'Inactive',
                    '${cat.inactiveMarketsCount}',
                    valueColor: Colors.white60,
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: _metricTile(
                    'Eligible',
                    '${cat.eligibleMarketsCount}',
                    valueColor: _greenProfit,
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: _metricTile(
                    'Rejected',
                    '${cat.rejectedMarketsCount}',
                    valueColor: _orangeWarn,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: Text(
                    'Last Catalogue Refresh: $lastRef',
                    style: const TextStyle(fontSize: 11, color: Colors.white70),
                  ),
                ),
                OutlinedButton.icon(
                  key: const ValueKey('refresh_market_catalogue_button'),
                  onPressed: _coordinator.isRefreshingCatalogue
                      ? null
                      : () => _coordinator.refreshMarketCatalogue(force: true),
                  icon: const Icon(Icons.refresh, size: 15),
                  label: Text(
                    _coordinator.isRefreshingCatalogue
                        ? 'REFRESHING...'
                        : 'REFRESH CATALOGUE',
                    style: const TextStyle(fontSize: 11),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            TextField(
              key: const ValueKey('market_search_field'),
              onChanged: _coordinator.setMarketSearchQuery,
              style: const TextStyle(fontSize: 12),
              decoration: const InputDecoration(
                isDense: true,
                prefixIcon: Icon(Icons.search, size: 18),
                hintText: 'Search symbol, pair, base or quote currency...',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                FilterChip(
                  key: const ValueKey('favourites_filter_chip'),
                  label: const Text(
                    '★ Favourites',
                    style: TextStyle(fontSize: 11),
                  ),
                  selected: _coordinator.showOnlyFavouriteMarkets,
                  onSelected: _coordinator.setShowOnlyFavouriteMarkets,
                ),
                ...quoteOptions.map((q) {
                  final selected =
                      _coordinator.selectedQuoteCurrencyFilter == q;
                  return ChoiceChip(
                    key: ValueKey('quote_filter_$q'),
                    label: Text(q, style: const TextStyle(fontSize: 11)),
                    selected: selected,
                    onSelected: (_) => _coordinator.setQuoteCurrencyFilter(q),
                  );
                }),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDiscoveredMarketCatalogueListCard() {
    final filtered = _coordinator.filteredDiscoveredMarkets;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'DISCOVERED MARKETS (${filtered.length} SHOWN • TAP FOR CHART)',
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
            ),
            const SizedBox(height: 8),
            if (filtered.isEmpty)
              const Text(
                'No discovered markets match the current search/quote filter.',
                style: TextStyle(fontSize: 12, color: Colors.white60),
              )
            else
              ...filtered.take(60).map((m) {
                final t = m.latestTicker;
                final lastPx = t != null
                    ? t.lastPrice.toStringAsFixed(m.pricePrecision.clamp(2, 8))
                    : '--';
                final spreadStr = t != null
                    ? '${t.spreadBps.toStringAsFixed(1)} bps (${t.spreadPct.toStringAsFixed(3)}%)'
                    : '--';
                final volStr =
                    t != null ? t.volume24h.toStringAsFixed(2) : '--';
                final eligColor = m.isEligibleForPaperTrading
                    ? _greenProfit
                    : (m.isActiveStatus ? _orangeWarn : _redLoss);
                final favKey = m.pair.isNotEmpty ? m.pair : m.symbol;
                final isFav =
                    _coordinator.favouriteMarketPairs.contains(favKey);

                return InkWell(
                  onTap: () => _showMarketDetailBottomSheet(m),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Flexible(
                              child: Row(
                                children: [
                                  InkWell(
                                    onTap: () =>
                                        _coordinator.toggleFavouriteMarket(
                                          favKey,
                                        ),
                                    child: Icon(
                                      isFav ? Icons.star : Icons.star_border,
                                      size: 16,
                                      color: isFav
                                          ? Colors.amberAccent
                                          : _mutedSlate,
                                    ),
                                  ),
                                  const SizedBox(width: 6),
                                  Flexible(
                                    child: Text(
                                      '${m.symbol} (${m.pair.isNotEmpty ? m.pair : "NO_PAIR"}) • Quote: ${m.baseCurrencyShortName.isNotEmpty ? m.baseCurrencyShortName : "--"}${m.isNewlyListed ? " [NEW]" : ""}',
                                      style: const TextStyle(
                                        fontWeight: FontWeight.bold,
                                        fontSize: 12,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            Text(
                              m.status.toUpperCase(),
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.bold,
                                color:
                                    m.isActiveStatus ? _greenProfit : _redLoss,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 2),
                        Text(
                          'Last: $lastPx ${m.baseCurrencyShortName} | Spread: $spreadStr | 24h Vol: $volStr | MinQty: ${m.minQuantity} | MinNotional: ${m.minNotional}',
                          style: const TextStyle(
                            fontSize: 11,
                            color: Colors.white70,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          'Eligibility: ${m.eligibilityStatus.name} — ${m.eligibilityReason}',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: eligColor,
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              }),
          ],
        ),
      ),
    );
  }

  Widget _buildMarketScannerCard() {
    final ranks = _coordinator.scannerRankings;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'STAGE 33 — COINDCX SPOT LIQUIDITY & SPREAD SCANNER',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
            ),
            const SizedBox(height: 8),
            if (ranks.isEmpty)
              const Text(
                'Scanner awaiting live ticker snapshot...',
                style: TextStyle(fontSize: 12, color: Colors.white60),
              )
            else
              ...ranks.map((r) => Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Text(
                      '${r.symbol}: ${r.filterReason}',
                      style: TextStyle(
                        fontSize: 11,
                        color: r.isEligible ? _greenProfit : _orangeWarn,
                      ),
                    ),
                  )),
          ],
        ),
      ),
    );
  }

  Widget _buildMultiPairPipelineDiagnosticsCard() {
    final sd = _coordinator.scanDiagnostics;
    final cat = _coordinator.marketCatalogue;
    final discCount = cat.totalDiscoveredCount > 0
        ? cat.totalDiscoveredCount
        : sd.totalPairsDiscovered;
    final actCount = cat.activeMarketsCount > 0
        ? cat.activeMarketsCount
        : sd.activePairsCount;
    final eligCount = cat.eligibleMarketsCount > 0
        ? cat.eligibleMarketsCount
        : sd.eligiblePairsCount;
    final rejCount = cat.rejectedMarketsCount > 0
        ? cat.rejectedMarketsCount
        : sd.rejectedPairsCount;
    final catRefMs = cat.lastSuccessfulRefreshMs ?? sd.lastCatalogueRefreshMs;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'PART 7 — MULTI-PAIR PIPELINE, SIGNAL & RECOVERY DIAGNOSTICS',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
            ),
            const SizedBox(height: 8),
            _diagRow(
              'Market Discovery (Total / Active / Eligible / Rejected)',
              '$discCount / $actCount / $eligCount / $rejCount',
              eligCount > 0 ? _greenProfit : _orangeWarn,
            ),
            _diagRow(
              'Last Catalogue Refresh',
              catRefMs != null
                  ? TradingCoordinator.formatUtcHhMmSs(catRefMs)
                  : 'Never',
              Colors.white70,
            ),
            _diagRow(
              'Last Cycle / Last Successful Scan',
              '${sd.lastCycleTimestampMs != null ? TradingCoordinator.formatUtcHhMmSs(sd.lastCycleTimestampMs!) : "--"} / ${sd.lastSuccessfulScanMs != null ? TradingCoordinator.formatUtcHhMmSs(sd.lastSuccessfulScanMs!) : "--"}',
              Colors.white70,
            ),
            _diagRow(
              'Pairs Evaluated / Pairs Skipped',
              '${sd.totalPairsEvaluated} evaluated / ${sd.pairsSkippedCount} skipped',
              sd.totalPairsEvaluated > 0 ? _greenProfit : _orangeWarn,
            ),
            _diagRow(
              'Signals (Total / BUY / SELL / Rejected)',
              '${sd.signalsGeneratedCount} total (${sd.buySignalsCount} BUY, ${sd.sellSignalsCount} SELL, ${sd.rejectedSignalsCount} rejected)',
              Colors.white70,
            ),
            _diagRow(
              'Paper Orders (Submitted / Accepted / Rejected)',
              '${sd.paperOrdersSubmittedCount} / ${sd.acceptedOrdersCount} / ${sd.rejectedOrdersCount}',
              Colors.white70,
            ),
            _diagRow(
              'Positions (Open / Closed Trades)',
              '${_coordinator.openPositions.length} open / ${_coordinator.closedTrades.length} closed',
              Colors.white70,
            ),
            _diagRow(
              'Connectivity (Internet / CoinDCX REST / Stream)',
              '${_coordinator.internetConnected ? "ONLINE" : "OFFLINE"} | ${sd.coindcxRestStatus} | ${sd.webSocketStatus}',
              _coordinator.internetConnected ? _greenProfit : _redLoss,
            ),
            _diagRow(
              'Recovery State & Retry Count',
              '${_coordinator.engineState.dashboardLabel} (Retries: ${_coordinator.recoveryAttemptCount})',
              _coordinator.recoveryAttemptCount == 0
                  ? _greenProfit
                  : _orangeWarn,
            ),
            if (sd.signalRejectionReasons.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(
                'Signal Rejections: ${sd.signalRejectionReasons.entries.take(5).map((e) => "${e.key}: ${e.value}").join(" | ")}',
                style: const TextStyle(fontSize: 11, color: Colors.white60),
              ),
            ],
            if (sd.skippedPairsReasons.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                'Skipped Pairs (Top 5): ${sd.skippedPairsReasons.entries.take(5).map((e) => "${e.key}: ${e.value}").join(" | ")}',
                style: const TextStyle(fontSize: 11, color: Colors.white54),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _diagRow(String label, String value, Color valueColor) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Flexible(
            child: Text(
              label,
              style: const TextStyle(fontSize: 12, color: Colors.white60),
            ),
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
    final points = _coordinator.filteredEquityCurve;
    const timeframes = ['1D', '7D', '30D', 'ALL'];

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
                  'EQUITY CURVE',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                ),
                Row(
                  children: timeframes.map((tf) {
                    final selected =
                        _coordinator.selectedEquityTimeframe == tf;
                    return Padding(
                      padding: const EdgeInsets.only(left: 4),
                      child: InkWell(
                        onTap: () =>
                            _coordinator.setSelectedEquityTimeframe(tf),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 3,
                          ),
                          decoration: BoxDecoration(
                            color: selected
                                ? const Color(0xFF00C853)
                                : const Color(0xFF182234),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            tf,
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.bold,
                              color: selected ? Colors.black : Colors.white70,
                            ),
                          ),
                        ),
                      ),
                    );
                  }).toList(),
                ),
              ],
            ),
            const SizedBox(height: 10),
            SizedBox(
              height: 110,
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
    final engineRunning = _coordinator.engineState == BotEngineState.running;
    final feedFresh =
        _coordinator.marketDataStatus == MarketDataStatus.healthy &&
        _coordinator.internetConnected;
    final sd = _coordinator.scanDiagnostics;
    final cat = _coordinator.marketCatalogue;
    final discCount = cat.totalDiscoveredCount > 0
        ? cat.totalDiscoveredCount
        : sd.totalPairsDiscovered;
    final eligCount = cat.eligibleMarketsCount > 0
        ? cat.eligibleMarketsCount
        : sd.eligiblePairsCount;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Row(
                  children: [
                    Icon(Icons.monitor_heart_outlined,
                        color: _greenProfit, size: 16),
                    SizedBox(width: 6),
                    Text(
                      'SYSTEM HEALTH',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                      ),
                    ),
                  ],
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: _coordinator.internetConnected
                        ? _greenProfit.withOpacity(0.18)
                        : _redLoss.withOpacity(0.18),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    _coordinator.internetConnected
                        ? 'NET ONLINE'
                        : 'NET OFFLINE',
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                      color: _coordinator.internetConnected
                          ? _greenProfit
                          : _redLoss,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            _diagRow(
              'Bot Engine',
              _coordinator.engineState.dashboardLabel,
              engineRunning ? _greenProfit : _orangeWarn,
            ),
            _diagRow(
              'Market Feed',
              feedFresh ? 'Connected (Fresh)' : 'Waiting / Stale',
              feedFresh ? _greenProfit : _orangeWarn,
            ),
            _diagRow(
              'VPS / Server',
              'Local Android Mode (VPS Not Configured)',
              _mutedSlate,
            ),
            _diagRow(
              'Last Successful Scan',
              sd.lastSuccessfulScanMs != null
                  ? TradingCoordinator.formatUtcHhMmSs(sd.lastSuccessfulScanMs!)
                  : 'Never',
              sd.lastSuccessfulScanMs != null ? _greenProfit : _mutedSlate,
            ),
            _diagRow(
              'Discovered / Eligible Markets',
              '$discCount discovered / $eligCount eligible',
              eligCount > 0 ? _greenProfit : _mutedSlate,
            ),
            const SizedBox(height: 4),
            Text(
              _coordinator.formatHeartbeatStatus(),
              key: const ValueKey('heartbeat_status_text'),
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: hbColor,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _statusChip(BotEngineState state) {
    Color bg;
    Color dotColor;
    final String label = state.dashboardLabel;
    switch (state) {
      case BotEngineState.running:
        bg = const Color(0xFF0D2E1E);
        dotColor = _greenProfit;
        break;
      case BotEngineState.pausedNetworkLoss:
      case BotEngineState.reconnecting:
      case BotEngineState.waitingForFreshData:
      case BotEngineState.pausedStaleData:
      case BotEngineState.pausedAfterRecoveryManualStartRequired:
        bg = _orangeWarn.withOpacity(0.2);
        dotColor = _orangeWarn;
        break;
      case BotEngineState.recoveryFailed:
      case BotEngineState.lockedDailyLossLimit:
      case BotEngineState.stoppedMaxDrawdownReached:
        bg = _redLoss.withOpacity(0.25);
        dotColor = _redLoss;
        break;
      case BotEngineState.stopped:
        bg = Colors.blueGrey.withOpacity(0.28);
        dotColor = _mutedSlate;
        break;
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(shape: BoxShape.circle, color: dotColor),
          ),
          const SizedBox(width: 6),
          Text(
            label,
            style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold),
          ),
        ],
      ),
    );
  }

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
              onPressed: _confirmAndStopBot,
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

    if (intention == UserSessionIntention.paused ||
        _coordinator.engineState.isNetworkOrStalePause) {
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
              onPressed: _confirmAndStopBot,
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
              onPressed: _confirmAndStopBot,
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
                  'COINDCX SPOT BENCHMARK FEEDS (4s POLL)',
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

  Widget _buildOpenPositionsCard({bool showHeaderLinkToTrades = false}) {
    final positions = _coordinator.openPositions;
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final stratName = _coordinator.strategyRegistry.activeStrategy.name;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'OPEN POSITIONS (${positions.length}/1)',
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 12,
                    color: Colors.white,
                  ),
                ),
                if (showHeaderLinkToTrades)
                  InkWell(
                    onTap: () => setState(() {
                      _selectedTabIndex = 2;
                      _tradesSubTabIndex = 1;
                    }),
                    child: const Text(
                      'History >',
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.lightBlueAccent,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
              ],
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
                final upnlPct = pos.investedNotionalUsdt > 0
                    ? (upnl / pos.investedNotionalUsdt) * 100.0
                    : 0.0;
                final durStr = _formatDurationMs(nowMs - pos.openedAtMs);
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Row(
                            children: [
                              Text(
                                pos.symbol,
                                style: const TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 13,
                                ),
                              ),
                              const SizedBox(width: 6),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 6,
                                  vertical: 2,
                                ),
                                decoration: BoxDecoration(
                                  color: const Color(0xFF0D2E1E),
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: const Text(
                                  'Long',
                                  style: TextStyle(
                                    fontSize: 10,
                                    fontWeight: FontWeight.bold,
                                    color: _greenProfit,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          Text(
                            '${upnl >= 0 ? "+" : ""}\$${upnl.toStringAsFixed(2)} (${upnlPct >= 0 ? "+" : ""}${upnlPct.toStringAsFixed(2)}%)',
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 13,
                              color: upnl >= 0 ? _greenProfit : _redLoss,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 3),
                      Text(
                        'Qty: ${pos.quantity.toStringAsFixed(5)} | Entry: \$${pos.entryPrice.toStringAsFixed(2)} | Current: \$${mark.toStringAsFixed(2)} | SL: \$${pos.stopLoss.toStringAsFixed(2)} | TP: \$${pos.takeProfit.toStringAsFixed(2)}',
                        style: const TextStyle(
                          fontSize: 11,
                          color: Colors.white70,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'Duration: $durStr • Strategy: $stratName',
                        style: const TextStyle(fontSize: 10, color: _mutedSlate),
                      ),
                    ],
                  ),
                );
              }),
          ],
        ),
      ),
    );
  }

  Widget _buildRecentTradesCard() {
    final trades = _coordinator.filteredClosedTrades;
    final stratName = _coordinator.strategyRegistry.activeStrategy.name;
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
              ...trades.take(25).map((t) {
                final win = t.realizedPnlUsdt >= 0;
                final durStr = _formatDurationMs(t.closedAtMs - t.openedAtMs);
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            '${t.symbol} (${t.exitReason})',
                            style: const TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 12,
                            ),
                          ),
                          Text(
                            '${win ? "+" : ""}\$${t.realizedPnlUsdt.toStringAsFixed(2)}',
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              color: win ? _greenProfit : _redLoss,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'Entry \$${t.entryPrice.toStringAsFixed(2)} → Exit \$${t.exitPrice.toStringAsFixed(2)} | Qty: ${t.quantity.toStringAsFixed(5)} | Fees: \$${t.totalFeesUsdt.toStringAsFixed(3)}',
                        style: const TextStyle(
                          fontSize: 11,
                          color: Colors.white70,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'Opened: ${TradingCoordinator.formatUtcHhMmSs(t.openedAtMs)} → Closed: ${TradingCoordinator.formatUtcHhMmSs(t.closedAtMs)} ($durStr) • Strategy: $stratName • Entry: 15m EMA20/50 Cross + 1h Bull',
                        style: const TextStyle(fontSize: 10, color: _mutedSlate),
                      ),
                    ],
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
          '4. Trade Alert Notifications',
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
    final regime = _coordinator.latestRegimeAssessment;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'STAGE 30–32 — BACKTEST, ROBUSTNESS & REGIME ENGINE',
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
            if (regime != null) ...[
              const SizedBox(height: 8),
              Text(
                'Detected Regime: ${regime.regimeLabel} (Confidence ${(regime.confidence * 100).toStringAsFixed(0)}%)',
                style: const TextStyle(fontSize: 11, color: Colors.white70),
              ),
            ],
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
      padding: const EdgeInsets.all(9),
      decoration: BoxDecoration(
        color: _surfaceSubtle,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 10, color: _mutedSlate),
          ),
          const SizedBox(height: 4),
          Text(
            value,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontWeight: FontWeight.bold,
              fontSize: 12,
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

    final gridPaint = Paint()
      ..color = const Color(0xFF1E293B)
      ..strokeWidth = 0.8;
    for (int g = 1; g <= 3; g++) {
      final gy = (size.height / 4) * g;
      canvas.drawLine(Offset(0, gy), Offset(size.width, gy), gridPaint);
    }

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
    final fillPath = Path();
    for (int i = 0; i < values.length; i++) {
      final x = values.length == 1
          ? size.width / 2
          : (i / (values.length - 1)) * size.width;
      final normY = (values[i] - minVal) / range;
      final y = size.height - (normY * (size.height - 14)) - 7;
      if (i == 0) {
        path.moveTo(x, y);
        fillPath.moveTo(x, size.height);
        fillPath.lineTo(x, y);
      } else {
        path.lineTo(x, y);
        fillPath.lineTo(x, y);
      }
      if (i == values.length - 1 && values.length > 1) {
        fillPath.lineTo(x, size.height);
        fillPath.close();
      }
    }

    if (values.length == 1) {
      canvas.drawLine(
        Offset(0, size.height / 2),
        Offset(size.width, size.height / 2),
        paint,
      );
    } else {
      final fillPaint = Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            lineColor.withOpacity(0.26),
            lineColor.withOpacity(0.01),
          ],
        ).createShader(Rect.fromLTWH(0, 0, size.width, size.height))
        ..style = PaintingStyle.fill;
      canvas.drawPath(fillPath, fillPaint);
      canvas.drawPath(path, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _EquityCurvePainter oldDelegate) =>
      oldDelegate.points != points;
}

class _DrawdownChartPainter extends CustomPainter {
  final List<EquityPoint> points;

  const _DrawdownChartPainter({required this.points});

  @override
  void paint(Canvas canvas, Size size) {
    if (points.isEmpty) return;
    double peak = 100.0;
    final dds = <double>[];
    for (final p in points) {
      if (p.equityUsdt > peak) peak = p.equityUsdt;
      dds.add((peak - p.equityUsdt).clamp(0.0, 10.0));
    }

    final paint = Paint()
      ..color = const Color(0xFFFF9100)
      ..strokeWidth = 2.0
      ..style = PaintingStyle.stroke;

    final path = Path();
    for (int i = 0; i < dds.length; i++) {
      final x = dds.length == 1
          ? size.width / 2
          : (i / (dds.length - 1)) * size.width;
      final normY = (dds[i] / 10.0).clamp(0.0, 1.0);
      final y = 6 + (normY * (size.height - 12));
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    if (dds.length == 1) {
      canvas.drawLine(const Offset(0, 6), Offset(size.width, 6), paint);
    } else {
      canvas.drawPath(path, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _DrawdownChartPainter oldDelegate) =>
      oldDelegate.points != points;
}

class _CandlestickChartPainter extends CustomPainter {
  final List<Candle> candles;

  const _CandlestickChartPainter({required this.candles});

  @override
  void paint(Canvas canvas, Size size) {
    if (candles.isEmpty) return;
    final visible = candles.length > 40
        ? candles.sublist(candles.length - 40)
        : candles;
    final minLow = visible.map((c) => c.low).reduce(math.min);
    final maxHigh = visible.map((c) => c.high).reduce(math.max);
    final range = (maxHigh - minLow).abs() < 1e-8 ? 1.0 : (maxHigh - minLow);

    final slotWidth = size.width / visible.length;
    final bodyWidth = (slotWidth * 0.65).clamp(2.0, 10.0);

    for (int i = 0; i < visible.length; i++) {
      final c = visible[i];
      final bull = c.close >= c.open;
      final color =
          bull ? const Color(0xFF00E676) : const Color(0xFFFF5252);
      final cx = (i + 0.5) * slotWidth;

      double toY(double px) {
        final norm = (px - minLow) / range;
        return size.height - (norm * (size.height - 12)) - 6;
      }

      final highY = toY(c.high);
      final lowY = toY(c.low);
      final openY = toY(c.open);
      final closeY = toY(c.close);

      final wickPaint = Paint()
        ..color = color
        ..strokeWidth = 1.1;
      canvas.drawLine(Offset(cx, highY), Offset(cx, lowY), wickPaint);

      final top = math.min(openY, closeY);
      final bottom = math.max(openY, closeY);
      final rect = Rect.fromLTRB(
        cx - bodyWidth / 2,
        top,
        cx + bodyWidth / 2,
        math.max(bottom, top + 1.5),
      );
      canvas.drawRect(rect, Paint()..color = color);
    }
  }

  @override
  bool shouldRepaint(covariant _CandlestickChartPainter oldDelegate) =>
      oldDelegate.candles != candles;
}

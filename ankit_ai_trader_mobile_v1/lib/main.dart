import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'models/dual_portfolio_models.dart';
import 'models/trading_models.dart';
import 'screens/dashboard_screen.dart';
import 'services/authoritative_engine.dart';
import 'services/autonomous_intelligence_and_ops.dart';
import 'services/coindcx_market_service.dart';
import 'services/dual_portfolio_service.dart';
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
        if (posted == true) {
          await persistence.markAlertIdNotified(alert.alertId);
        }
      } catch (_) {}
    },
  );

  channel.setMethodCallHandler((MethodCall call) async {
    switch (call.method) {
      case 'handleCommand':
        final cmd =
            (call.arguments as Map?)?['command']?.toString().toUpperCase() ?? '';
        if (cmd == 'START') {
          return await engine.startEngine();
        } else if (cmd == 'PAUSE') {
          await engine.pauseEngine();
          return true;
        } else if (cmd == 'STOP') {
          await engine.stopEngine();
          return true;
        } else if (cmd == 'RESET') {
          await engine.resetAccountTo100();
          return true;
        }
        return false;
      case 'executeCycle':
        await engine.executeTradingCycle(
          allowTradingExecution: true,
        );
        return true;
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
  int _tradesSubTabIndex = 0;

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
                    'Dual-Portfolio Multi-Pair Trading Terminal',
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
      body: Column(
        children: [
          _buildPortfolioSelectorBar(),
          Expanded(
            child: RefreshIndicator(
              onRefresh: () =>
                  _coordinator.refreshStateFromDatabase(isInitialLoad: false),
              child: pages[_selectedTabIndex],
            ),
          ),
        ],
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

  Widget _buildPortfolioSelectorBar() {
    final isCrypto = _coordinator.selectedPortfolioId == PortfolioId.crypto;
    final activeSnap = _coordinator.activePortfolio;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: const BoxDecoration(
        color: Color(0xFF0E1422),
        border: Border(
          bottom: BorderSide(color: Color(0xFF1E293B), width: 1),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: InkWell(
                  key: const ValueKey('select_crypto_portfolio'),
                  onTap: () => _coordinator.selectPortfolio(PortfolioId.crypto),
                  borderRadius: BorderRadius.circular(8),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 7,
                    ),
                    decoration: BoxDecoration(
                      color: isCrypto
                          ? const Color(0xFF0D2E1E)
                          : const Color(0xFF161F30),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: isCrypto
                            ? _greenProfit
                            : const Color(0xFF283B5B),
                      ),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Flexible(
                          child: Text(
                            'CRYPTO PORTFOLIO',
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.bold,
                              color: Colors.white,
                            ),
                          ),
                        ),
                        Text(
                          '\$${_coordinator.cryptoPortfolio.accountEquityUsdt.toStringAsFixed(2)}',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                            color: isCrypto ? _greenProfit : Colors.white70,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: InkWell(
                  key: const ValueKey('select_high_vol_portfolio'),
                  onTap: () =>
                      _coordinator.selectPortfolio(PortfolioId.highVolatility),
                  borderRadius: BorderRadius.circular(8),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 7,
                    ),
                    decoration: BoxDecoration(
                      color: !isCrypto
                          ? const Color(0xFF2B2110)
                          : const Color(0xFF161F30),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: !isCrypto
                            ? _orangeWarn
                            : const Color(0xFF283B5B),
                      ),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Flexible(
                          child: Text(
                            'HIGH-VOLATILITY PORTFOLIO',
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.bold,
                              color: Colors.white,
                            ),
                          ),
                        ),
                        Text(
                          '\$${_coordinator.highVolatilityPortfolio.accountEquityUsdt.toStringAsFixed(2)}',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                            color: !isCrypto ? _orangeWarn : Colors.white70,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
          if (activeSnap.isResearchOnlyMode) ...[
            const SizedBox(height: 6),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                color: const Color(0xFF2B1D0E),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: _orangeWarn.withOpacity(0.5)),
              ),
              child: const Text(
                'RESEARCH-ONLY MODE: High-Volatility & Precious Metals (XAUUSD / XAGUSD) execution is disabled until provider & specifications are verified.',
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                  color: Colors.amberAccent,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildHomeTab() {
    final dailyPnl = _coordinator.activeDailyPnlUsdt;
    final startDayEq = _coordinator.activeStartOfDayEquityUsdt;
    final dailyPct = startDayEq > 0
        ? (dailyPnl / startDayEq) * 100.0
        : 0.0;
    final overallPnl = _coordinator.activeOverallPnlUsdt;
    final overallPct = overallPnl;
    final dd = _coordinator.activeDrawdownUsdt;

    final closed = _coordinator.activeClosedTrades;
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
                            '\$${_coordinator.activeEquityUsdt.toStringAsFixed(2)}',
                            style: const TextStyle(
                              fontSize: 24,
                              fontWeight: FontWeight.bold,
                              color: Colors.white,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'Balance: \$${_coordinator.activePortfolio.startingBalanceUsdt.toStringAsFixed(2)}  |  Available: \$${_coordinator.activeAvailableCashUsdt.toStringAsFixed(2)}',
                            style: const TextStyle(
                              fontSize: 11,
                              color: Colors.white70,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            'Used Margin: \$${_coordinator.activeUsedMarginUsdt.toStringAsFixed(2)}  |  Free Margin: \$${_coordinator.activeFreeMarginUsdt.toStringAsFixed(2)}  |  ${_coordinator.activePortfolio.displayName}',
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
        _buildEquityCurveCard(),
        const SizedBox(height: 10),
        _buildHomeMarketOverviewCard(),
        const SizedBox(height: 10),
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
                  fontSize: 12,
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
    final markets = _coordinator.marketCatalogue.allMarkets.take(4).toList();
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
                  'MARKET OVERVIEW',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    color: _mutedSlate,
                  ),
                ),
                InkWell(
                  onTap: () => setState(() => _selectedTabIndex = 1),
                  child: const Text(
                    'See All >',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: _greenProfit,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            if (markets.isEmpty)
              const Text(
                'Discovering active CoinDCX Spot pairs...',
                style: TextStyle(fontSize: 12, color: Colors.white60),
              )
            else
              ...markets.map((m) {
                final t = m.latestTicker;
                final chg = t?.change24hPct ?? 0.0;
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        '${m.symbol} (${m.quoteCurrency})',
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      Text(
                        t != null
                            ? '${t.lastPrice.toStringAsFixed(m.pricePrecision.clamp(2, 6))} (${chg >= 0 ? "+" : ""}${chg.toStringAsFixed(2)}%)'
                            : m.status,
                        style: TextStyle(
                          fontSize: 12,
                          color: chg >= 0 ? _greenProfit : _redLoss,
                        ),
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

  Widget _buildRiskInformationDisplayCard() {
    final openRisk = _coordinator.isHighVolatilitySelected
        ? 0.0
        : _coordinator.currentOpenPositionRiskUsdt;
    final remDaily = _coordinator.activeRemainingDailyRiskUsdt;
    final remDd = _coordinator.activeRemainingDrawdownUsdt;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'RISK SUPERVISOR & PORTFOLIO LIMITS',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
            ),
            const SizedBox(height: 8),
            _diagRow(
              'Risk Per Trade',
              '\$1.00 USDT (1.0% of \$100.00)',
              Colors.white,
            ),
            _diagRow(
              'Daily Loss Limit / Remaining',
              '\$2.00 max / \$${remDaily.toStringAsFixed(2)} remaining',
              remDaily > 0.5 ? _greenProfit : _orangeWarn,
            ),
            _diagRow(
              'Account Drawdown Limit / Remaining',
              '\$10.00 max (\$90.00 floor) / \$${remDd.toStringAsFixed(2)} remaining',
              remDd > 3.0 ? _greenProfit : _orangeWarn,
            ),
            _diagRow(
              'Configured Max Open Positions (Capacity <= 5)',
              '${_coordinator.activeOpenPositions.length} / ${_coordinator.activePortfolio.configuredMaxOpenPositions} (Arch Max: ${_coordinator.activePortfolio.architecturalMaxPositionCapacity})',
              Colors.white,
            ),
            _diagRow(
              'Portfolio Execution Mode',
              _coordinator.activePortfolio.isResearchOnlyMode
                  ? 'RESEARCH-ONLY (Execution Disabled)'
                  : 'PAPER TRADING ACTIVE (Live Locked)',
              _coordinator.activePortfolio.isResearchOnlyMode
                  ? _orangeWarn
                  : _greenProfit,
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

  Widget _buildHighVolatilityAndMetalsCard() {
    final classifications = _coordinator.highVolatilityMarketClassifications;
    const criteria = HighVolatilityClassificationCriteria();
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'HIGH-VOLATILITY & PRECIOUS METALS WATCHLIST (RESEARCH-ONLY)',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
            ),
            const SizedBox(height: 4),
            Text(
              'Classification Criteria: ATR(14) ${criteria.minAtrPct.toStringAsFixed(2)}%–${criteria.maxAtrPct.toStringAsFixed(2)}% | Realized Vol >= ${criteria.minRealizedVolatilityPct.toStringAsFixed(2)}% | Spread <= ${criteria.maxSpreadBps.toStringAsFixed(0)} bps | Min ${criteria.minClosedCandlesRequired} Closed Candles',
              style: const TextStyle(fontSize: 10, color: _mutedSlate),
            ),
            const SizedBox(height: 8),
            ...classifications.take(6).map((c) {
              final isMetal =
                  c.category == PortfolioAssetCategory.preciousMetalSpotCfd;
              return Container(
                margin: const EdgeInsets.only(bottom: 6),
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: _surfaceSubtle,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          isMetal
                              ? '${c.symbol} (Precious Metal)'
                              : '${c.symbol} (${c.pair})',
                          style: const TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 12,
                          ),
                        ),
                        Text(
                          c.isExecutionAuthorized
                              ? 'PAPER ELIGIBLE'
                              : 'RESEARCH-ONLY',
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                            color: c.isExecutionAuthorized
                                ? _greenProfit
                                : _orangeWarn,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      c.classificationReason,
                      style: const TextStyle(fontSize: 10, color: Colors.white70),
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

  Widget _buildMarketsTab() {
    const quoteOptions = ['ALL', 'USDT', 'INR', 'BTC', 'ETH', 'OTHER'];
    final cat = _coordinator.marketCatalogue;
    final filtered = _coordinator.filteredDiscoveredMarkets;

    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        if (_coordinator.isHighVolatilitySelected) ...[
          _buildHighVolatilityAndMetalsCard(),
          const SizedBox(height: 12),
        ],
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
                      'COINDCX SPOT MARKET CATALOGUE',
                      style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                    ),
                    IconButton(
                      icon: const Icon(Icons.refresh, size: 18),
                      onPressed: () =>
                          _coordinator.refreshMarketCatalogue(force: true),
                    ),
                  ],
                ),
                Text(
                  'Discovered: ${cat.totalDiscoveredCount} | Active: ${cat.activeMarketsCount} | Eligible: ${cat.eligibleMarketsCount}',
                  style: const TextStyle(fontSize: 11, color: Colors.white70),
                ),
                const SizedBox(height: 8),
                TextField(
                  onChanged: _coordinator.setMarketSearchQuery,
                  decoration: InputDecoration(
                    hintText: 'Search pair or symbol (e.g. BTC, INR, SOL)...',
                    prefixIcon: const Icon(Icons.search, size: 18),
                    isDense: true,
                    filled: true,
                    fillColor: _surfaceSubtle,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: BorderSide.none,
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    FilterChip(
                      label: const Text('★ Favs', style: TextStyle(fontSize: 11)),
                      selected: _coordinator.showOnlyFavouriteMarkets,
                      onSelected: _coordinator.setShowOnlyFavouriteMarkets,
                    ),
                    ...quoteOptions.map((q) {
                      final sel =
                          _coordinator.selectedQuoteCurrencyFilter == q;
                      return ChoiceChip(
                        label: Text(q, style: const TextStyle(fontSize: 11)),
                        selected: sel,
                        onSelected: (_) =>
                            _coordinator.setQuoteCurrencyFilter(q),
                      );
                    }),
                  ],
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'MATCHING MARKETS (${filtered.length})',
                  style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    color: _mutedSlate,
                  ),
                ),
                const SizedBox(height: 8),
                if (filtered.isEmpty)
                  const Text(
                    'No markets match current filter.',
                    style: TextStyle(fontSize: 12, color: Colors.white60),
                  )
                else
                  ...filtered.take(30).map((m) {
                    final favKey = m.pair.isNotEmpty ? m.pair : m.symbol;
                    final isFav =
                        _coordinator.favouriteMarketPairs.contains(favKey);
                    final t = m.latestTicker;
                    return ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: IconButton(
                        icon: Icon(
                          isFav ? Icons.star : Icons.star_border,
                          color: isFav ? Colors.amberAccent : _mutedSlate,
                          size: 18,
                        ),
                        onPressed: () =>
                            _coordinator.toggleFavouriteMarket(favKey),
                      ),
                      title: Text(
                        '${m.symbol} (${m.pair})',
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 12,
                        ),
                      ),
                      subtitle: Text(
                        '${m.eligibilityStatus.categoryLabel} • ${m.eligibilityReason}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 10),
                      ),
                      trailing: Text(
                        t != null
                            ? '${t.lastPrice.toStringAsFixed(m.pricePrecision.clamp(2, 6))} ${m.quoteCurrency}'
                            : m.status,
                        style: const TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    );
                  }),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildTradesTab() {
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        Row(
          children: [
            Expanded(
              child: ChoiceChip(
                label: Text(
                  'Open Positions (${_coordinator.activeOpenPositions.length})',
                ),
                selected: _tradesSubTabIndex == 0,
                onSelected: (_) => setState(() => _tradesSubTabIndex = 0),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: ChoiceChip(
                label: Text(
                  'Closed Trades (${_coordinator.activeClosedTrades.length})',
                ),
                selected: _tradesSubTabIndex == 1,
                onSelected: (_) => setState(() => _tradesSubTabIndex = 1),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        if (_tradesSubTabIndex == 0)
          _buildOpenPositionsCard()
        else ...[
          _buildClosedTradesFilterBar(),
          const SizedBox(height: 10),
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

  Widget _buildAiLabTab() {
    final activeStrat = _coordinator.strategyRegistry.activeStrategy;
    final learningCtx = _coordinator.activePortfolio.learningContext;
    final costEst = _coordinator.agentOrchestrator.estimateCouncilRunCost();
    final hypotheses =
        SandboxedStrategyBuilderAndOptimizer.generateSandboxedHypotheses();

    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'ENGINE & LEARNING CONTEXT (${learningCtx.portfolioId.displayName})',
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 13,
                  ),
                ),
                const SizedBox(height: 8),
                _diagRow(
                  'Active Strategy',
                  '${activeStrat.name} (${activeStrat.version})',
                  _greenProfit,
                ),
                _diagRow(
                  'Evaluated Portfolio Trades',
                  '${learningCtx.evaluatedClosedTradesCount} (${learningCtx.observedWinningTrades}W / ${learningCtx.observedLosingTrades}L)',
                  Colors.white,
                ),
                _diagRow(
                  'Auto Strategy Transfer Across Portfolios',
                  learningCtx.autoStrategyTransferBlocked
                      ? 'BLOCKED (Isolated)'
                      : 'ALLOWED',
                  _greenProfit,
                ),
                _diagRow(
                  'External Cloud LLM Council',
                  'INACTIVE (${costEst.modeDescription})',
                  Colors.white70,
                ),
                const SizedBox(height: 8),
                ...hypotheses.map(
                  (h) => Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Text(
                      '• ${h.candidateId}: ${h.description}',
                      style: const TextStyle(fontSize: 11, color: Colors.white70),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        _buildBacktestCard(),
      ],
    );
  }

  Widget _buildReportsTab() {
    final pnl24h =
        _coordinator.computeRealizedPnlForWindowMs(24 * 60 * 60 * 1000);
    final pnl7d =
        _coordinator.computeRealizedPnlForWindowMs(7 * 24 * 60 * 60 * 1000);
    final pnl30d =
        _coordinator.computeRealizedPnlForWindowMs(30 * 24 * 60 * 60 * 1000);
    final totalPnl = _coordinator.activeOverallPnlUsdt;
    final durStats = _coordinator.tradeDurationStats;

    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'FINANCIAL PERFORMANCE ANALYTICS',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
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
                  'Trade Duration (Avg / Min / Max)',
                  _coordinator.activeClosedTrades.isNotEmpty
                      ? '${durStats.avgMinutes}m / ${durStats.minMinutes}m / ${durStats.maxMinutes}m'
                      : 'No completed trades yet',
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
                      points: _coordinator.activeEquityCurve.isEmpty
                          ? [
                              EquityPoint(
                                timestampMs: 0,
                                equityUsdt: _coordinator.activeEquityUsdt,
                              )
                            ]
                          : _coordinator.activeEquityCurve,
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

  Widget _buildSettingsTab() {
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'ENGINE CONTROLS (PAPER TRADING ONLY)',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    ElevatedButton.icon(
                      onPressed: _coordinator.startBot,
                      icon: const Icon(Icons.play_arrow, size: 16),
                      label: const Text('START'),
                    ),
                    OutlinedButton.icon(
                      onPressed: _coordinator.pauseBot,
                      icon: const Icon(Icons.pause, size: 16),
                      label: const Text('PAUSE'),
                    ),
                    OutlinedButton.icon(
                      onPressed: _coordinator.stopBot,
                      icon: const Icon(Icons.stop, size: 16),
                      label: const Text('STOP'),
                    ),
                    OutlinedButton.icon(
                      onPressed: _coordinator.manualResetDrawdownAndAccount,
                      icon: const Icon(Icons.refresh, size: 16),
                      label: const Text('RESET \$100'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        OnePlusBatteryOptimizationCard(
          ignoringBatteryOptimizations:
              _coordinator.ignoringBatteryOptimizations,
          notificationPermissionGranted:
              _coordinator.notificationPermissionGranted,
          onOpenSettings: _coordinator.openBatteryOptimizationSettings,
          onOpenNotifications: _coordinator.openNotificationSettings,
        ),
      ],
    );
  }

  Widget _buildEquityCurveCard() {
    final points = _coordinator.filteredEquityCurve;
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
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    color: _mutedSlate,
                  ),
                ),
                Row(
                  children: ['1D', '7D', '30D', 'ALL'].map((tf) {
                    final sel = _coordinator.selectedEquityTimeframe == tf;
                    return Padding(
                      padding: const EdgeInsets.only(left: 4),
                      child: ChoiceChip(
                        label: Text(tf, style: const TextStyle(fontSize: 10)),
                        selected: sel,
                        onSelected: (_) =>
                            _coordinator.setSelectedEquityTimeframe(tf),
                      ),
                    );
                  }).toList(),
                ),
              ],
            ),
            const SizedBox(height: 8),
            SizedBox(
              height: 110,
              width: double.infinity,
              child: CustomPaint(
                painter: _EquityCurvePainter(
                  points: points.isEmpty
                      ? [
                          EquityPoint(
                            timestampMs: 0,
                            equityUsdt: _coordinator.activeEquityUsdt,
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

  Widget _buildOpenPositionsCard({bool showHeaderLinkToTrades = false}) {
    final positions = _coordinator.activeOpenPositions;
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
                  'OPEN POSITIONS (${positions.length})',
                  style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    color: _mutedSlate,
                  ),
                ),
                if (showHeaderLinkToTrades)
                  InkWell(
                    onTap: () => setState(() => _selectedTabIndex = 2),
                    child: const Text(
                      'History >',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: _greenProfit,
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            if (positions.isEmpty)
              const Text(
                'No open positions in selected portfolio.',
                style: TextStyle(fontSize: 12, color: Colors.white60),
              )
            else
              ...positions.map((pos) {
                final mark = _coordinator.liveTickerPrices[pos.symbol] ??
                    _coordinator.closedCandlePrices[pos.symbol] ??
                    pos.entryPrice;
                final upnl = pos.unrealizedPnlUsdt(mark);
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        '${pos.symbol} • Qty ${pos.quantity}',
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 12,
                        ),
                      ),
                      Text(
                        '${upnl >= 0 ? "+" : ""}\$${upnl.toStringAsFixed(2)}',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 12,
                          color: upnl >= 0 ? _greenProfit : _redLoss,
                        ),
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
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'CLOSED TRADES HISTORY (${trades.length})',
              style: const TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.bold,
                color: _mutedSlate,
              ),
            ),
            const SizedBox(height: 8),
            if (trades.isEmpty)
              const Text(
                'No closed paper trades matching filter.',
                style: TextStyle(fontSize: 12, color: Colors.white60),
              )
            else
              ...trades.map((t) {
                final win = t.realizedPnlUsdt >= 0;
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
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
                          fontSize: 12,
                          color: win ? _greenProfit : _redLoss,
                        ),
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

  Widget _buildSystemHealthSummaryCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'SYSTEM & CONNECTIVITY STATUS',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.bold,
                color: _mutedSlate,
              ),
            ),
            const SizedBox(height: 8),
            _diagRow(
              'Runtime State',
              _coordinator.engineState.dashboardLabel,
              _coordinator.engineState == BotEngineState.running
                  ? _greenProfit
                  : Colors.white70,
            ),
            _diagRow(
              'Heartbeat',
              _coordinator.formatHeartbeatStatus(),
              Colors.white70,
            ),
            _diagRow(
              'Execution Mode',
              'Local Android Mode (VPS Not Configured)',
              Colors.white70,
            ),
          ],
        ),
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
            if (regime != null) ...[
              const SizedBox(height: 8),
              Text(
                'Detected Regime: ${regime.regimeLabel} (Confidence ${(regime.confidence * 100).toStringAsFixed(0)}%)',
                style: const TextStyle(fontSize: 11, color: Colors.white70),
              ),
            ],
            if (report != null) ...[
              const SizedBox(height: 8),
              Text(
                'Trades: ${report.totalTrades} | Win Rate: ${report.winRatePct.toStringAsFixed(1)}% | Net PnL: \$${report.netPnlUsdt.toStringAsFixed(2)}',
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

  Widget _diagRow(String label, String value, Color valueColor) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Flexible(
            child: Text(
              label,
              style: const TextStyle(fontSize: 11, color: _mutedSlate),
            ),
          ),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              value,
              textAlign: TextAlign.right,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: valueColor,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _statusChip(BotEngineState state) {
    final isRun = state == BotEngineState.running;
    final color = isRun ? _greenProfit : _orangeWarn;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withOpacity(0.15),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withOpacity(0.5)),
      ),
      child: Text(
        state.dashboardLabel,
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.bold,
          color: color,
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
    final values = points.map((p) => p.equityUsdt).toList();
    final minVal = values.reduce(math.min);
    final maxVal = values.reduce(math.max);
    final range = (maxVal - minVal).abs() < 0.01 ? 1.0 : (maxVal - minVal);
    final isProfit = values.last >= 100.0;
    final lineColor =
        isProfit ? const Color(0xFF00E676) : const Color(0xFFFF5252);

    final paint = Paint()
      ..color = lineColor
      ..strokeWidth = 2.0
      ..style = PaintingStyle.stroke;

    final path = Path();
    for (int i = 0; i < values.length; i++) {
      final x = values.length == 1
          ? size.width / 2
          : (i / (values.length - 1)) * size.width;
      final normY = (values[i] - minVal) / range;
      final y = size.height - (normY * (size.height - 14)) - 7;
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

class _DrawdownChartPainter extends CustomPainter {
  final List<EquityPoint> points;

  const _DrawdownChartPainter({required this.points});

  @override
  void paint(Canvas canvas, Size size) {
    if (points.isEmpty) return;
    final paint = Paint()
      ..color = const Color(0xFFFF9100)
      ..strokeWidth = 2.0
      ..style = PaintingStyle.stroke;
    canvas.drawLine(const Offset(0, 6), Offset(size.width, 6), paint);
  }

  @override
  bool shouldRepaint(covariant _DrawdownChartPainter oldDelegate) =>
      oldDelegate.points != points;
}

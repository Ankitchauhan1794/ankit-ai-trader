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
    await engine.loadPersistedStateIntoMemory();
    await channel.invokeMethod('acknowledgeEngineInitialized');
    if (engine.userIntention == UserSessionIntention.running &&
        engine.state != BotEngineState.starting &&
        !engine.maxDrawdownLocked &&
        engine.lockedDailyLossUtcDate == null) {
      await engine.startEngine();
    }
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

  static double _cleanZero(double val) => val.abs() < 0.005 ? 0.0 : val;

  static String _formatSignedUsdt(double rawValue) {
    final v = _cleanZero(rawValue);
    if (v == 0.0) return '\$0.00';
    return '${v > 0 ? "+" : "-"}\$${v.abs().toStringAsFixed(2)}';
  }

  static String _formatUnsignedUsdt(double rawValue) {
    final v = _cleanZero(rawValue);
    return '\$${v.abs().toStringAsFixed(2)}';
  }

  static String _formatSignedPct(double rawPct) {
    final v = _cleanZero(rawPct);
    if (v == 0.0) return '0.00%';
    return '${v > 0 ? "+" : "-"}${v.abs().toStringAsFixed(2)}%';
  }

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
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const FittedBox(
                          fit: BoxFit.scaleDown,
                          alignment: Alignment.centerLeft,
                          child: Text(
                            'CRYPTO PORTFOLIO',
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.bold,
                              color: Colors.white,
                            ),
                          ),
                        ),
                        const SizedBox(height: 2),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            const Text(
                              'CoinDCX Spot',
                              style: TextStyle(
                                fontSize: 9.5,
                                color: _mutedSlate,
                              ),
                            ),
                            Text(
                              _formatUnsignedUsdt(
                                _coordinator.cryptoPortfolio.accountEquityUsdt,
                              ),
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.bold,
                                color: isCrypto ? _greenProfit : Colors.white70,
                              ),
                            ),
                          ],
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
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const FittedBox(
                          fit: BoxFit.scaleDown,
                          alignment: Alignment.centerLeft,
                          child: Text(
                            'HIGH-VOLATILITY PORTFOLIO',
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.bold,
                              color: Colors.white,
                            ),
                          ),
                        ),
                        const SizedBox(height: 2),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(
                              _coordinator.highVolatilityPortfolio.isResearchOnlyMode
                                  ? 'Research-Only'
                                  : 'Crypto Paper • Metals Research',
                              style: const TextStyle(
                                fontSize: 9.5,
                                color: Colors.amberAccent,
                              ),
                            ),
                            Text(
                              _formatUnsignedUsdt(
                                _coordinator
                                    .highVolatilityPortfolio.accountEquityUsdt,
                              ),
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.bold,
                                color: !isCrypto ? _orangeWarn : Colors.white70,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: const Color(0xFF121A2B),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(
              'Crypto Engine: ${_coordinator.cryptoEngineStatusLabel}  •  High-Vol Research: ${_coordinator.highVolatilityResearchStatusLabel}  •  High-Vol Execution: ${_coordinator.highVolatilityExecutionStatusLabel}',
              style: const TextStyle(
                fontSize: 9.5,
                fontWeight: FontWeight.w600,
                color: Colors.white70,
              ),
            ),
          ),
          if (_coordinator.isHighVolatilitySelected) ...[
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
                'HIGH-VOLATILITY PORTFOLIO: CoinDCX Crypto Spot Paper Trading ACTIVE • Gold (XAUUSD) & Silver (XAGUSD) remain RESEARCH-ONLY until provider & specs are verified.',
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
                            _formatUnsignedUsdt(_coordinator.activeEquityUsdt),
                            style: const TextStyle(
                              fontSize: 24,
                              fontWeight: FontWeight.bold,
                              color: Colors.white,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'Starting: ${_formatUnsignedUsdt(_coordinator.activePortfolio.startingBalanceUsdt)}  |  Settled Balance: ${_formatUnsignedUsdt(_coordinator.activeSettledBalanceUsdt)}',
                            style: const TextStyle(
                              fontSize: 11,
                              color: Colors.white70,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            'Available Cash: ${_formatUnsignedUsdt(_coordinator.activeAvailableCashUsdt)}  |  Reserved (Spot): ${_formatUnsignedUsdt(_coordinator.activeReservedCapitalUsdt)}',
                            style: const TextStyle(
                              fontSize: 10.5,
                              color: Colors.white70,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            'Realised P&L: ${_formatSignedUsdt(_coordinator.activeRealizedPnlUsdt)}  |  Unrealised P&L: ${_formatSignedUsdt(_coordinator.activeUnrealizedPnlUsdt)}  |  Positions: ${_coordinator.activeOpenPositions.length}/${_coordinator.activeMaxOpenPositions}',
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
                              '${_formatSignedUsdt(dailyPnl)} (${_formatSignedPct(dailyPct)})',
                              valueColor: _cleanZero(dailyPnl) >= 0
                                  ? _greenProfit
                                  : _redLoss,
                            ),
                          ),
                          const SizedBox(width: 6),
                          Expanded(
                            child: _metricTile(
                              'Overall P&L',
                              '${_formatSignedUsdt(overallPnl)} (${_formatSignedPct(overallPct)})',
                              valueColor: _cleanZero(overallPnl) >= 0
                                  ? _greenProfit
                                  : _redLoss,
                            ),
                          ),
                          const SizedBox(width: 6),
                          Expanded(
                            child: _metricTile(
                              'Drawdown (Max 15% / \$15)',
                              _formatUnsignedUsdt(dd),
                              valueColor: _cleanZero(dd) >= 5.0
                                  ? _redLoss
                                  : (_cleanZero(dd) > 0
                                      ? _orangeWarn
                                      : _greenProfit),
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
                    _formatSignedUsdt(overallPnl),
                    _cleanZero(overallPnl) >= 0 ? _greenProfit : _redLoss,
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
              'Overall Portfolio Loss Limit (${_coordinator.activeMaxPortfolioLossPct.toStringAsFixed(0)}%)',
              '\$${_coordinator.activeMaxPortfolioLossUsdt.toStringAsFixed(2)} max (\$${_coordinator.activePortfolioLossFloorUsdt.toStringAsFixed(2)} floor) / \$${_coordinator.activeRemainingPortfolioLossBudgetUsdt.toStringAsFixed(2)} remaining',
              _coordinator.activeIsPortfolioLossLocked
                  ? _redLoss
                  : (_coordinator.activeRemainingPortfolioLossBudgetUsdt > 4.0
                      ? _greenProfit
                      : _orangeWarn),
            ),
            _diagRow(
              'Open Positions / Max Capacity',
              '${_coordinator.activeOpenPositions.length} / ${_coordinator.activeMaxOpenPositions} (Max 5 per portfolio)',
              Colors.white,
            ),
            _diagRow(
              'Portfolio Risk Lockout State',
              _coordinator.activeIsPortfolioLossLocked
                  ? 'LOCKED (15% Loss Limit Reached — Reset Required)'
                  : 'UNLOCKED (Healthy)',
              _coordinator.activeIsPortfolioLossLocked ? _redLoss : _greenProfit,
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
                  'Discovered: ${cat.totalDiscoveredCount} | Active: ${cat.activeMarketsCount} | Eligible: ${cat.eligibleMarketsCount} (USDT: ${cat.eligibleUsdtMarketsCount}) | Excluded: ${cat.rejectedMarketsCount}',
                  style: const TextStyle(fontSize: 11, color: Colors.white70),
                ),
                const SizedBox(height: 4),
                Text(
                  _coordinator.showOnlyEligibleMarkets
                      ? 'View Mode: Showing ONLY Eligible Paper-Trading Markets (Verified Liquidity, Spread <= 35 bps & Risk Rules)'
                      : 'View Mode: Showing ALL Discovered Catalogue Markets (Both Eligible & Excluded — toggle "✓ Eligible Only" to filter)',
                  style: TextStyle(
                    fontSize: 10,
                    color: _coordinator.showOnlyEligibleMarkets
                        ? _greenProfit
                        : _mutedSlate,
                  ),
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
                    FilterChip(
                      key: const ValueKey('filter_eligible_only_markets'),
                      label: Text(
                        '✓ Eligible Only (${cat.eligibleMarketsCount})',
                        style: const TextStyle(fontSize: 11),
                      ),
                      selected: _coordinator.showOnlyEligibleMarkets,
                      onSelected: _coordinator.setShowOnlyEligibleMarkets,
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
                      onTap: () => _showMarketDetailBottomSheet(m),
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
    final activeStrat = _coordinator.activePortfolioStrategyDescriptor;
    final availStrats = _coordinator.activePortfolioAvailableStrategies;
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
                  'Active Strategy (${_coordinator.activePortfolio.portfolioId.shortLabel})',
                  '${activeStrat.name} (${activeStrat.version})',
                  _greenProfit,
                ),
                _diagRow(
                  'Strategy Entry Rule',
                  activeStrat.entryRuleSummary,
                  Colors.white70,
                ),
                _diagRow(
                  'Evaluated Portfolio Trades',
                  learningCtx.evaluatedClosedTradesCount > 0
                      ? '${learningCtx.evaluatedClosedTradesCount} (${learningCtx.observedWinningTrades}W / ${learningCtx.observedLosingTrades}L)'
                      : '0 (Performance not yet established)',
                  Colors.white,
                ),
                _diagRow(
                  'Configured Max Open Positions',
                  '${_coordinator.activePortfolio.configuredMaxOpenPositions} (Isolated per portfolio)',
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
                const Text(
                  'PORTFOLIO-ISOLATED STRATEGY SELECTION',
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                    color: _mutedSlate,
                  ),
                ),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: availStrats.map((s) {
                    final selected =
                        _coordinator.activePortfolio.activeStrategyId == s.id;
                    return ChoiceChip(
                      key: ValueKey(
                        'select_strat_${_coordinator.selectedPortfolioId.dbKey}_${s.id}',
                      ),
                      label: Text(
                        s.name,
                        style: const TextStyle(fontSize: 10),
                      ),
                      selected: selected,
                      onSelected: (_) => _coordinator.setPortfolioStrategy(
                        portfolioId: _coordinator.selectedPortfolioId,
                        strategyId: s.id,
                      ),
                    );
                  }).toList(),
                ),
                const SizedBox(height: 10),
                const Text(
                  'SANDBOX STRATEGY CANDIDATES (RESEARCH ONLY — NOT ACTIVE)',
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                    color: _mutedSlate,
                  ),
                ),
                const SizedBox(height: 4),
                ...hypotheses.map(
                  (h) => Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Text(
                      '• ${h.candidateId} [SANDBOX CANDIDATE]: ${h.description}',
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
    final hasCompletedTrades = _coordinator.activeClosedTrades.isNotEmpty;
    final currentDd = _coordinator.activeDrawdownUsdt;
    final remDd = _coordinator.activeRemainingDrawdownUsdt;
    final startBal = _coordinator.activePortfolio.startingBalanceUsdt;
    final ddPct = startBal > 0 ? (_cleanZero(currentDd) / startBal) * 100.0 : 0.0;

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
                if (!hasCompletedTrades) ...[
                  const SizedBox(height: 8),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: _surfaceSubtle,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: const Text(
                      'Performance not yet established.',
                      style: TextStyle(fontSize: 11, color: Colors.white70),
                    ),
                  ),
                ],
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: _metricTile(
                        'Daily (24H)',
                        _formatSignedUsdt(pnl24h),
                        valueColor:
                            _cleanZero(pnl24h) >= 0 ? _greenProfit : _redLoss,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: _metricTile(
                        'Weekly (7D)',
                        _formatSignedUsdt(pnl7d),
                        valueColor:
                            _cleanZero(pnl7d) >= 0 ? _greenProfit : _redLoss,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: _metricTile(
                        'Monthly (30D)',
                        _formatSignedUsdt(pnl30d),
                        valueColor:
                            _cleanZero(pnl30d) >= 0 ? _greenProfit : _redLoss,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: _metricTile(
                        'Total P&L',
                        _formatSignedUsdt(totalPnl),
                        valueColor:
                            _cleanZero(totalPnl) >= 0 ? _greenProfit : _redLoss,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                _diagRow(
                  'Trade Duration (Avg / Min / Max)',
                  hasCompletedTrades
                      ? '${durStats.avgMinutes}m / ${durStats.minMinutes}m / ${durStats.maxMinutes}m'
                      : 'No completed trades yet',
                  Colors.white70,
                ),
                _diagRow(
                  'Realised P&L (Completed Trades)',
                  _formatSignedUsdt(_coordinator.activeRealizedPnlUsdt),
                  _cleanZero(_coordinator.activeRealizedPnlUsdt) >= 0
                      ? _greenProfit
                      : _redLoss,
                ),
                _diagRow(
                  'Unrealised P&L (Open Spot Positions)',
                  _formatSignedUsdt(_coordinator.activeUnrealizedPnlUsdt),
                  _cleanZero(_coordinator.activeUnrealizedPnlUsdt) >= 0
                      ? _greenProfit
                      : _redLoss,
                ),
                _diagRow(
                  'Reserved Spot Capital / Available Cash',
                  '${_formatUnsignedUsdt(_coordinator.activeReservedCapitalUsdt)} reserved / ${_formatUnsignedUsdt(_coordinator.activeAvailableCashUsdt)} cash',
                  Colors.white70,
                ),
                _diagRow(
                  'Actual Paper Trades',
                  hasCompletedTrades
                      ? '${_coordinator.activeClosedTrades.length} completed trade(s)'
                      : 'Performance not yet established.',
                  Colors.white,
                ),
                _diagRow(
                  'Historical Backtest Results',
                  _coordinator.latestBacktestReport != null
                      ? '${_coordinator.latestBacktestReport!.totalTrades} simulated trades (Net ${_formatSignedUsdt(_coordinator.latestBacktestReport!.netPnlUsdt)})'
                      : 'Not run in this session (Separate from paper account)',
                  Colors.white70,
                ),
                _diagRow(
                  'Walk-Forward & Out-of-Sample Data',
                  _coordinator.activeClosedTrades.length >= 5
                      ? (_coordinator.latestRobustnessReport?.summaryReason ??
                          'Evaluated')
                      : 'Unavailable (Requires >= 5 completed paper trades)',
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
                const SizedBox(height: 6),
                _diagRow(
                  'Current Portfolio Drawdown',
                  '${_formatUnsignedUsdt(currentDd)} (${ddPct.toStringAsFixed(2)}%)',
                  _cleanZero(currentDd) > 0 ? _orangeWarn : _greenProfit,
                ),
                _diagRow(
                  'Overall Portfolio Loss Protection (15%)',
                  '\$${_coordinator.activeMaxPortfolioLossUsdt.toStringAsFixed(2)} max (15.0% of \$100.00 • \$${_coordinator.activePortfolioLossFloorUsdt.toStringAsFixed(2)} Floor)',
                  Colors.white,
                ),
                _diagRow(
                  'Remaining 15% Loss Protection Buffer',
                  '${_formatUnsignedUsdt(_coordinator.activeRemainingPortfolioLossBudgetUsdt)} remaining',
                  _coordinator.activeRemainingPortfolioLossBudgetUsdt > 4.0
                      ? _greenProfit
                      : _orangeWarn,
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
                const SizedBox(height: 6),
                Text(
                  'State: ${_coordinator.engineState.startupStateMachineLabel}',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: _coordinator.engineState == BotEngineState.running
                        ? _greenProfit
                        : _orangeWarn,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  _coordinator.statusBannerMessage,
                  style: const TextStyle(fontSize: 11, color: Colors.white70),
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
                      onPressed: _confirmAndStopBot,
                      icon: const Icon(Icons.stop, size: 16),
                      label: const Text('STOP'),
                    ),
                    OutlinedButton.icon(
                      onPressed: _confirmAndResetAccount,
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
        Card(
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'ENGINE STARTUP & RUNTIME DIAGNOSTICS',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                ),
                const SizedBox(height: 8),
                _diagRow(
                  'Current Engine State',
                  _coordinator.engineState.startupStateMachineLabel,
                  _coordinator.engineState == BotEngineState.running
                      ? _greenProfit
                      : _orangeWarn,
                ),
                _diagRow(
                  'Foreground Service State',
                  _coordinator.serviceRunning ? 'RUNNING (Alive)' : 'STOPPED',
                  _coordinator.serviceRunning ? _greenProfit : _orangeWarn,
                ),
                _diagRow(
                  'Background Dart Engine State',
                  _coordinator.dartEngineInitialized
                      ? 'READY (Initialized)'
                      : 'NOT INITIALIZED',
                  _coordinator.dartEngineInitialized
                      ? _greenProfit
                      : _orangeWarn,
                ),
                _diagRow(
                  'Last Heartbeat',
                  _coordinator.formatHeartbeatStatus(),
                  Colors.white70,
                ),
                _diagRow(
                  'Last Successful Trading Cycle',
                  _coordinator.scanDiagnostics.lastSuccessfulScanMs != null
                      ? TradingCoordinator.formatUtcHhMmSs(
                          _coordinator.scanDiagnostics.lastSuccessfulScanMs!,
                        )
                      : 'None recorded',
                  Colors.white70,
                ),
                _diagRow(
                  'Current Portfolio',
                  '${_coordinator.activePortfolio.displayName} (${_coordinator.activePortfolio.isResearchOnlyMode ? "RESEARCH-ONLY" : "PAPER ACTIVE"} • ${_formatUnsignedUsdt(_coordinator.activeEquityUsdt)})',
                  Colors.white,
                ),
                _diagRow(
                  'Network State',
                  _coordinator.internetConnected
                      ? 'CONNECTED (Online)'
                      : 'DISCONNECTED (Offline)',
                  _coordinator.internetConnected ? _greenProfit : _redLoss,
                ),
                _diagRow(
                  'Market-Data Freshness',
                  _coordinator.marketDataFreshnessLabel,
                  _coordinator.marketDataFreshnessLabel.startsWith('FRESH')
                      ? _greenProfit
                      : _orangeWarn,
                ),
                _diagRow(
                  'Last Startup Error',
                  _coordinator.lastStartupError ?? 'None',
                  _coordinator.lastStartupError != null
                      ? _redLoss
                      : _greenProfit,
                ),
                _diagRow(
                  'Last Shutdown Reason',
                  _coordinator.lastShutdownReason ?? 'None',
                  Colors.white70,
                ),
                _diagRow(
                  'Risk-Lockout State',
                  _coordinator.activeIsPortfolioLossLocked
                      ? 'LOCKED — 15% Portfolio Loss Limit Reached (\$${_coordinator.activePortfolioLossFloorUsdt.toStringAsFixed(2)} floor)'
                      : (_coordinator.lockedDailyLossUtcDate != null
                          ? 'LOCKED — Daily Loss Limit (\$2.00) Reached'
                          : 'UNLOCKED (Healthy)'),
                  _coordinator.activeIsPortfolioLossLocked ? _redLoss : _greenProfit,
                ),
                _diagRow(
                  'Open Positions / Maximum Positions',
                  '${_coordinator.activeOpenPositions.length} / ${_coordinator.activeMaxOpenPositions} (Max 5 per portfolio)',
                  Colors.white,
                ),
                const SizedBox(height: 10),
                Text(
                  'MAX SIMULTANEOUS OPEN POSITIONS (${_coordinator.activePortfolio.displayName}): ${_coordinator.activeOpenPositions.length} / ${_coordinator.activeMaxOpenPositions}',
                  style: const TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                    color: _mutedSlate,
                  ),
                ),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 6,
                  children: [1, 2, 3, 4, 5].map((maxPos) {
                    final sel = _coordinator.activeMaxOpenPositions == maxPos;
                    return ChoiceChip(
                      label: Text('$maxPos / 5', style: const TextStyle(fontSize: 10)),
                      selected: sel,
                      onSelected: (_) => _coordinator.updatePortfolioSettings(
                        portfolioId: _coordinator.selectedPortfolioId,
                        configuredMaxOpenPositions: maxPos,
                      ),
                    );
                  }).toList(),
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
                  'OPEN POSITIONS (${positions.length} / ${_coordinator.activeMaxOpenPositions})',
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
                  padding: const EdgeInsets.symmetric(vertical: 5),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
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
                            'Unrealised: ${_formatSignedUsdt(upnl)}',
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 12,
                              color:
                                  _cleanZero(upnl) >= 0 ? _greenProfit : _redLoss,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'Entry: \$${pos.entryPrice.toStringAsFixed(2)} | Mark: \$${mark.toStringAsFixed(2)} | Reserved: \$${pos.investedNotionalUsdt.toStringAsFixed(2)} | Fee: \$${pos.entryFeeUsdt.toStringAsFixed(2)} | SL: \$${pos.stopLoss.toStringAsFixed(2)} | TP: \$${pos.takeProfit.toStringAsFixed(2)}',
                        style: const TextStyle(
                          fontSize: 10,
                          color: Colors.white70,
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
                        builder: (ctx, snap) {
                          if (snap.connectionState == ConnectionState.waiting) {
                            return const Center(
                              child: CircularProgressIndicator(),
                            );
                          }
                          final candles = snap.data ?? const [];
                          if (candles.isEmpty) {
                            return const Center(
                              child: Text(
                                'No closed candles returned for this pair.',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: Colors.white54,
                                ),
                              ),
                            );
                          }
                          return CustomPaint(
                            painter: _CandlestickChartPainter(candles: candles),
                            size: const Size(double.infinity, 160),
                          );
                        },
                      ),
                    ),
                    const SizedBox(height: 12),
                    _diagRow(
                      'Min Quantity / Step',
                      '${market.minQuantity} / ${market.step} ${market.targetCurrencyShortName}',
                      Colors.white70,
                    ),
                    _diagRow(
                      'Min Notional',
                      '${market.minNotional} ${market.baseCurrencyShortName}',
                      Colors.white70,
                    ),
                    _diagRow(
                      'Eligibility Status',
                      '${market.eligibilityStatus.categoryLabel} (${market.eligibilityReason})',
                      market.isEligibleForPaperTrading
                          ? _greenProfit
                          : _orangeWarn,
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

  void _showCsvAccountingExportDialog() {
    final summary = _coordinator.latestTaxAccountingSummary;
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF101622),
        title: const Text('CSV Trade History & Tax Export'),
        content: SingleChildScrollView(
          child: SelectableText(
            summary.csvExportPreview,
            style: const TextStyle(fontSize: 11, fontFamily: 'monospace'),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: summary.csvExportPreview));
              Navigator.of(ctx).pop();
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('CSV copied to clipboard.')),
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

  void _confirmAndStopBot() {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF101622),
        title: const Text('Stop Paper Trading Bot?'),
        content: const Text(
          'This will stop scheduled multi-pair scanning and release the background execution lock. Existing positions and history are preserved.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('CANCEL'),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              _coordinator.stopBot();
            },
            child: const Text('CONFIRM STOP'),
          ),
        ],
      ),
    );
  }

  void _confirmAndResetAccount() {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF101622),
        title: const Text('Reset Paper Account to \$100.00?'),
        content: const Text(
          'This will stop the bot, clear open positions and drawdown locks, and reset the Crypto Portfolio cash and equity to \$100.00 USDT.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('CANCEL'),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              _coordinator.manualResetDrawdownAndAccount();
            },
            child: const Text('CONFIRM RESET'),
          ),
        ],
      ),
    );
  }
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

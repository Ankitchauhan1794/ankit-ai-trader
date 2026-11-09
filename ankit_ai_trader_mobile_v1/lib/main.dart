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

  /// STAGE 22, 33 & 47.1 — MARKETS TAB (Dynamic CoinDCX Market Catalogue, Search & Quote Filters):
  Widget _buildMarketsTab() {
    return ListView(
      padding: const EdgeInsets.all(14),
      children: [
        _buildMarketCatalogueSummaryAndFiltersCard(),
        const SizedBox(height: 14),
        _buildDiscoveredMarketCatalogueListCard(),
        const SizedBox(height: 14),
        _buildLiveMarketCard(),
        const SizedBox(height: 14),
        _buildMarketScannerCard(),
      ],
    );
  }

  /// STAGE 22 & 38 — TRADES TAB:
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

  /// STAGE 22, 29–37 — AI LAB TAB:
  Widget _buildAiLabTab() {
    final activeStrat = _coordinator.strategyRegistry.activeStrategy;
    final expStrats = _coordinator.strategyRegistry.experimentalStrategies;
    final costEst = _coordinator.agentOrchestrator.estimateCouncilRunCost();
    final hypotheses =
        SandboxedStrategyBuilderAndOptimizer.generateSandboxedHypotheses();

    return ListView(
      padding: const EdgeInsets.all(14),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'STAGE 29 — STRATEGY REGISTRY (CHAMPION: ${activeStrat.id})',
                  style: const TextStyle(
                      fontWeight: FontWeight.bold, fontSize: 13),
                ),
                const SizedBox(height: 6),
                Text(
                  '${activeStrat.name} (v${activeStrat.version})\n'
                  '• ${activeStrat.rulesSummary}\n'
                  '• Risk / Exit: SL = 1.5 × ATR(14), TP = 3.0 × ATR(14), 1% (\$1) Risk/Trade, 30m Cooldown\n'
                  '• Sandbox Challengers (${expStrats.length}): ${expStrats.map((s) => s.id).join(", ")}',
                  style: const TextStyle(
                      fontSize: 12, color: Colors.white70, height: 1.4),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 14),
        _buildBacktestCard(),
        const SizedBox(height: 14),
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
                      fontSize: 11, color: Colors.white60, height: 1.35),
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

  /// STAGE 22 — REPORTS TAB (Stage 5 Diagnostics + Stages 24, 38, 39, 45, 46):
  Widget _buildReportsTab() {
    final hbLevel = _coordinator.heartbeatHealthLevel;
    final hbColor = hbLevel == 'OK'
        ? _greenProfit
        : (hbLevel == 'DELAYED' ? _orangeWarn : _redLoss);
    final events = _coordinator.recentEvents;
    final alloc = _coordinator.currentPortfolioAllocation;
    final paperStatus = _coordinator.extendedPaperStatus;
    final liveGate = _coordinator.controlledLiveGateStatus;

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
        const SizedBox(height: 14),
        _buildMultiPairPipelineDiagnosticsCard(),
        const SizedBox(height: 14),
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
                      fontSize: 11, color: Colors.white70, height: 1.4),
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

  /// STAGE 22 — SETTINGS TAB (Stage 9 Auto-Resume, Stage 10 OnePlus Battery, Stage 43 Security, Account Reset):
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
          child: const ListTile(
            title: Text(
              'Stage 43 & 46 — Security & Controlled Live Lock',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
            ),
            subtitle: Text(
              'Trade-only permissions enforced; withdrawals disabled; API credentials never sent to any LLM; Stage 46 Controlled Live is HARD-LOCKED (Paper-Only Mode active).',
              style: TextStyle(fontSize: 11),
            ),
          ),
        ),
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
              children: quoteOptions.map((q) {
                final selected = _coordinator.selectedQuoteCurrencyFilter == q;
                return ChoiceChip(
                  key: ValueKey('quote_filter_$q'),
                  label: Text(q, style: const TextStyle(fontSize: 11)),
                  selected: selected,
                  onSelected: (_) => _coordinator.setQuoteCurrencyFilter(q),
                );
              }).toList(),
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
              'DISCOVERED MARKETS (${filtered.length} SHOWN)',
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
                final lastPx =
                    t != null ? t.lastPrice.toStringAsFixed(m.pricePrecision.clamp(2, 8)) : '--';
                final spreadStr = t != null
                    ? '${t.spreadBps.toStringAsFixed(1)} bps (${t.spreadPct.toStringAsFixed(3)}%)'
                    : '--';
                final volStr = t != null ? t.volume24h.toStringAsFixed(2) : '--';
                final eligColor = m.isEligibleForPaperTrading
                    ? _greenProfit
                    : (m.isActiveStatus ? _orangeWarn : _redLoss);

                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Flexible(
                            child: Text(
                              '${m.symbol} (${m.pair.isNotEmpty ? m.pair : "NO_PAIR"}) • Quote: ${m.baseCurrencyShortName.isNotEmpty ? m.baseCurrencyShortName : "--"}${m.isNewlyListed ? " [NEW]" : ""}',
                              style: const TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 12,
                              ),
                            ),
                          ),
                          Text(
                            m.status.toUpperCase(),
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.bold,
                              color: m.isActiveStatus ? _greenProfit : _redLoss,
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
    final String label = state.dashboardLabel;
    switch (state) {
      case BotEngineState.running:
        bg = _greenProfit.withOpacity(0.2);
        break;
      case BotEngineState.pausedNetworkLoss:
      case BotEngineState.reconnecting:
      case BotEngineState.waitingForFreshData:
      case BotEngineState.pausedStaleData:
      case BotEngineState.pausedAfterRecoveryManualStartRequired:
        bg = _orangeWarn.withOpacity(0.2);
        break;
      case BotEngineState.recoveryFailed:
      case BotEngineState.lockedDailyLossLimit:
      case BotEngineState.stoppedMaxDrawdownReached:
        bg = _redLoss.withOpacity(0.25);
        break;
      case BotEngineState.stopped:
        bg = Colors.blueGrey.withOpacity(0.3);
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

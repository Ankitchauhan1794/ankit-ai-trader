import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'models/trading_models.dart';
import 'services/coindcx_market_service.dart';
import 'services/paper_broker.dart';
import 'services/persistence_db.dart';
import 'services/trading_coordinator.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const AnkitTraderApp());
}

/// Headless entrypoint invoked by `TradingForegroundService.kt` when the screen is locked
/// or the main Activity is swiped away. Restores SQLite state and only processes candles
/// if the user had explicitly left the bot in `BotEngineState.running`.
@pragma('vm:entry-point')
void backgroundServiceMain() {
  WidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.ankit.aitrader/background_worker');
  final marketService = CoinDcxMarketService();
  final persistence = PersistenceDatabase();
  final broker = PaperBroker();

  channel.setMethodCallHandler((call) async {
    if (call.method == 'onBackgroundTick') {
      try {
        final state = await persistence.restoreIntoBroker(broker);
        if (state != BotEngineState.running) {
          return true;
        }
        final pairs = await marketService.discoverActiveUsdtPairs();
        final nowMs = DateTime.now().toUtc().millisecondsSinceEpoch;
        final latestPrices = <String, double>{};

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
          if (closed15m.isEmpty ||
              closed1h.isEmpty ||
              CoinDcxMarketService.isDataStale(
                closedCandles: closed15m,
                interval: '15m',
                nowMs: nowMs,
              )) {
            await persistence.saveFullState(
              broker: broker,
              botState: BotEngineState.pausedStaleData,
              latestPrices: latestPrices,
            );
            return false;
          }
          latestPrices[symbol] = closed15m.last.close;
          broker.processClosedCandleStep(
            symbol: symbol,
            closed15m: closed15m,
            closed1h: closed1h,
            latestPrices: latestPrices,
            minNotionalUsdt: meta.minNotional,
            minQuantity: meta.minQuantity,
          );
        }

        BotEngineState nextState = BotEngineState.running;
        if (broker.maxDrawdownLocked) {
          nextState = BotEngineState.stoppedMaxDrawdownReached;
        } else if (broker.isDailyLockedAt(nowMs)) {
          nextState = BotEngineState.lockedDailyLossLimit;
        }

        await persistence.saveFullState(
          broker: broker,
          botState: nextState,
          latestPrices: latestPrices,
        );

        final eq = broker.accountEquity(latestPrices).toStringAsFixed(2);
        await channel.invokeMethod('updateServiceNotification', {
          'title': 'Ankit AI Trader — Paper Engine',
          'text': 'State: ${nextState.name.toUpperCase()} | Equity: \$$eq USDT',
        });
      } catch (_) {
        // Network loss or timeout in background: pause safely and require manual START
        try {
          await persistence.restoreIntoBroker(broker);
          await persistence.saveFullState(
            broker: broker,
            botState: BotEngineState.pausedAfterRecoveryManualStartRequired,
            latestPrices: const {},
          );
          await channel.invokeMethod('updateServiceNotification', {
            'title': 'Ankit AI Trader — PAUSED',
            'text': 'Network/data interrupted. Manual START required.',
          });
        } catch (_) {}
      }
      return true;
    }
    return false;
  });
}

class AnkitTraderApp extends StatelessWidget {
  const AnkitTraderApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Ankit AI Trader',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF0B101B),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF39D6A0),
          secondary: Color(0xFF4C8DFF),
        ),
      ),
      home: const DashboardPage(),
    );
  }
}

class DashboardPage extends StatefulWidget {
  final Future<bool> Function()? internetChecker;
  final TradingCoordinator? injectedCoordinator;

  const DashboardPage({
    super.key,
    this.internetChecker,
    this.injectedCoordinator,
  });

  @override
  State<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends State<DashboardPage> {
  late final TradingCoordinator _coordinator;
  bool _ownsCoordinator = false;

  @override
  void initState() {
    super.initState();
    if (widget.injectedCoordinator != null) {
      _coordinator = widget.injectedCoordinator!;
    } else {
      _ownsCoordinator = true;
      _coordinator = TradingCoordinator(
        customInternetProbe: widget.internetChecker,
      );
      unawaited(
        _coordinator.initialize(
          enablePlatformChannels: widget.internetChecker == null,
        ),
      );
    }
    _coordinator.addListener(_onCoordinatorChanged);
  }

  void _onCoordinatorChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _coordinator.removeListener(_onCoordinatorChanged);
    if (_ownsCoordinator) {
      _coordinator.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final broker = _coordinator.broker;
    final prices = _coordinator.latestPrices;
    final nowMs = DateTime.now().toUtc().millisecondsSinceEpoch;
    final equity = broker.accountEquity(prices);
    final cash = broker.availableCashUsdt;
    final realized = broker.realizedPnlUsdt;
    final unrealized = broker.unrealizedPnl(prices);
    final dailyPnl = broker.todayRealizedPnl(nowMs);
    final drawdown = broker.currentDrawdownUsdt(prices);

    final btcPrice = prices['BTCUSDT'] ?? 0.0;
    final ethPrice = prices['ETHUSDT'] ?? 0.0;
    final btcEval = _coordinator.latestEvaluations['BTCUSDT'];
    final ethEval = _coordinator.latestEvaluations['ETHUSDT'];

    final isBotRunning = _coordinator.engineState == BotEngineState.running &&
        _coordinator.marketDataStatus == MarketDataStatus.connected;

    return Scaffold(
      appBar: AppBar(
        backgroundColor: const Color(0xFF111827),
        title: const Text(
          'ANKIT AI TRADER',
          style: TextStyle(fontWeight: FontWeight.bold, letterSpacing: 1.1),
        ),
        actions: [
          Container(
            margin: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: const Color(0xFF39D6A0).withAlpha(33),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: const Color(0xFF39D6A0)),
            ),
            child: const Center(
              child: Text(
                'PAPER TRADING MODE',
                style: TextStyle(
                  color: Color(0xFF39D6A0),
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildStatusGrid(isBotRunning),
            const SizedBox(height: 12),
            _buildBannerCard(),
            const SizedBox(height: 12),
            _buildAccountMetricsCard(
              equity: equity,
              cash: cash,
              realized: realized,
              unrealized: unrealized,
              dailyPnl: dailyPnl,
              drawdown: drawdown,
            ),
            const SizedBox(height: 12),
            _buildLiveMarketCard(
              btcPrice: btcPrice,
              ethPrice: ethPrice,
              btcEval: btcEval,
              ethEval: ethEval,
            ),
            const SizedBox(height: 12),
            _buildControlButtons(isBotRunning),
            const SizedBox(height: 12),
            _buildOpenPositionsCard(),
            const SizedBox(height: 12),
            _buildRecentTradesCard(),
            const SizedBox(height: 12),
            _buildBacktestCard(),
          ],
        ),
      ),
    );
  }

  Widget _buildStatusGrid(bool isBotRunning) {
    final netConnected = _coordinator.internetConnected;
    final mktStatus = _coordinator.marketDataStatus;
    final fgsActive = _coordinator.foregroundServiceActive;

    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        _statusChip(
          netConnected ? 'INTERNET CONNECTED' : 'INTERNET DISCONNECTED',
          netConnected ? const Color(0xFF39D6A0) : Colors.redAccent,
        ),
        _statusChip(
          'MARKET DATA: ${mktStatus.name.toUpperCase()}',
          mktStatus == MarketDataStatus.connected
              ? const Color(0xFF39D6A0)
              : Colors.orangeAccent,
        ),
        _statusChip(
          fgsActive ? 'FOREGROUND SERVICE: ACTIVE' : 'FOREGROUND SERVICE: IDLE',
          fgsActive ? const Color(0xFF4C8DFF) : Colors.grey,
        ),
        _statusChip(
          isBotRunning
              ? 'BOT RUNNING'
              : 'ENGINE: ${_coordinator.engineState.name.toUpperCase()}',
          isBotRunning ? const Color(0xFF39D6A0) : Colors.amberAccent,
        ),
      ],
    );
  }

  Widget _statusChip(String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withAlpha(33),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withAlpha(89)),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 11,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }

  Widget _buildBannerCard() {
    final lastUpdate = _coordinator.lastMarketDataUpdateUtc != null
        ? _coordinator.lastMarketDataUpdateUtc!.toIso8601String()
        : 'Never';
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF161F30),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.white12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            _coordinator.statusBannerMessage,
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.bold,
              fontSize: 13,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Last Market Data Update (UTC): $lastUpdate',
            style: const TextStyle(color: Colors.white70, fontSize: 11),
          ),
        ],
      ),
    );
  }

  Widget _buildAccountMetricsCard({
    required double equity,
    required double cash,
    required double realized,
    required double unrealized,
    required double dailyPnl,
    required double drawdown,
  }) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF161F30),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.white12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'PAPER ACCOUNT PORTFOLIO (1X SPOT — NO LIVE ORDERS)',
            style: TextStyle(
              color: Colors.white70,
              fontSize: 11,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              _metricTile('Account Equity', '\$${equity.toStringAsFixed(2)}'),
              _metricTile('Available Cash', '\$${cash.toStringAsFixed(2)}'),
              _metricTile('Realized P&L', '\$${realized.toStringAsFixed(2)}'),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              _metricTile(
                  'Unrealized P&L', '\$${unrealized.toStringAsFixed(2)}'),
              _metricTile(
                  'Daily P&L (Max -\$2)', '\$${dailyPnl.toStringAsFixed(2)}'),
              _metricTile(
                  'Drawdown (Max \$10)', '\$${drawdown.toStringAsFixed(2)}'),
            ],
          ),
        ],
      ),
    );
  }

  Widget _metricTile(String label, String value) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(color: Colors.white54, fontSize: 11)),
        const SizedBox(height: 2),
        Text(
          value,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 15,
            fontWeight: FontWeight.bold,
          ),
        ),
      ],
    );
  }

  Widget _buildLiveMarketCard({
    required double btcPrice,
    required double ethPrice,
    required StrategyEvaluationResult? btcEval,
    required StrategyEvaluationResult? ethEval,
  }) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF161F30),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.white12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'COINDCX PUBLIC SPOT FEEDS (CLOSED 15M & 1H CANDLES)',
            style: TextStyle(
              color: Colors.white70,
              fontSize: 11,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 8),
          _pairRow('BTC/USDT', btcPrice, btcEval),
          const Divider(color: Colors.white12),
          _pairRow('ETH/USDT', ethPrice, ethEval),
        ],
      ),
    );
  }

  Widget _pairRow(
    String label,
    double price,
    StrategyEvaluationResult? eval,
  ) {
    final priceText = price > 0 ? '\$${price.toStringAsFixed(2)}' : '--';
    final sigText = eval?.description ?? 'AWAITING MARKET POLL';
    final indText = eval?.ema20_15m != null
        ? '15m EMA20: ${eval!.ema20_15m!.toStringAsFixed(1)} | EMA50: ${eval.ema50_15m!.toStringAsFixed(1)} | RSI14: ${eval.rsi14_15m!.toStringAsFixed(1)} | ATR14: ${eval.atr14_15m!.toStringAsFixed(2)}'
        : 'Indicators warming up';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              label,
              style: const TextStyle(
                  fontWeight: FontWeight.bold, color: Colors.white),
            ),
            Text(
              priceText,
              style: const TextStyle(
                fontWeight: FontWeight.bold,
                color: Color(0xFF39D6A0),
                fontSize: 15,
              ),
            ),
          ],
        ),
        const SizedBox(height: 3),
        Text(sigText,
            style: const TextStyle(color: Colors.amberAccent, fontSize: 11)),
        Text(indText,
            style: const TextStyle(color: Colors.white60, fontSize: 11)),
      ],
    );
  }

  Widget _buildControlButtons(bool isBotRunning) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        ElevatedButton.icon(
          onPressed: isBotRunning ? null : () => _coordinator.manualStartBot(),
          icon: const Icon(Icons.play_arrow, size: 18),
          label: const Text('START PAPER BOT'),
          style: ElevatedButton.styleFrom(
            backgroundColor: const Color(0xFF39D6A0),
            foregroundColor: Colors.black,
          ),
        ),
        ElevatedButton.icon(
          onPressed: isBotRunning ? () => _coordinator.manualPauseBot() : null,
          icon: const Icon(Icons.pause, size: 18),
          label: const Text('PAUSE'),
        ),
        ElevatedButton.icon(
          onPressed: () => _coordinator.manualStopBot(),
          icon: const Icon(Icons.stop, size: 18),
          label: const Text('STOP'),
          style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent),
        ),
        OutlinedButton(
          onPressed: () =>
              _coordinator.pollMarketDataAndEvaluate(allowTradingExecution: false),
          child: const Text('REFRESH QUOTES'),
        ),
        OutlinedButton(
          onPressed: () => _coordinator.openBatteryOptimizationSettings(),
          child: const Text('BATTERY SETTINGS'),
        ),
        OutlinedButton(
          onPressed: () => _coordinator.manualResetDrawdownAndAccount(),
          child: const Text('RESET \$100 ACCOUNT'),
        ),
      ],
    );
  }

  Widget _buildOpenPositionsCard() {
    final positions = _coordinator.broker.openPositions.values.toList();
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF161F30),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.white12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'OPEN SIMULATED POSITIONS (${positions.length}/1)',
            style: const TextStyle(
              color: Colors.white70,
              fontSize: 11,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 8),
          if (positions.isEmpty)
            const Text(
              'No open paper position.',
              style: TextStyle(color: Colors.white54, fontSize: 12),
            )
          else
            for (final pos in positions)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text(
                  '${pos.symbol} | Qty: ${pos.quantity.toStringAsFixed(6)} | Entry: \$${pos.entryPrice.toStringAsFixed(2)} | SL: \$${pos.stopLoss.toStringAsFixed(2)} | TP: \$${pos.takeProfit.toStringAsFixed(2)}',
                  style: const TextStyle(color: Colors.white, fontSize: 12),
                ),
              ),
        ],
      ),
    );
  }

  Widget _buildRecentTradesCard() {
    final trades = _coordinator.broker.closedTrades.take(5).toList();
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF161F30),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.white12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'RECENT SIMULATED TRADES (${_coordinator.broker.closedTrades.length})',
            style: const TextStyle(
              color: Colors.white70,
              fontSize: 11,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 8),
          if (trades.isEmpty)
            const Text(
              'No closed paper trades yet.',
              style: TextStyle(color: Colors.white54, fontSize: 12),
            )
          else
            for (final t in trades)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text(
                  '${t.symbol} | Entry: \$${t.entryPrice.toStringAsFixed(2)} -> Exit: \$${t.exitPrice.toStringAsFixed(2)} | Net P&L: \$${t.realizedPnlUsdt.toStringAsFixed(2)} (Fees: \$${t.totalFeesUsdt.toStringAsFixed(3)}) | ${t.exitReason}',
                  style: TextStyle(
                    color: t.realizedPnlUsdt >= 0
                        ? const Color(0xFF39D6A0)
                        : Colors.redAccent,
                    fontSize: 12,
                  ),
                ),
              ),
        ],
      ),
    );
  }

  Widget _buildBacktestCard() {
    final report = _coordinator.lastBacktestReport;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF161F30),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.white12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                'HISTORICAL BACKTEST ENGINE (BTC/USDT)',
                style: TextStyle(
                  color: Colors.white70,
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                ),
              ),
              TextButton(
                onPressed: () =>
                    _coordinator.runLiveHistoricalBacktest('BTCUSDT'),
                child: const Text('RUN BACKTEST'),
              ),
            ],
          ),
          if (report == null)
            const Text(
              'Run backtest on historical candles using identical strategy, fees, slippage & risk rules.',
              style: TextStyle(color: Colors.white54, fontSize: 12),
            )
          else
            Text(
              'Trades: ${report.totalTrades} | Win Rate: ${report.winRatePercent.toStringAsFixed(1)}% | Net P&L: \$${report.netPnlUsdt.toStringAsFixed(2)} | Profit Factor: ${report.profitFactor.toStringAsFixed(2)} | Max DD: \$${report.maxDrawdownUsdt.toStringAsFixed(2)} | Avg R: ${report.averageRewardToRisk.toStringAsFixed(2)}R',
              style: const TextStyle(color: Colors.white, fontSize: 12),
            ),
        ],
      ),
    );
  }
}
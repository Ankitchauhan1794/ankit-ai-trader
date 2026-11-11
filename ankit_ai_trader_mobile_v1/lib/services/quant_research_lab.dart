import 'dart:math' as math;
import '../models/trading_models.dart';
import 'indicator_engine.dart';

enum StrategyApprovalStatus {
  experimental,
  shadowPaper,
  approvedChampion,
  retired,
}

class RegisteredStrategyDescriptor {
  final String id;
  final String name;
  final String version;
  final StrategyApprovalStatus status;
  final List<String> timeframes;
  final List<String> supportedSymbols;
  final List<String> allowedRegimes;
  final String entryRuleSummary;
  final String exitRuleSummary;

  const RegisteredStrategyDescriptor({
    required this.id,
    required this.name,
    required this.version,
    required this.status,
    this.timeframes = const ['15m', '1h'],
    this.supportedSymbols = const ['ALL_ELIGIBLE_COINDCX_SPOT'],
    this.allowedRegimes = const ['TRENDING_BULL', 'RANGING_ACCUMULATION'],
    this.entryRuleSummary = '1H EMA20>EMA50 + 15m EMA20>EMA50 + RSI(14) 50-68',
    this.exitRuleSummary = 'SL = 1.5x ATR(14), TP = 3.0x ATR(14) or Bearish Cross',
  });

  RegisteredStrategyDescriptor copyWith({
    StrategyApprovalStatus? status,
    String? version,
  }) {
    return RegisteredStrategyDescriptor(
      id: id,
      name: name,
      version: version ?? this.version,
      status: status ?? this.status,
      timeframes: timeframes,
      supportedSymbols: supportedSymbols,
      allowedRegimes: allowedRegimes,
      entryRuleSummary: entryRuleSummary,
      exitRuleSummary: exitRuleSummary,
    );
  }
}

class StrategyRegistry {
  RegisteredStrategyDescriptor _activeChampion =
      const RegisteredStrategyDescriptor(
    id: 'EMA_20_50_RSI_ATR_V1',
    name: 'EMA 20/50 + RSI 14 + ATR 14 Multi-Timeframe',
    version: '1.0.0',
    status: StrategyApprovalStatus.approvedChampion,
  );

  final List<RegisteredStrategyDescriptor> _experimental = [
    const RegisteredStrategyDescriptor(
      id: 'VOL_BREAKOUT_SHADOW_V1',
      name: 'ATR Volatility Breakout Challenger',
      version: '0.9.0-exp',
      status: StrategyApprovalStatus.experimental,
    ),
  ];

  RegisteredStrategyDescriptor get activeStrategy => _activeChampion;

  List<RegisteredStrategyDescriptor> get experimentalStrategies =>
      List.unmodifiable(_experimental);

  void registerExperimental(RegisteredStrategyDescriptor descriptor) {
    _experimental.add(
      descriptor.copyWith(status: StrategyApprovalStatus.experimental),
    );
  }

  bool promoteExperimentalToChampion({
    required String strategyId,
    required RobustnessValidationReport validationReport,
    required bool humanApproved,
  }) {
    if (!humanApproved || !validationReport.passesAllGates) {
      return false;
    }
    final idx = _experimental.indexWhere((s) => s.id == strategyId);
    if (idx == -1) return false;
    final promoted = _experimental[idx].copyWith(
      status: StrategyApprovalStatus.approvedChampion,
    );
    _experimental.removeAt(idx);
    _activeChampion = promoted;
    return true;
  }
}

class RobustnessValidationReport {
  final String strategyId;
  final int sampleSize;
  final double winRatePct;
  final double profitFactor;
  final double expectancyUsdt;
  final double maxDrawdownUsdt;
  final double outOfSampleReturnRatio;
  final bool walkForwardPassed;
  final bool passesAllGates;
  final String summaryReason;

  const RobustnessValidationReport({
    required this.strategyId,
    required this.sampleSize,
    required this.winRatePct,
    required this.profitFactor,
    required this.expectancyUsdt,
    required this.maxDrawdownUsdt,
    required this.outOfSampleReturnRatio,
    required this.walkForwardPassed,
    required this.passesAllGates,
    required this.summaryReason,
  });
}

class QuantResearchValidator {
  const QuantResearchValidator();

  RobustnessValidationReport evaluateClosedTrades({
    required String strategyId,
    required List<ClosedPaperTrade> trades,
    int minRequiredTrades = 5,
  }) {
    if (trades.isEmpty) {
      return RobustnessValidationReport(
        strategyId: strategyId,
        sampleSize: 0,
        winRatePct: 0.0,
        profitFactor: 0.0,
        expectancyUsdt: 0.0,
        maxDrawdownUsdt: 0.0,
        outOfSampleReturnRatio: 0.0,
        walkForwardPassed: false,
        passesAllGates: false,
        summaryReason: 'Insufficient closed trades (0/$minRequiredTrades)',
      );
    }

    int wins = 0;
    double grossProfit = 0.0;
    double grossLoss = 0.0;
    double cumPnl = 0.0;
    double peak = 0.0;
    double maxDd = 0.0;

    for (final t in trades.reversed) {
      if (t.realizedPnlUsdt >= 0) {
        wins++;
        grossProfit += t.realizedPnlUsdt;
      } else {
        grossLoss += t.realizedPnlUsdt.abs();
      }
      cumPnl += t.realizedPnlUsdt;
      if (cumPnl > peak) peak = cumPnl;
      final dd = peak - cumPnl;
      if (dd > maxDd) maxDd = dd;
    }

    final winRate = (wins / trades.length) * 100.0;
    final pf = grossLoss > 0
        ? (grossProfit / grossLoss)
        : (grossProfit > 0 ? 9.99 : 0.0);
    final expectancy = cumPnl / trades.length;

    final mid = trades.length ~/ 2;
    double isPnl = 0.0;
    double oosPnl = 0.0;
    for (int i = 0; i < trades.length; i++) {
      if (i < mid) {
        isPnl += trades[i].realizedPnlUsdt;
      } else {
        oosPnl += trades[i].realizedPnlUsdt;
      }
    }
    final oosRatio = isPnl > 0 ? (oosPnl / isPnl).clamp(0.0, 2.0) : (oosPnl > 0 ? 1.0 : 0.0);
    final wfPassed = trades.length >= minRequiredTrades && pf >= 1.1 && expectancy > 0;
    final passes = wfPassed && maxDd <= 10.0;

    return RobustnessValidationReport(
      strategyId: strategyId,
      sampleSize: trades.length,
      winRatePct: winRate,
      profitFactor: pf,
      expectancyUsdt: expectancy,
      maxDrawdownUsdt: maxDd,
      outOfSampleReturnRatio: oosRatio,
      walkForwardPassed: wfPassed,
      passesAllGates: passes,
      summaryReason: passes
          ? 'PASSED: PF ${pf.toStringAsFixed(2)}, WinRate ${winRate.toStringAsFixed(1)}%, DD \$${maxDd.toStringAsFixed(2)}'
          : 'GATE_HOLD: Sample ${trades.length}/$minRequiredTrades, PF ${pf.toStringAsFixed(2)}, Exp \$${expectancy.toStringAsFixed(2)}',
    );
  }
}

class ChampionChallengerDecision {
  final String championId;
  final String challengerId;
  final bool challengerApprovedToReplace;
  final String reason;

  const ChampionChallengerDecision({
    required this.championId,
    required this.challengerId,
    required this.challengerApprovedToReplace,
    required this.reason,
  });

  static ChampionChallengerDecision compare({
    required RobustnessValidationReport championReport,
    required RobustnessValidationReport challengerReport,
    int minForwardPaperTrades = 10,
  }) {
    if (challengerReport.sampleSize < minForwardPaperTrades) {
      return ChampionChallengerDecision(
        championId: championReport.strategyId,
        challengerId: challengerReport.strategyId,
        challengerApprovedToReplace: false,
        reason:
            'REJECTED: Challenger has only ${challengerReport.sampleSize}/$minForwardPaperTrades forward trades',
      );
    }
    if (!challengerReport.passesAllGates) {
      return ChampionChallengerDecision(
        championId: championReport.strategyId,
        challengerId: challengerReport.strategyId,
        challengerApprovedToReplace: false,
        reason: 'REJECTED: Challenger failed OOS/Walk-Forward robustness gates',
      );
    }
    final better = challengerReport.profitFactor >
            championReport.profitFactor * 1.10 &&
        challengerReport.maxDrawdownUsdt <= championReport.maxDrawdownUsdt;
    return ChampionChallengerDecision(
      championId: championReport.strategyId,
      challengerId: challengerReport.strategyId,
      challengerApprovedToReplace: better,
      reason: better
          ? 'APPROVED_FOR_HUMAN_REVIEW: Challenger outperforms Champion PF & Drawdown'
          : 'RETAIN_CHAMPION: Challenger does not beat Champion by >=10% PF margin',
    );
  }
}

enum DetectedMarketRegime {
  trendingBull,
  trendingBear,
  rangingSideways,
  highVolatilitySpike,
  lowLiquidityWideSpread,
  staleDisconnected,
}

class MarketRegimeAssessment {
  final String symbol;
  final DetectedMarketRegime regime;
  final String regimeLabel;
  final double confidence;
  final double atrVolatilityPct;
  final double spreadPct;
  final bool tradingAllowedInRegime;
  final String reason;

  const MarketRegimeAssessment({
    required this.symbol,
    required this.regime,
    required this.regimeLabel,
    required this.confidence,
    required this.atrVolatilityPct,
    required this.spreadPct,
    required this.tradingAllowedInRegime,
    required this.reason,
  });
}

class MarketRegimeDetector {
  static MarketRegimeAssessment detect({
    required String symbol,
    required List<Candle> closedCandles,
    LiveMarketTicker? liveTicker,
    required int nowMs,
  }) {
    if (closedCandles.length < 50) {
      return MarketRegimeAssessment(
        symbol: symbol,
        regime: DetectedMarketRegime.staleDisconnected,
        regimeLabel: 'WARMING_UP_OR_STALE',
        confidence: 0.0,
        atrVolatilityPct: 0.0,
        spreadPct: liveTicker?.spreadPct ?? 0.0,
        tradingAllowedInRegime: false,
        reason: 'Need >=50 closed candles for regime classification',
      );
    }

    final spread = liveTicker?.spreadPct ?? 0.05;
    if (spread > 0.35) {
      return MarketRegimeAssessment(
        symbol: symbol,
        regime: DetectedMarketRegime.lowLiquidityWideSpread,
        regimeLabel: 'LOW_LIQUIDITY_WIDE_SPREAD',
        confidence: 0.90,
        atrVolatilityPct: 0.0,
        spreadPct: spread,
        tradingAllowedInRegime: false,
        reason: 'Spread ${spread.toStringAsFixed(3)}% exceeds 0.35% threshold',
      );
    }

    const ind = IndicatorEngine();
    final closes = closedCandles.map((c) => c.close).toList();
    final ema20 = ind.calculateEmaSeries(closes, 20).last;
    final ema50 = ind.calculateEmaSeries(closes, 50).last;
    final atr14 = ind.calculateAtr(closedCandles, period: 14) ?? 0.0;
    final lastPrice = closes.last;
    final atrPct = lastPrice > 0 ? (atr14 / lastPrice) * 100.0 : 0.0;

    if (atrPct > 5.0) {
      return MarketRegimeAssessment(
        symbol: symbol,
        regime: DetectedMarketRegime.highVolatilitySpike,
        regimeLabel: 'HIGH_VOLATILITY_SPIKE',
        confidence: 0.88,
        atrVolatilityPct: atrPct,
        spreadPct: spread,
        tradingAllowedInRegime: false,
        reason: 'ATR ${atrPct.toStringAsFixed(2)}% indicates extreme volatility spike',
      );
    }

    final diffPct = ema50 > 0 ? ((ema20 - ema50) / ema50) * 100.0 : 0.0;
    if (diffPct > 0.15) {
      return MarketRegimeAssessment(
        symbol: symbol,
        regime: DetectedMarketRegime.trendingBull,
        regimeLabel: 'TRENDING_BULL',
        confidence: 0.85,
        atrVolatilityPct: atrPct,
        spreadPct: spread,
        tradingAllowedInRegime: true,
        reason: 'EMA20 > EMA50 (+${diffPct.toStringAsFixed(2)}%) with healthy spread & volatility',
      );
    } else if (diffPct < -0.15) {
      return MarketRegimeAssessment(
        symbol: symbol,
        regime: DetectedMarketRegime.trendingBear,
        regimeLabel: 'TRENDING_BEAR',
        confidence: 0.82,
        atrVolatilityPct: atrPct,
        spreadPct: spread,
        tradingAllowedInRegime: false,
        reason: 'Bearish regime (${diffPct.toStringAsFixed(2)}%); long-only spot entries paused',
      );
    }

    return MarketRegimeAssessment(
      symbol: symbol,
      regime: DetectedMarketRegime.rangingSideways,
      regimeLabel: 'RANGING_SIDEWAYS',
      confidence: 0.75,
      atrVolatilityPct: atrPct,
      spreadPct: spread,
      tradingAllowedInRegime: true,
      reason: 'Balanced consolidation regime (${diffPct.toStringAsFixed(2)}%)',
    );
  }
}

class RankedScannerCandidate {
  final String symbol;
  final double compositeScore;
  final double spreadPct;
  final double volume24h;
  final double momentum24hPct;
  final bool eligibleForEvaluation;
  final String statusNote;

  const RankedScannerCandidate({
    required this.symbol,
    required this.compositeScore,
    required this.spreadPct,
    required this.volume24h,
    required this.momentum24hPct,
    required this.eligibleForEvaluation,
    required this.statusNote,
  });
}

class CoinDcxMarketScanner {
  static List<RankedScannerCandidate> rankPairs({
    required Map<String, LiveMarketTicker> tickers,
    double maxSpreadPct = 0.35,
  }) {
    final list = <RankedScannerCandidate>[];
    for (final entry in tickers.entries) {
      final sym = entry.key;
      final t = entry.value;
      final spread = t.spreadPct;
      final eligible = t.lastPrice > 0 && spread <= maxSpreadPct && t.volume24h > 0;
      final liqScore = t.volume24h > 0 ? math.min(40.0, math.log(t.volume24h + 1) * 3.0) : 0.0;
      final spreadScore = (maxSpreadPct - spread).clamp(0.0, maxSpreadPct) * 100.0;
      final momScore = t.change24hPct.clamp(-10.0, 15.0) * 1.5;
      final total = eligible ? (liqScore + spreadScore + momScore).clamp(0.0, 100.0) : 0.0;
      list.add(
        RankedScannerCandidate(
          symbol: sym,
          compositeScore: total,
          spreadPct: spread,
          volume24h: t.volume24h,
          momentum24hPct: t.change24hPct,
          eligibleForEvaluation: eligible,
          statusNote: eligible
              ? 'ELIGIBLE (Score ${total.toStringAsFixed(1)})'
              : 'FILTERED_OUT (Spread ${spread.toStringAsFixed(3)}%)',
        ),
      );
    }
    list.sort((a, b) => b.compositeScore.compareTo(a.compositeScore));
    return list;
  }
}

enum PostmortemCauseCategory {
  profitableTargetHit,
  normalStopLossWithinPlan,
  adverseRegimeShift,
  feeAndSlippageDrag,
}

class TradePostmortemReport {
  final String tradeId;
  final String symbol;
  final String strategyVersion;
  final double realizedPnlUsdt;
  final PostmortemCauseCategory primaryCause;
  final String actionableSummary;

  const TradePostmortemReport({
    required this.tradeId,
    required this.symbol,
    required this.strategyVersion,
    required this.realizedPnlUsdt,
    required this.primaryCause,
    required this.actionableSummary,
  });
}

class TradePostmortemAnalyzer {
  static TradePostmortemReport analyzeClosedTrade({
    required ClosedPaperTrade trade,
    required String strategyVersion,
  }) {
    if (trade.realizedPnlUsdt >= 0) {
      return TradePostmortemReport(
        tradeId: trade.id,
        symbol: trade.symbol,
        strategyVersion: strategyVersion,
        realizedPnlUsdt: trade.realizedPnlUsdt,
        primaryCause: PostmortemCauseCategory.profitableTargetHit,
        actionableSummary:
            'Trade ${trade.id} closed in profit (+\$${trade.realizedPnlUsdt.toStringAsFixed(2)}) via ${trade.exitReason}.',
      );
    }
    if (trade.totalFeesUsdt > trade.realizedPnlUsdt.abs() * 0.5) {
      return TradePostmortemReport(
        tradeId: trade.id,
        symbol: trade.symbol,
        strategyVersion: strategyVersion,
        realizedPnlUsdt: trade.realizedPnlUsdt,
        primaryCause: PostmortemCauseCategory.feeAndSlippageDrag,
        actionableSummary:
            'Fee drag (\$${trade.totalFeesUsdt.toStringAsFixed(2)}) contributed materially to net loss.',
      );
    }
    return TradePostmortemReport(
      tradeId: trade.id,
      symbol: trade.symbol,
      strategyVersion: strategyVersion,
      realizedPnlUsdt: trade.realizedPnlUsdt,
      primaryCause: PostmortemCauseCategory.normalStopLossWithinPlan,
      actionableSummary:
          'Controlled stop-loss (\$${trade.realizedPnlUsdt.toStringAsFixed(2)}) within 1% risk budget; no Martingale or revenge sizing allowed.',
    );
  }
}

class PortfolioAllocationDecision {
  final double effectiveTradingCapitalUsd;
  final double riskPerTradeUsd;
  final double dailyLossLimitUsd;
  final double drawdownFloorUsd;
  final double positionSizeThrottleMultiplier;
  final bool depositsLockedAt100Cap;
  final bool martingaleForbidden;

  const PortfolioAllocationDecision({
    required this.effectiveTradingCapitalUsd,
    required this.riskPerTradeUsd,
    required this.dailyLossLimitUsd,
    required this.drawdownFloorUsd,
    required this.positionSizeThrottleMultiplier,
    this.depositsLockedAt100Cap = true,
    this.martingaleForbidden = true,
  });
}

class PortfolioRiskAllocator {
  static PortfolioAllocationDecision computeAllocation({
    required double currentEquityUsd,
    required double externalDepositsUsd,
    required int consecutiveLosses,
    bool depositCapApprovedByUser = false,
  }) {
    final cappedBase = depositCapApprovedByUser
        ? currentEquityUsd
        : math.min(currentEquityUsd, 100.0 + (currentEquityUsd - 100.0 - externalDepositsUsd).clamp(-100.0, 10000.0));
    final throttle = consecutiveLosses >= 2 ? 0.50 : 1.00;
    final riskPerTrade = (cappedBase * 0.01 * throttle).clamp(0.25, 1.00);
    return PortfolioAllocationDecision(
      effectiveTradingCapitalUsd: cappedBase,
      riskPerTradeUsd: riskPerTrade,
      dailyLossLimitUsd: 2.0,
      drawdownFloorUsd: 90.0,
      positionSizeThrottleMultiplier: throttle,
      depositsLockedAt100Cap: !depositCapApprovedByUser,
      martingaleForbidden: true,
    );
  }
}

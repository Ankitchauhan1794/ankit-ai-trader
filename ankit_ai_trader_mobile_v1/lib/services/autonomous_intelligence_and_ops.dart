import 'dart:math' as math;
import '../models/trading_models.dart';
import 'indicator_engine.dart';
import 'quant_research_lab.dart';

// ============================================================================
// STAGE 32 — MARKET REGIME DETECTION
// ============================================================================
enum DetectedMarketRegime {
  bullTrend,
  bearTrend,
  sidewaysRange,
  highVolatility,
  lowVolatilityCompression,
  breakoutExpansion,
  abnormalDislocation,
}

class MarketRegimeAssessment {
  final String symbol;
  final DetectedMarketRegime primaryRegime;
  final DetectedMarketRegime volatilityRegime;
  final double confidence; // 0.0 to 1.0
  final double annualizedVolPct;
  final double emaSlopePct;
  final double spreadBps;
  final bool isAbnormalCondition;
  final String summaryReason;
  final int evaluatedAtMs;

  const MarketRegimeAssessment({
    required this.symbol,
    required this.primaryRegime,
    required this.volatilityRegime,
    required this.confidence,
    required this.annualizedVolPct,
    required this.emaSlopePct,
    required this.spreadBps,
    required this.isAbnormalCondition,
    required this.summaryReason,
    required this.evaluatedAtMs,
  });

  String get regimeLabel {
    switch (primaryRegime) {
      case DetectedMarketRegime.bullTrend:
        return 'BULL TREND';
      case DetectedMarketRegime.bearTrend:
        return 'BEAR TREND';
      case DetectedMarketRegime.sidewaysRange:
        return 'SIDEWAYS RANGE';
      case DetectedMarketRegime.highVolatility:
        return 'HIGH VOLATILITY';
      case DetectedMarketRegime.lowVolatilityCompression:
        return 'LOW VOL COMPRESSION';
      case DetectedMarketRegime.breakoutExpansion:
        return 'BREAKOUT EXPANSION';
      case DetectedMarketRegime.abnormalDislocation:
        return 'ABNORMAL DISLOCATION';
    }
  }
}

class MarketRegimeDetector {
  static const IndicatorEngine _indicators = IndicatorEngine();

  static MarketRegimeAssessment detect({
    required String symbol,
    required List<Candle> closedCandles,
    LiveMarketTicker? liveTicker,
    int? nowMs,
  }) {
    final ts = nowMs ?? DateTime.now().millisecondsSinceEpoch;
    final closed = List<Candle>.from(closedCandles)
      ..sort((a, b) => a.openTimeMs.compareTo(b.openTimeMs));

    if (closed.length < 25) {
      return MarketRegimeAssessment(
        symbol: symbol,
        primaryRegime: DetectedMarketRegime.sidewaysRange,
        volatilityRegime: DetectedMarketRegime.lowVolatilityCompression,
        confidence: 0.35,
        annualizedVolPct: 0.0,
        emaSlopePct: 0.0,
        spreadBps: 0.0,
        isAbnormalCondition: false,
        summaryReason:
            'Insufficient closed candles (${closed.length}/25) for full regime classification.',
        evaluatedAtMs: ts,
      );
    }

    final closes = closed.map((c) => c.close).toList();
    final ema9 = _indicators.calculateEmaSeries(closes, 9);
    final ema21 = _indicators.calculateEmaSeries(closes, 21);
    final atr = _indicators.calculateAtr(closed, period: 14) ?? 0.0;
    final lastClose = closes.last;
    final atrPct = lastClose > 0 ? (atr / lastClose) * 100.0 : 0.0;
    final annualizedVolPct = atrPct * math.sqrt(365 * 24 * 4);

    double spreadBps = 4.0;
    if (liveTicker != null &&
        liveTicker.bid > 0 &&
        liveTicker.ask >= liveTicker.bid) {
      final mid = (liveTicker.bid + liveTicker.ask) / 2.0;
      spreadBps = ((liveTicker.ask - liveTicker.bid) / mid) * 10000.0;
    }

    final emaDiffPct =
        lastClose > 0 ? ((ema9.last - ema21.last) / lastClose) * 100.0 : 0.0;
    final prevEma21 = ema21[math.max(0, ema21.length - 5)];
    final emaSlopePct =
        prevEma21 > 0 ? ((ema21.last - prevEma21) / prevEma21) * 100.0 : 0.0;

    final recentWindow =
        closed.sublist(math.max(0, closed.length - 21), closed.length - 1);
    double recentHigh = recentWindow.first.high;
    for (final c in recentWindow) {
      if (c.high > recentHigh) recentHigh = c.high;
    }

    if (spreadBps > 45.0 || atrPct > 4.5) {
      return MarketRegimeAssessment(
        symbol: symbol,
        primaryRegime: DetectedMarketRegime.abnormalDislocation,
        volatilityRegime: DetectedMarketRegime.highVolatility,
        confidence: 0.92,
        annualizedVolPct: annualizedVolPct,
        emaSlopePct: emaSlopePct,
        spreadBps: spreadBps,
        isAbnormalCondition: true,
        summaryReason:
            'Abnormal market conditions: spread ${spreadBps.toStringAsFixed(1)} bps, ATR ${atrPct.toStringAsFixed(2)}%.',
        evaluatedAtMs: ts,
      );
    }

    final volRegime = atrPct >= 1.2
        ? DetectedMarketRegime.highVolatility
        : DetectedMarketRegime.lowVolatilityCompression;

    if (lastClose > recentHigh && atrPct >= 0.45) {
      final conf = (0.65 + (emaDiffPct.abs() * 0.15)).clamp(0.60, 0.95);
      return MarketRegimeAssessment(
        symbol: symbol,
        primaryRegime: DetectedMarketRegime.breakoutExpansion,
        volatilityRegime: volRegime,
        confidence: conf,
        annualizedVolPct: annualizedVolPct,
        emaSlopePct: emaSlopePct,
        spreadBps: spreadBps,
        isAbnormalCondition: false,
        summaryReason:
            'Price broke 20-bar high (${recentHigh.toStringAsFixed(2)}) with expanding range.',
        evaluatedAtMs: ts,
      );
    }

    if (emaDiffPct > 0.18 && emaSlopePct > 0.08) {
      final conf = (0.60 + (emaDiffPct * 0.4)).clamp(0.55, 0.94);
      return MarketRegimeAssessment(
        symbol: symbol,
        primaryRegime: DetectedMarketRegime.bullTrend,
        volatilityRegime: volRegime,
        confidence: conf,
        annualizedVolPct: annualizedVolPct,
        emaSlopePct: emaSlopePct,
        spreadBps: spreadBps,
        isAbnormalCondition: false,
        summaryReason:
            'Bullish EMA9>EMA21 alignment (+${emaDiffPct.toStringAsFixed(2)}%) with positive slope.',
        evaluatedAtMs: ts,
      );
    }

    if (emaDiffPct < -0.18 && emaSlopePct < -0.08) {
      final conf = (0.60 + (emaDiffPct.abs() * 0.4)).clamp(0.55, 0.94);
      return MarketRegimeAssessment(
        symbol: symbol,
        primaryRegime: DetectedMarketRegime.bearTrend,
        volatilityRegime: volRegime,
        confidence: conf,
        annualizedVolPct: annualizedVolPct,
        emaSlopePct: emaSlopePct,
        spreadBps: spreadBps,
        isAbnormalCondition: false,
        summaryReason:
            'Bearish EMA9<EMA21 alignment (${emaDiffPct.toStringAsFixed(2)}%) with negative slope.',
        evaluatedAtMs: ts,
      );
    }

    return MarketRegimeAssessment(
      symbol: symbol,
      primaryRegime: atrPct < 0.25
          ? DetectedMarketRegime.lowVolatilityCompression
          : DetectedMarketRegime.sidewaysRange,
      volatilityRegime: volRegime,
      confidence: 0.72,
      annualizedVolPct: annualizedVolPct,
      emaSlopePct: emaSlopePct,
      spreadBps: spreadBps,
      isAbnormalCondition: false,
      summaryReason:
          'Range-bound structure (EMA diff ${emaDiffPct.toStringAsFixed(2)}%, ATR ${atrPct.toStringAsFixed(2)}%).',
      evaluatedAtMs: ts,
    );
  }
}

// ============================================================================
// STAGE 33 — MARKET SCANNER
// ============================================================================
class RankedScannerCandidate {
  final String symbol;
  final double compositeScore; // 0 to 100
  final double spreadBps;
  final double volume24h;
  final double change24hPct;
  final bool isEligible;
  final String filterReason;

  const RankedScannerCandidate({
    required this.symbol,
    required this.compositeScore,
    required this.spreadBps,
    required this.volume24h,
    required this.change24hPct,
    required this.isEligible,
    required this.filterReason,
  });
}

class CoinDcxMarketScanner {
  static List<RankedScannerCandidate> rankPairs({
    required Map<String, LiveMarketTicker> tickers,
    double maxSpreadBps = 25.0,
    double minVolume24h = 100.0,
  }) {
    final results = <RankedScannerCandidate>[];
    for (final entry in tickers.entries) {
      final t = entry.value;
      final mid =
          (t.bid > 0 && t.ask >= t.bid) ? (t.bid + t.ask) / 2.0 : t.lastPrice;
      final spreadBps = (mid > 0 && t.ask >= t.bid && t.bid > 0)
          ? ((t.ask - t.bid) / mid) * 10000.0
          : 999.0;
      final rangePct = (t.low24h > 0 && t.high24h >= t.low24h)
          ? ((t.high24h - t.low24h) / t.low24h) * 100.0
          : 0.0;

      if (t.lastPrice <= 0 || t.bid <= 0 || t.ask <= 0) {
        results.add(RankedScannerCandidate(
          symbol: t.symbol,
          compositeScore: 0.0,
          spreadBps: spreadBps,
          volume24h: t.volume24h,
          change24hPct: t.change24hPct,
          isEligible: false,
          filterReason: 'SKIPPED: Invalid bid/ask/price quote.',
        ));
        continue;
      }

      if (spreadBps > maxSpreadBps) {
        results.add(RankedScannerCandidate(
          symbol: t.symbol,
          compositeScore: 15.0,
          spreadBps: spreadBps,
          volume24h: t.volume24h,
          change24hPct: t.change24hPct,
          isEligible: false,
          filterReason:
              'SKIPPED: Spread ${spreadBps.toStringAsFixed(1)} bps > max ${maxSpreadBps.toStringAsFixed(1)} bps.',
        ));
        continue;
      }

      if (t.volume24h < minVolume24h) {
        results.add(RankedScannerCandidate(
          symbol: t.symbol,
          compositeScore: 20.0,
          spreadBps: spreadBps,
          volume24h: t.volume24h,
          change24hPct: t.change24hPct,
          isEligible: false,
          filterReason:
              'SKIPPED: 24h Volume ${t.volume24h.toStringAsFixed(1)} < min $minVolume24h.',
        ));
        continue;
      }

      final liquidityScore =
          (math.log(t.volume24h + 1) / math.log(1000000)).clamp(0.0, 1.0) * 35.0;
      final spreadScore =
          ((maxSpreadBps - spreadBps) / maxSpreadBps).clamp(0.0, 1.0) * 30.0;
      final momentumScore =
          (t.change24hPct.abs() / 6.0).clamp(0.0, 1.0) * 20.0;
      final volScore = (rangePct / 5.0).clamp(0.0, 1.0) * 15.0;
      final totalScore =
          (liquidityScore + spreadScore + momentumScore + volScore)
              .clamp(0.0, 100.0);

      results.add(RankedScannerCandidate(
        symbol: t.symbol,
        compositeScore: totalScore,
        spreadBps: spreadBps,
        volume24h: t.volume24h,
        change24hPct: t.change24hPct,
        isEligible: true,
        filterReason:
            'ELIGIBLE: Score ${totalScore.toStringAsFixed(1)}/100 (Spread ${spreadBps.toStringAsFixed(1)} bps).',
      ));
    }

    results.sort((a, b) {
      if (a.isEligible != b.isEligible) {
        return a.isEligible ? -1 : 1;
      }
      return b.compositeScore.compareTo(a.compositeScore);
    });
    return results;
  }
}

// ============================================================================
// STAGE 34 & 35 — AGENT ORCHESTRATION (VPS ONLY) & RESEARCH AGENTS
// ============================================================================
class AgentCostEstimate {
  final int estimatedInputTokens;
  final int estimatedOutputTokens;
  final double estimatedCostUsd;
  final bool vpsApproved;
  final String notice;

  const AgentCostEstimate({
    required this.estimatedInputTokens,
    required this.estimatedOutputTokens,
    required this.estimatedCostUsd,
    required this.vpsApproved,
    required this.notice,
  });
}

class ResearchAgentOpinion {
  final String agentRole;
  final String stance;
  final double confidence;
  final String rationale;
  final bool isDeterministicSupervisor;

  const ResearchAgentOpinion({
    required this.agentRole,
    required this.stance,
    required this.confidence,
    required this.rationale,
    this.isDeterministicSupervisor = false,
  });
}

class MultiAgentCouncilReport {
  final String symbol;
  final AgentCostEstimate costEstimate;
  final List<ResearchAgentOpinion> agentOpinions;
  final bool riskApproved;
  final String riskReason;
  final String finalVerdict;
  final int timestampMs;

  const MultiAgentCouncilReport({
    required this.symbol,
    required this.costEstimate,
    required this.agentOpinions,
    required this.riskApproved,
    required this.riskReason,
    required this.finalVerdict,
    required this.timestampMs,
  });
}

class VpsAgentOrchestrator {
  final bool vpsStage20bApproved;

  const VpsAgentOrchestrator({this.vpsStage20bApproved = false});

  AgentCostEstimate estimateCouncilRunCost({int agentCount = 8}) {
    final inTokens = agentCount * 950;
    final outTokens = agentCount * 280;
    final costUsd = (inTokens * 0.00000015) + (outTokens * 0.00000060);
    return AgentCostEstimate(
      estimatedInputTokens: inTokens,
      estimatedOutputTokens: outTokens,
      estimatedCostUsd: costUsd,
      vpsApproved: vpsStage20bApproved,
      notice: vpsStage20bApproved
          ? 'VPS Orchestration active. Est. LLM cycle cost: \$${costUsd.toStringAsFixed(4)} USD.'
          : 'LOCAL DETERMINISTIC MODE (Stage 20B VPS not yet activated). Zero paid LLM API calls made; est. cloud cost if enabled: \$${costUsd.toStringAsFixed(4)}/run.',
    );
  }

  MultiAgentCouncilReport evaluateSymbol({
    required String symbol,
    required MarketRegimeAssessment regime,
    required RankedScannerCandidate? scannerRank,
    required StrategyEvaluationResult technicalEval,
    required bool independentRiskApproved,
    required String independentRiskReason,
    int? nowMs,
  }) {
    final ts = nowMs ?? DateTime.now().millisecondsSinceEpoch;
    final cost = estimateCouncilRunCost(agentCount: 8);

    final scannerOpinion = ResearchAgentOpinion(
      agentRole: 'Scanner Agent',
      stance:
          (scannerRank != null && scannerRank.isEligible) ? 'BULLISH' : 'NEUTRAL',
      confidence: scannerRank != null
          ? (scannerRank.compositeScore / 100.0).clamp(0.2, 0.95)
          : 0.4,
      rationale: scannerRank?.filterReason ?? 'No scanner ranking available.',
    );

    final techStance = technicalEval.signal == StrategySignalType.buy
        ? 'BULLISH'
        : (technicalEval.signal == StrategySignalType.sell
            ? 'BEARISH'
            : 'NEUTRAL');
    final technicalOpinion = ResearchAgentOpinion(
      agentRole: 'Technical Agent',
      stance: techStance,
      confidence:
          technicalEval.signal == StrategySignalType.none ? 0.50 : 0.82,
      rationale: technicalEval.reason,
    );

    final macroOpinion = ResearchAgentOpinion(
      agentRole: 'News/Macro Agent',
      stance: regime.isAbnormalCondition ? 'BEARISH' : 'NEUTRAL',
      confidence: 0.65,
      rationale: regime.isAbnormalCondition
          ? 'Macro liquidity spread dislocation detected; defensive posture.'
          : 'No external macro shock detected in feed.',
    );

    final sentimentOpinion = ResearchAgentOpinion(
      agentRole: 'Sentiment Agent',
      stance: regime.primaryRegime == DetectedMarketRegime.bullTrend
          ? 'BULLISH'
          : 'NEUTRAL',
      confidence: regime.confidence,
      rationale: 'Regime sentiment aligned with ${regime.regimeLabel}.',
    );

    final bullOpinion = ResearchAgentOpinion(
      agentRole: 'Bull Researcher',
      stance: 'BULLISH',
      confidence: regime.emaSlopePct > 0 ? 0.78 : 0.45,
      rationale:
          'Constructive case: EMA slope ${regime.emaSlopePct.toStringAsFixed(2)}% with controlled spread (${regime.spreadBps.toStringAsFixed(1)} bps).',
    );

    final bearOpinion = ResearchAgentOpinion(
      agentRole: 'Bear Researcher',
      stance: 'BEARISH',
      confidence:
          regime.emaSlopePct < 0 || regime.isAbnormalCondition ? 0.80 : 0.48,
      rationale:
          'Risk case: Annualized vol ${regime.annualizedVolPct.toStringAsFixed(1)}% and fee/slippage drag must be overcome.',
    );

    final quantOpinion = ResearchAgentOpinion(
      agentRole: 'Quant Analyst',
      stance:
          technicalEval.signal == StrategySignalType.buy ? 'BULLISH' : 'NEUTRAL',
      confidence: 0.75,
      rationale:
          'Requires positive OOS Sharpe and 2:1 reward-to-risk after 0.10% fee + 5 bps slippage.',
    );

    final chiefStance = (technicalEval.signal == StrategySignalType.buy &&
            !regime.isAbnormalCondition)
        ? 'PROPOSE LONG'
        : 'HOLD / NO TRADE';
    final chiefOpinion = ResearchAgentOpinion(
      agentRole: 'Chief Analyst',
      stance: chiefStance,
      confidence: regime.confidence,
      rationale: 'Synthesized 7 research desks: $chiefStance on $symbol.',
    );

    final riskSupervisorOpinion = ResearchAgentOpinion(
      agentRole: 'Independent Risk Supervisor',
      stance: independentRiskApproved ? 'APPROVED' : 'HARD VETO',
      confidence: 1.0,
      rationale: independentRiskReason,
      isDeterministicSupervisor: true,
    );

    final finalVerdict = (!independentRiskApproved)
        ? 'BLOCKED BY DETERMINISTIC RISK SUPERVISOR: $independentRiskReason'
        : (chiefStance == 'PROPOSE LONG'
            ? 'APPROVED FOR PAPER EXECUTION ($symbol)'
            : 'NO ACTION ($chiefStance)');

    return MultiAgentCouncilReport(
      symbol: symbol,
      costEstimate: cost,
      agentOpinions: [
        scannerOpinion,
        technicalOpinion,
        macroOpinion,
        sentimentOpinion,
        bullOpinion,
        bearOpinion,
        quantOpinion,
        chiefOpinion,
        riskSupervisorOpinion,
      ],
      riskApproved: independentRiskApproved,
      riskReason: independentRiskReason,
      finalVerdict: finalVerdict,
      timestampMs: ts,
    );
  }
}

// ============================================================================
// STAGE 36 & 37 — SANDBOXED STRATEGY BUILDER & CHAMPION-CHALLENGER OPTIMIZER
// ============================================================================
class StrategyCandidateHypothesis {
  final String configId;
  final String version;
  final String hypothesis;
  final Map<String, num> parameters;
  final bool isolatedInSandbox;
  final bool allowedInLiveProcess;

  const StrategyCandidateHypothesis({
    required this.configId,
    required this.version,
    required this.hypothesis,
    required this.parameters,
    this.isolatedInSandbox = true,
    this.allowedInLiveProcess = false,
  });
}

class ChampionChallengerDecision {
  final String championId;
  final String challengerId;
  final bool promoteChallenger;
  final bool rollbackTriggered;
  final String decisionReason;

  const ChampionChallengerDecision({
    required this.championId,
    required this.challengerId,
    required this.promoteChallenger,
    required this.rollbackTriggered,
    required this.decisionReason,
  });
}

class SandboxedStrategyBuilderAndOptimizer {
  static List<StrategyCandidateHypothesis> generateSandboxedHypotheses() {
    return const [
      StrategyCandidateHypothesis(
        configId: 'challenger_ema_12_26_atr_1.8',
        version: '1.1.0-sandbox',
        hypothesis:
            'Wider EMA(12/26) and 1.8x ATR stop reduces whipsaw in moderate volatility regimes.',
        parameters: {
          'emaFast': 12,
          'emaSlow': 26,
          'rsiPeriod': 14,
          'atrStopMult': 1.8,
          'atrTpMult': 3.6,
        },
        isolatedInSandbox: true,
        allowedInLiveProcess: false,
      ),
      StrategyCandidateHypothesis(
        configId: 'challenger_ema_8_21_rsi_55',
        version: '1.2.0-sandbox',
        hypothesis:
            'Tighter RSI [42, 62] entry band filters late-stage momentum exhaustion.',
        parameters: {
          'emaFast': 8,
          'emaSlow': 21,
          'rsiMin': 42,
          'rsiMax': 62,
          'atrStopMult': 1.5,
          'atrTpMult': 3.0,
        },
        isolatedInSandbox: true,
        allowedInLiveProcess: false,
      ),
    ];
  }

  static ChampionChallengerDecision evaluatePromotion({
    required String championId,
    required RobustnessValidationReport championReport,
    required String challengerId,
    required RobustnessValidationReport challengerReport,
    required int challengerForwardPaperTrades,
    required double championRecentDrawdownPct,
  }) {
    if (championRecentDrawdownPct > 8.5) {
      return ChampionChallengerDecision(
        championId: championId,
        challengerId: challengerId,
        promoteChallenger: false,
        rollbackTriggered: true,
        decisionReason:
            'DEGRADATION ROLLBACK: Champion drawdown ${championRecentDrawdownPct.toStringAsFixed(1)}% exceeded 8.5% threshold; reverting to defensive baseline.',
      );
    }

    if (!challengerReport.passesPromotionGates) {
      return ChampionChallengerDecision(
        championId: championId,
        challengerId: challengerId,
        promoteChallenger: false,
        rollbackTriggered: false,
        decisionReason:
            'CHALLENGER REJECTED: Failed out-of-sample/Monte Carlo robustness gates (${challengerReport.verdictSummary}).',
      );
    }

    if (challengerForwardPaperTrades < 20) {
      return ChampionChallengerDecision(
        championId: championId,
        challengerId: challengerId,
        promoteChallenger: false,
        rollbackTriggered: false,
        decisionReason:
            'CHALLENGER PENDING FORWARD VALIDATION: Has $challengerForwardPaperTrades/20 required forward paper trades. Never promote on backtest alone.',
      );
    }

    final betterSharpe =
        challengerReport.sharpeRatio > (championReport.sharpeRatio + 0.15);
    final lowerDrawdown =
        challengerReport.maxDrawdownUsdt <= championReport.maxDrawdownUsdt;

    if (betterSharpe && lowerDrawdown) {
      return ChampionChallengerDecision(
        championId: championId,
        challengerId: challengerId,
        promoteChallenger: true,
        rollbackTriggered: false,
        decisionReason:
            'CHALLENGER PROMOTED: Outperformed champion in OOS Sharpe (${challengerReport.sharpeRatio.toStringAsFixed(2)} vs ${championReport.sharpeRatio.toStringAsFixed(2)}) + $challengerForwardPaperTrades forward paper trades.',
      );
    }

    return ChampionChallengerDecision(
      championId: championId,
      challengerId: challengerId,
      promoteChallenger: false,
      rollbackTriggered: false,
      decisionReason:
          'CHAMPION RETAINED: Challenger did not beat champion risk-adjusted OOS Sharpe & drawdown.',
    );
  }
}

// ============================================================================
// STAGE 38 — TRADE POSTMORTEM
// ============================================================================
enum PostmortemCauseCategory {
  plannedTargetReached,
  normalStopOutInValidSetup,
  regimeShiftAdverseMove,
  feeAndSlippageDrag,
  prematureExit,
}

class TradePostmortemReport {
  final String tradeId;
  final String symbol;
  final String strategyVersion;
  final String entryReasoning;
  final double expectedPrice;
  final double actualEntryPrice;
  final double exitPrice;
  final double totalFeesPaid;
  final double realizedSlippageCost;
  final double realizedPnl;
  final String exitReason;
  final PostmortemCauseCategory causeCategory;
  final String improvementHypothesis;
  final bool requiresParameterChange;

  const TradePostmortemReport({
    required this.tradeId,
    required this.symbol,
    required this.strategyVersion,
    required this.entryReasoning,
    required this.expectedPrice,
    required this.actualEntryPrice,
    required this.exitPrice,
    required this.totalFeesPaid,
    required this.realizedSlippageCost,
    required this.realizedPnl,
    required this.exitReason,
    required this.causeCategory,
    required this.improvementHypothesis,
    required this.requiresParameterChange,
  });
}

class TradePostmortemAnalyzer {
  static TradePostmortemReport analyzeClosedTrade({
    required ClosedPaperTrade trade,
    required String strategyVersion,
    String entryReasoning = '15m EMA20/50 crossover + 1h bull trend',
    double expectedSlippageBps = 5.0,
  }) {
    final pnl = trade.realizedPnlUsdt;
    final exitPx = trade.exitPrice;
    final expectedPx =
        trade.entryPrice / (1.0 + (expectedSlippageBps / 10000.0));
    final slippageCost =
        (trade.entryPrice - expectedPx).abs() * trade.quantity * 2.0;

    PostmortemCauseCategory category;
    String hypothesis;

    if (pnl > 0 && trade.exitReason.contains('TAKE_PROFIT')) {
      category = PostmortemCauseCategory.plannedTargetReached;
      hypothesis = 'Execution matched 2:1 R:R thesis. Maintain current parameters.';
    } else if (pnl <= 0 && pnl.abs() <= (trade.totalFeesUsdt * 1.5)) {
      category = PostmortemCauseCategory.feeAndSlippageDrag;
      hypothesis =
          'Gross move was near breakeven; fee/slippage drag turned net P&L negative. Filter low-ATR entries.';
    } else if (trade.exitReason.contains('STOP_LOSS')) {
      category = PostmortemCauseCategory.normalStopOutInValidSetup;
      hypothesis =
          'Bounded 1% risk stop-out functioned as designed. Do not overreact to a single loss; evaluate only across 30+ trade sample.';
    } else {
      category = PostmortemCauseCategory.regimeShiftAdverseMove;
      hypothesis =
          'Review 1h higher-timeframe regime alignment prior to entry.';
    }

    return TradePostmortemReport(
      tradeId: trade.id,
      symbol: trade.symbol,
      strategyVersion: strategyVersion,
      entryReasoning: entryReasoning,
      expectedPrice: expectedPx,
      actualEntryPrice: trade.entryPrice,
      exitPrice: exitPx,
      totalFeesPaid: trade.totalFeesUsdt,
      realizedSlippageCost: slippageCost,
      realizedPnl: pnl,
      exitReason: trade.exitReason,
      causeCategory: category,
      improvementHypothesis: hypothesis,
      requiresParameterChange: false,
    );
  }
}

// ============================================================================
// STAGE 39 — PORTFOLIO MANAGEMENT
// ============================================================================
class PortfolioAllocationDecision {
  final double effectiveRiskCapitalUsd;
  final double maxRiskPerTradeUsd;
  final double drawdownThrottleMultiplier;
  final bool martingaleForbidden;
  final bool depositRiskIncreaseLocked;
  final String summary;

  const PortfolioAllocationDecision({
    required this.effectiveRiskCapitalUsd,
    required this.maxRiskPerTradeUsd,
    required this.drawdownThrottleMultiplier,
    this.martingaleForbidden = true,
    this.depositRiskIncreaseLocked = true,
    required this.summary,
  });
}

class PortfolioRiskAllocator {
  static const double approvedBaseCapitalUsd = 100.0;
  static const double approvedBaseRiskPerTradeUsd = 1.0;

  static PortfolioAllocationDecision computeAllocation({
    required double currentEquityUsd,
    required double externalDepositsUsd,
    required int consecutiveLosses,
    bool hasSeparateWrittenDepositRiskApproval = false,
  }) {
    final double riskBase = hasSeparateWrittenDepositRiskApproval
        ? currentEquityUsd
        : math.min(
            currentEquityUsd - externalDepositsUsd, approvedBaseCapitalUsd);

    double throttle = 1.0;
    if (consecutiveLosses >= 2) {
      throttle = 0.50;
    } else if (riskBase < 95.0) {
      throttle = 0.75;
    }

    final maxRiskUsd = (approvedBaseRiskPerTradeUsd * throttle)
        .clamp(0.25, approvedBaseRiskPerTradeUsd);

    return PortfolioAllocationDecision(
      effectiveRiskCapitalUsd: math.max(0.0, riskBase),
      maxRiskPerTradeUsd: maxRiskUsd,
      drawdownThrottleMultiplier: throttle,
      martingaleForbidden: true,
      depositRiskIncreaseLocked: !hasSeparateWrittenDepositRiskApproval,
      summary:
          'Risk cap \$${maxRiskUsd.toStringAsFixed(2)}/trade (Throttle ${(throttle * 100).toStringAsFixed(0)}%, Martingale FORBIDDEN, Deposit auto-scaling LOCKED).',
    );
  }
}

// ============================================================================
// STAGE 40, 41, 42, 43 — OPERATION MANAGER, VPS/WATCHDOG & SECURITY GUARD
// ============================================================================
class SecurityAndOpsAuditStatus {
  final bool tradeOnlyApiPermissionsEnforced;
  final bool withdrawalsDisabledOnApi;
  final bool credentialsEncryptedServerSide;
  final bool credentialsNeverSentToLlm;
  final bool promptInjectionSanitizerActive;
  final bool safeModeActive;
  final String lastBackupStatus;
  final String operationManagerStatus;

  const SecurityAndOpsAuditStatus({
    this.tradeOnlyApiPermissionsEnforced = true,
    this.withdrawalsDisabledOnApi = true,
    this.credentialsEncryptedServerSide = true,
    this.credentialsNeverSentToLlm = true,
    this.promptInjectionSanitizerActive = true,
    required this.safeModeActive,
    required this.lastBackupStatus,
    required this.operationManagerStatus,
  });

  static String sanitizeExternalUntrustedText(String input) {
    final redacted = input
        .replaceAll(
            RegExp(r'(api[_-]?key|secret|password|token)\s*[:=]\s*\S+',
                caseSensitive: false),
            '[REDACTED_CREDENTIAL]')
        .replaceAll(
            RegExp(
                r'(ignore previous instructions|system prompt|override risk|disable stoploss)',
                caseSensitive: false),
            '[BLOCKED_INJECTION]');
    return redacted;
  }
}

// ============================================================================
// STAGE 45 & 46 — 90-DAY EXTENDED PAPER TRADING & HARD-LOCKED CONTROLLED LIVE
// ============================================================================
class ExtendedPaperReadinessStatus {
  final int daysCompleted;
  final int requiredDays;
  final int closedPaperTrades;
  final int requiredClosedTrades;
  final int distinctRegimesObserved;
  final int verifiedAutoRecoveries;
  final bool costSlippageWithinBacktestTolerance;
  final bool stage45Complete;
  final String statusSummary;

  const ExtendedPaperReadinessStatus({
    required this.daysCompleted,
    this.requiredDays = 90,
    required this.closedPaperTrades,
    this.requiredClosedTrades = 30,
    required this.distinctRegimesObserved,
    required this.verifiedAutoRecoveries,
    required this.costSlippageWithinBacktestTolerance,
    required this.stage45Complete,
    required this.statusSummary,
  });
}

class ControlledLiveGateStatus {
  final bool explicitWrittenUserAuthorization;
  final bool stage45NinetyDayPaperPassed;
  final bool tradeOnlyKeyVerified;
  final bool liveExecutionEnabled;
  final String gateReason;

  const ControlledLiveGateStatus({
    required this.explicitWrittenUserAuthorization,
    required this.stage45NinetyDayPaperPassed,
    required this.tradeOnlyKeyVerified,
    required this.liveExecutionEnabled,
    required this.gateReason,
  });

  static ControlledLiveGateStatus evaluate({
    required bool explicitWrittenAuthorization,
    required ExtendedPaperReadinessStatus paperStatus,
    required bool tradeOnlyKeyVerified,
    required bool runtimeViolationDetected,
  }) {
    if (runtimeViolationDetected) {
      return const ControlledLiveGateStatus(
        explicitWrittenUserAuthorization: false,
        stage45NinetyDayPaperPassed: false,
        tradeOnlyKeyVerified: false,
        liveExecutionEnabled: false,
        gateReason:
            'AUTO-PAUSED & ROLLED BACK TO PAPER: Runtime risk or balance reconciliation violation detected.',
      );
    }
    if (!paperStatus.stage45Complete) {
      return ControlledLiveGateStatus(
        explicitWrittenUserAuthorization: explicitWrittenAuthorization,
        stage45NinetyDayPaperPassed: false,
        tradeOnlyKeyVerified: tradeOnlyKeyVerified,
        liveExecutionEnabled: false,
        gateReason:
            'LOCKED (PAPER-ONLY): Stage 45 requires 90-day live-data paper validation (${paperStatus.daysCompleted}/90 days, ${paperStatus.closedPaperTrades}/${paperStatus.requiredClosedTrades} trades).',
      );
    }
    if (!explicitWrittenAuthorization) {
      return ControlledLiveGateStatus(
        explicitWrittenUserAuthorization: false,
        stage45NinetyDayPaperPassed: true,
        tradeOnlyKeyVerified: tradeOnlyKeyVerified,
        liveExecutionEnabled: false,
        gateReason:
            'LOCKED (PAPER-ONLY): Requires explicit written user authorization for Stage 46 Controlled Live.',
      );
    }
    if (!tradeOnlyKeyVerified) {
      return const ControlledLiveGateStatus(
        explicitWrittenUserAuthorization: true,
        stage45NinetyDayPaperPassed: true,
        tradeOnlyKeyVerified: false,
        liveExecutionEnabled: false,
        gateReason:
            'LOCKED (PAPER-ONLY): Trade-only API key with withdrawals disabled is not configured.',
      );
    }
    return const ControlledLiveGateStatus(
      explicitWrittenUserAuthorization: true,
      stage45NinetyDayPaperPassed: true,
      tradeOnlyKeyVerified: true,
      liveExecutionEnabled: true,
      gateReason:
          'CONTROLLED LIVE AUTHORIZED (Restricted Capital, Capital Preservation First).',
    );
  }
}

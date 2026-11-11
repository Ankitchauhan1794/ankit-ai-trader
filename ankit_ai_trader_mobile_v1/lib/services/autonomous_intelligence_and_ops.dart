class ResearchAgentOpinion {
  final String agentRole;
  final String modelName;
  final String summaryVerdict;
  final bool recommendsAction;
  final bool canOverrideRiskSupervisor;

  const ResearchAgentOpinion({
    required this.agentRole,
    required this.modelName,
    required this.summaryVerdict,
    required this.recommendsAction,
    this.canOverrideRiskSupervisor = false,
  });
}

class MultiAgentCouncilReport {
  final int timestampMs;
  final List<ResearchAgentOpinion> opinions;
  final String consensusSummary;
  final bool deterministicRiskSupervisorHasFinalVeto;

  const MultiAgentCouncilReport({
    required this.timestampMs,
    required this.opinions,
    required this.consensusSummary,
    this.deterministicRiskSupervisorHasFinalVeto = true,
  });
}

class AgentCostEstimate {
  final double estimatedDailyCostUsd;
  final double monthlyBudgetCapUsd;
  final bool withinBudget;
  final String modeDescription;

  const AgentCostEstimate({
    required this.estimatedDailyCostUsd,
    required this.monthlyBudgetCapUsd,
    required this.withinBudget,
    required this.modeDescription,
  });
}

class VpsAgentOrchestrator {
  final bool vpsStage20bApproved;

  const VpsAgentOrchestrator({this.vpsStage20bApproved = false});

  AgentCostEstimate estimateCouncilRunCost({int runsPerDay = 4}) {
    final cost = vpsStage20bApproved ? (runsPerDay * 0.015) : 0.0;
    return AgentCostEstimate(
      estimatedDailyCostUsd: cost,
      monthlyBudgetCapUsd: 5.0,
      withinBudget: cost * 30 <= 5.0,
      modeDescription: vpsStage20bApproved
          ? 'VPS Multi-Agent Council Active'
          : 'Local Android Mode (VPS Not Configured — \$0.00 LLM Cost)',
    );
  }

  MultiAgentCouncilReport runLocalAdvisoryCouncil({
    required String symbol,
    required String regimeLabel,
    required int nowMs,
  }) {
    return MultiAgentCouncilReport(
      timestampMs: nowMs,
      opinions: [
        ResearchAgentOpinion(
          agentRole: 'Market Regime Analyst',
          modelName: 'Local-Deterministic-Regime-v1',
          summaryVerdict: '$symbol regime is $regimeLabel',
          recommendsAction: regimeLabel == 'TRENDING_BULL',
        ),
        const ResearchAgentOpinion(
          agentRole: 'Risk & Skeptic Auditor',
          modelName: 'Local-Deterministic-Risk-v1',
          summaryVerdict: 'Enforce 1% (\$1.00) risk cap and 1 max open position.',
          recommendsAction: true,
        ),
      ],
      consensusSummary:
          'Advisory council evaluated $symbol ($regimeLabel). Deterministic Risk Supervisor retains absolute veto.',
    );
  }
}

class StrategyCandidateHypothesis {
  final String candidateId;
  final String description;
  final Map<String, num> parameters;
  final bool sandboxOnly;
  final bool autoLiveDeployForbidden;

  const StrategyCandidateHypothesis({
    required this.candidateId,
    required this.description,
    required this.parameters,
    this.sandboxOnly = true,
    this.autoLiveDeployForbidden = true,
  });
}

class SandboxedStrategyBuilderAndOptimizer {
  static List<StrategyCandidateHypothesis> generateSandboxedHypotheses() {
    return const [
      StrategyCandidateHypothesis(
        candidateId: 'CAND_EMA_20_50_RSI_52_66',
        description: 'Tighter RSI [52-66] filter with 1.5x ATR SL / 3.0x ATR TP',
        parameters: {'emaFast': 20, 'emaSlow': 50, 'rsiMin': 52, 'rsiMax': 66},
      ),
      StrategyCandidateHypothesis(
        candidateId: 'CAND_EMA_25_60_RSI_50_65',
        description: 'Smoother EMA 25/60 trend filter for lower turnover',
        parameters: {'emaFast': 25, 'emaSlow': 60, 'rsiMin': 50, 'rsiMax': 65},
      ),
    ];
  }
}

class SecurityAndOpsAuditStatus {
  static String sanitizeUntrustedText(String rawInput) {
    var out = rawInput;
    final secretPatterns = [
      RegExp(r'(api[_-]?key|secret|token|password)\s*[:=]\s*\S+', caseSensitive: false),
      RegExp(r'ignore\s+previous\s+instructions', caseSensitive: false),
      RegExp(r'override\s+risk\s+supervisor', caseSensitive: false),
      RegExp(r'enable\s+live\s+trading', caseSensitive: false),
    ];
    for (final p in secretPatterns) {
      out = out.replaceAll(p, '[REDACTED_BY_SECURITY_GUARD]');
    }
    return out;
  }
}

class ExtendedPaperReadinessStatus {
  final int daysCompleted;
  final int closedPaperTrades;
  final int distinctRegimesObserved;
  final int verifiedAutoRecoveries;
  final bool costSlippageWithinBacktestTolerance;
  final bool stage45Complete;
  final String statusSummary;

  const ExtendedPaperReadinessStatus({
    required this.daysCompleted,
    required this.closedPaperTrades,
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
    required bool tradeOnlyApiKeyWithNoWithdrawalVerified,
  }) {
    final allowed = explicitWrittenAuthorization &&
        paperStatus.stage45Complete &&
        tradeOnlyApiKeyWithNoWithdrawalVerified;
    return ControlledLiveGateStatus(
      explicitWrittenUserAuthorization: explicitWrittenAuthorization,
      stage45NinetyDayPaperPassed: paperStatus.stage45Complete,
      tradeOnlyKeyVerified: tradeOnlyApiKeyWithNoWithdrawalVerified,
      liveExecutionEnabled: false, // Hard-locked to Paper Mode per project rules
      gateReason: allowed
          ? 'Stage 45 passed, but Live Mode remains hard-locked to Paper Mode per safety policy.'
          : 'HARD-LOCKED TO PAPER MODE: Stage 45 (90-day paper validation) and explicit written user authorization required.',
    );
  }
}

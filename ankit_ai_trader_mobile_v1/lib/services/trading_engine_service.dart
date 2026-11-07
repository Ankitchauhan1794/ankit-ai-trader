import 'persistence_db.dart';

class TradingEngineService {
  static final TradingEngineService _instance = TradingEngineService._internal();
  factory TradingEngineService() => _instance;
  TradingEngineService._internal();

  String currentState = 'STOPPED';
  String? pauseReason;
  int orderSeq = 0;
  bool autoResumeEnabled = false;

  bool shouldRestart(String state, int lastHeartbeatMs, int nowMs) {
    if (state != 'RUNNING') return false;
    return (nowMs - lastHeartbeatMs) > (10 * 60 * 1000);
  }

  Future<void> setEngineState(String state, {String? reason}) async {
    currentState = state;
    pauseReason = reason;
    await PersistenceDb.saveEngineState(state, reason, orderSeq);
    await PersistenceDb.logEvent('STATE_CHANGE', 'State: $state, Reason: ${reason ?? 'none'}');
  }

  Future<void> handleNetworkRecovery(bool isFreshDataValid) async {
    if (autoResumeEnabled && currentState == 'PAUSED' && (pauseReason == 'network' || pauseReason == 'stale_data')) {
      if (isFreshDataValid) {
        await setEngineState('RUNNING', reason: null);
      }
    }
  }
}

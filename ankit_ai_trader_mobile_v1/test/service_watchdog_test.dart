import 'package:flutter_test/flutter_test.dart';
import 'package:ankit_ai_trader/services/trading_engine_service.dart';

void main() {
  group('Service Watchdog & Engine Tests', () {
    test('shouldRestart logic test', () {
      final engine = TradingEngineService();
      final now = 1000000000;
      
      // RUNNING and stale heartbeat (> 10 mins)
      expect(engine.shouldRestart('RUNNING', now - 11 * 60 * 1000, now), true);

      // RUNNING but fresh heartbeat (< 10 mins)
      expect(engine.shouldRestart('RUNNING', now - 5 * 60 * 1000, now), false);

      // STOPPED or PAUSED should never restart via watchdog
      expect(engine.shouldRestart('STOPPED', now - 15 * 60 * 1000, now), false);
      expect(engine.shouldRestart('PAUSED', now - 15 * 60 * 1000, now), false);
    });

    test('Auto-resume toggle and pause reason rules', () async {
      final engine = TradingEngineService();
      engine.autoResumeEnabled = false;
      engine.currentState = 'PAUSED';
      engine.pauseReason = 'network';

      // With autoResumeEnabled = false, should not resume
      await engine.handleNetworkRecovery(true);
      expect(engine.currentState, 'PAUSED');

      // With autoResumeEnabled = true and valid fresh data, should resume
      engine.autoResumeEnabled = true;
      await engine.handleNetworkRecovery(true);
      expect(engine.currentState, 'RUNNING');
    });
  });
}

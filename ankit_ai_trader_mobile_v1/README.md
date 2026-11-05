# Ankit AI Trader — Phase 1 Final Candidate (Simulated Paper-Trading Engine)

## Complete File Tree

```text
.github/
  workflows/
    build-apk.yml
ankit_ai_trader_mobile_v1/
  README.md
  REVIEW_SUMMARY.txt
  TEST_RESULTS.txt
  pubspec.yaml
  analysis_options.yaml
  .github/
    workflows/
      build-apk.yml
  android/
    build.gradle
    gradle.properties
    settings.gradle
    gradle/
      wrapper/
        gradle-wrapper.properties
    app/
      build.gradle
      src/
        main/
          AndroidManifest.xml
          kotlin/
            com/
              ankit/
                aitrader/
                  MainActivity.kt
                  TradingForegroundService.kt
  lib/
    main.dart
    models/
      trading_models.dart
    services/
      authoritative_engine.dart
      coindcx_market_service.dart
      indicator_engine.dart
      paper_broker.dart
      persistence_db.dart
      risk_manager.dart
      strategy_engine.dart
      trading_coordinator.dart
  test/
    phase1_trading_test.dart
    widget_test.dart
```

## Architecture & Safety Guarantees

1. **Single Authoritative Trading Engine (`AuthoritativeTradingEngine`)**:
   - Hosted exclusively inside `TradingForegroundService`'s headless background Dart isolate (`backgroundServiceMain`).
   - Protected by a persistent SQLite execution lease table (`execution_locks`) and idempotency table (`processed_signal_keys`).
   - `TradingCoordinator` in the UI isolate has zero trade-execution timers and never runs `processClosedCandleStream`; it only dispatches commands (`START`, `PAUSE`, `STOP`, `RESET`, `REFRESH_QUOTES`) over `EngineCommandBridge` and reads committed SQLite snapshots.
   - `MainActivity.kt` waits for both Android `TradingForegroundService.isRunning` and Dart `acknowledgeEngineInitialized` before reporting the service as active.

2. **First-Start Historical Warm-Up Without Historical Trades**:
   - When `lastProcessedCandleCloseMs[symbol]` is null on a fresh account, historical candles are used solely to warm up EMA 20, EMA 50, RSI 14, and ATR 14.
   - A checkpoint is committed at the latest closed 15m candle without generating historical trades or pending signals.
   - Only candles closing after the user's manual `START` command are evaluated for trade signals.

3. **Persistent UTC-Day Baseline & Daily Loss Management ($2 Limit)**:
   - At the first valid market valuation of each UTC day (`YYYY-MM-DD`), `PaperBroker.ensureUtcDayBaseline` establishes and persists `startOfDayEquityUsdt` in SQLite without resetting the $100 account or closing open positions.
   - Daily P&L is computed against that baseline (`accountEquity - startOfDayEquityUsdt`), incorporating both realized P&L (with fees) and unrealized P&L.
   - When daily loss reaches `-$2.00`, new entries are locked (`BotEngineState.lockedDailyLossLimit`), while the authoritative engine stays alive whenever `openPositions.isNotEmpty` to continue managing existing positions against Stop-Loss and Take-Profit.

4. **$90 Maximum Drawdown Floor & Emergency Liquidation**:
   - When account equity reaches or falls below `$90.00`, `maxDrawdownLocked` is set permanently and pending signals are cleared.
   - Open positions are liquidated using valid market prices. If a valid market quote is unavailable, the engine never invents a price—it locks the account and sets `pendingEmergencyLiquidation = true` until a valid quote arrives.

5. **Android Battery Management & OEM Restrictions**:
   - `TradingForegroundService.kt` acquires a bounded 15-minute `PARTIAL_WAKE_LOCK` renewed on each 60-second heartbeat and released cleanly in `onDestroy()`.
   - Because Android OEMs (Xiaomi MIUI, Vivo, Oppo, Samsung) may still throttle background network sockets under extreme battery saver policies, 24/7 uninterrupted uptime is never guaranteed; users can grant unrestricted battery usage via the **BATTERY SETTINGS** button.

## Build & Verification Instructions

```bash
cd ankit_ai_trader_mobile_v1
flutter pub get
dart format .
dart format --set-exit-if-changed .
flutter analyze
flutter test
flutter build apk --release --android-skip-build-dependency-validation
```

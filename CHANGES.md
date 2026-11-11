# Ankit AI Trader — Critical Engine Startup Failure Fix & Full App Audit (`CHANGES.md`)

## 1. Root-Cause Findings (`START -> RUNNING -> STOPPED`)
1. **Compiled APK Native Channel Mismatch + Optimistic UI State Overwrite (`TradingCoordinator.startBot` & `MainActivity.kt`)**:
   - In `Ankit_AI_Trader_APK (8).zip`, the compiled `classes.dex` registered `com.ankit.aitrader/background_engine` but did not register `com.ankit.aitrader/service` (`startOrEnsureService`, `dispatchEngineCommand`, `getServiceStatus`).
   - When `START` was tapped, `TradingCoordinator.startBot()` saved `userIntention = running` to SQLite, optimistically set `engineState = BotEngineState.running` in memory only (without updating `engine_kv_state['botState']`, which remained `'stopped'`), and called `notifyListeners()`—causing the UI to briefly display `RUNNING`.
   - `ensureServiceStartedAndReady()` then threw `MissingPluginException` and returned `false`. Within 4 seconds, `_uiStateRefreshTimer` invoked `refreshStateFromDatabase(isInitialLoad: false)`, which read `snap.botState == BotEngineState.stopped` from SQLite and reverted `engineState` back to `STOPPED`.
2. **Headless `FlutterEngine` Cold-Start Race & Premature Command Drop (`TradingForegroundService.kt`)**:
   - `initBackgroundFlutterEngine` set `isDartEngineReady = true` synchronously before `backgroundServiceMain()` finished booting or registered its `MethodChannel` handler (`acknowledgeEngineInitialized`), and set `isDartEngineReady = true` inside `catch`.
   - `dispatchCommandToDartEngine` used a fixed `150ms` delay and returned `callback(true)` on `notImplemented()` and `error()`, causing `"START"` to be dropped during isolate cold-start while reporting success.
   - `MainActivity.kt` in `dispatchEngineCommand` previously triggered both `startTradingService(cmd)` (intent extra) and `dispatchCommandToDartEngine(cmd)`, dispatching duplicate concurrent commands.
3. **Periodic Timer Freeze After `waitingForFreshData` (`AuthoritativeTradingEngine._startPeriodicTimer`)**:
   - `_startPeriodicTimer()` previously checked `if (!_disposed && state == BotEngineState.running)`. If the first cycle temporarily entered `BotEngineState.waitingForFreshData`, the 15-second periodic timer stopped firing permanently and froze heartbeats.
4. **Unbatched 472-Pair Candle Scan Blocking `startEngine()` (`AuthoritativeTradingEngine.executeTradingCycle`)**:
   - `executeTradingCycle()` iterated over all `472` eligible USDT pairs sequentially (`944` HTTP candle requests) inside `startEngine()`.

## 2. Exact Fixes Implemented (Tasks 1–9)
- **`android/app/src/main/kotlin/com/ankit/aitrader/TradingForegroundService.kt`**:
  - Added `waitForServiceAndEngineReady()` and `invokeCommandWithRetry()` so `isDartEngineReady` is only set `true` upon receiving `"acknowledgeEngineInitialized"` from `backgroundServiceMain()`.
  - Explicitly invoked `GeneratedPluginRegistrant.registerWith(created)` on the headless `FlutterEngine`.
  - Eliminated false-positive `callback(true)` in `error()` and `notImplemented()`, added native error/shutdown reason tracking (`lastStartupError`, `lastShutdownReason`), and wired live notification updates and trade alert notifications.
- **`android/app/src/main/kotlin/com/ankit/aitrader/MainActivity.kt`**:
  - Updated `startOrEnsureService` to await `TradingForegroundService.waitForServiceAndEngineReady`.
  - Updated `dispatchEngineCommand` to avoid duplicate intent-extra command dispatches and return the true Dart engine acknowledgement.
  - Exposed `lastNativeError` and `lastNativeShutdownReason` in `getServiceStatus`.
- **`lib/models/trading_models.dart`**:
  - Added `BotEngineState.starting` and `BotEngineState.failedStartupError` and `startupStateMachineLabel` (`STOPPED`, `STARTING`, `RUNNING`, `RUNNING — WAITING FOR VALID MARKET DATA`, `PAUSED — NETWORK OR DATA ISSUE`, `PAUSED — SAFETY RESTRICTION`, `FAILED — STARTUP ERROR`).
  - Updated `CoinDcxMarketRecord.isActiveStatus` to require `hasValidSpecifications`.
- **`lib/services/persistence_db.dart`**:
  - Added `lastStartupAttemptMs`, `lastStartupError`, `lastShutdownReason`, and `lastBackgroundCycleError` to `PersistedEngineSnapshot`, `saveFullState`, `loadFullState`, and `saveStartupDiagnostics`.
- **`lib/services/authoritative_engine.dart`**:
  - Persisted `BotEngineState.running` and fresh heartbeat immediately on `startEngine()` before running the first scan cycle.
  - Updated `_startPeriodicTimer()` to continue polling across `running`, `waitingForFreshData`, `pausedStaleData`, and `reconnecting` whenever `userIntention == UserSessionIntention.running`.
  - Added rotating liquidity-prioritized candle batching (`maxCandleEvaluationPairsPerCycle = 12`) for large live catalogues (`> 12` pairs) while evaluating 100% of pairs when `<= 12`.
  - Isolated non-fatal cycle errors into `lastBackgroundCycleError` without terminating the engine.
- **`lib/services/trading_coordinator.dart`**:
  - Implemented strict `STOPPED -> STARTING -> RUNNING / FAILED — STARTUP ERROR` state machine in `startBot()` with `_isStartupInFlight` mutex and verified initial cycle persistence.
  - Added `showOnlyEligibleMarkets` filter and portfolio-isolated `setPortfolioStrategy` / `updatePortfolioSettings` methods.
- **`lib/services/dual_portfolio_service.dart` & `lib/models/dual_portfolio_models.dart`**:
  - Added portfolio-isolated strategy descriptors (`availableStrategiesFor`, `activeStrategyDescriptorFor`), `setPortfolioStrategy`, and `updatePortfolioSettings`, preserving each portfolio's strategy and settings across SQLite syncs.
- **`lib/main.dart` & `lib/screens/dashboard_screen.dart`**:
  - Added `ENGINE STARTUP & RUNTIME DIAGNOSTICS` card in `Settings` displaying all 10 required diagnostic fields.
  - Fixed `-$0.00` negative-zero formatting (`_formatSignedUsdt`, `_formatUnsignedUsdt`, `_formatSignedPct`) so values within `±0.005` display `$0.00`.
  - Fixed responsive two-line layout in `_buildPortfolioSelectorBar()` so `HIGH-VOLATILITY PORTFOLIO` is never truncated.
  - Added `✓ Eligible Only` filter chip and explicit view-mode indicator in `Markets`.
  - Updated `Reports` and `AI Lab` to clearly distinguish actual paper trades (`Performance not yet established` when 0 trades), backtests, simulated research, strategy candidates, and current drawdown vs the approved `$10.00` (`$90.00` floor) limit.
- **`test/stages_1_to_20_test.dart` (and `phase1_trading_test.dart`, `service_watchdog_test.dart`, `stage47_1_market_discovery_test.dart`)**:
  - Added `Startup Audit & Full Lifecycle Tests 1–15 (Tasks 1–9)` covering startup readiness, no-trade `RUNNING` persistence across periodic UI refreshes, temporary API outage recovery, stale data/stop-loss/risk vetoes, `PAUSE`/`RESUME`/`STOP`, startup failure handling, and portfolio strategy/settings isolation.

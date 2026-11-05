# CHANGES.md — Self-Healing Background (Step 0 & Step 1)

## 1. Files Changed / Added
- `CHANGES.md` (added at repository/zip root)
- `.github/workflows/build-apk.yml` (modified)
- `ankit_ai_trader_mobile_v1/lib/main.dart` (modified)
- `ankit_ai_trader_mobile_v1/lib/services/authoritative_engine.dart` (modified)
- `ankit_ai_trader_mobile_v1/lib/services/persistence_db.dart` (modified)
- `ankit_ai_trader_mobile_v1/lib/services/trading_coordinator.dart` (modified)
- `ankit_ai_trader_mobile_v1/android/app/src/main/kotlin/com/ankit/aitrader/MainActivity.kt` (modified)
- `ankit_ai_trader_mobile_v1/android/app/src/main/kotlin/com/ankit/aitrader/TradingForegroundService.kt` (modified)
- `ankit_ai_trader_mobile_v1/test/phase1_trading_test.dart` (modified)

## 2. Root-Cause Verification (One Line Per Root Cause)
- **Root Cause (1)**: Verified **YES** — in base `ankit_ai_trader_mobile_v1/lib/services/authoritative_engine.dart:367-422` (`pausedStaleData`), `:439-454` (`pausedStaleData`), and `:554-579` (`pausedAfterRecoveryManualStartRequired`), any single transient stale/gap/network error permanently saved a paused state, causing subsequent heartbeat ticks to early-return at `:335-342`. Fixed with bounded auto-recovery (30s -> 60s -> 120s backoff for up to 10 minutes) in `authoritative_engine.dart:64-109, 198-311`.
- **Root Cause (2)**: Verified **YES** — in base `ankit_ai_trader_mobile_v1/lib/services/trading_coordinator.dart:165-183` (reopen check) and `MainActivity.kt:266-270` (`onAvailable` calling `TradingForegroundService.notifyNetworkTransition(true)` which rewrote `running -> pausedAfterRecoveryManualStartRequired` at `authoritative_engine.dart:278-298`), reopening the app or receiving an `onAvailable` callback while already connected overwrote `running` to `paused`. Fixed in `trading_coordinator.dart:194-239` (reconnects if heartbeat < 5m old, displaying `"RECONNECTED — heartbeat HH:MM:SS"`) and `MainActivity.kt:252-256`.
- **Root Cause (3)**: Verified **YES** — in base `ankit_ai_trader_mobile_v1/lib/services/authoritative_engine.dart:348-463`, a single unisolated loop iterated over `['BTCUSDT', 'ETHUSDT']` so any BTC exception/stale/gap aborted before ETH and saved the entire engine as paused. Fixed with per-symbol `try/catch` isolation in `authoritative_engine.dart:541-642`.
- **Root Cause (4)**: Verified **YES** — in base `ankit_ai_trader_mobile_v1/android/app/src/main/kotlin/com/ankit/aitrader/TradingForegroundService.kt:102-111, 132`, `heartbeatRunnable` invoked `backgroundChannel?.invokeMethod("onBackgroundTick", null)` with no `MethodChannel.Result` callback and no `try/catch`, and never persisted a heartbeat timestamp to SQLite. Fixed in `TradingForegroundService.kt:107-161` and `persistence_db.dart:161-185` + `main.dart:428-432`.
- **Root Cause (5)**: Verified **YES** — in base `ankit_ai_trader_mobile_v1/android/app/src/main/kotlin/com/ankit/aitrader/MainActivity.kt:64, 222-252`, `awaitServiceAndDartInitialization` polled `attemptsRemaining = 25` at `200L` ms (5 seconds total) and returned `SERVICE_INIT_TIMEOUT`. Raised to 15s (`75 * 200ms`) and updated slow cold-start status to `"starting…"` in `MainActivity.kt:27-28, 66, 226-256` and `trading_coordinator.dart:322-352`.

## 3. Exact Git Commands to Run
```bash
git checkout -b feature/self-healing-background
# (unzip Ankit_AI_Trader_Self_Healing_Background_1.zip over the repo root, allow overwrite)
git status
git add -A
git commit -m "Self-healing background: bounded recovery, reconnect on reopen, per-symbol isolation"
git push -u origin feature/self-healing-background
```

## 4. Deferred Items ("Next" — Not Bundled in This Branch)
- Moving `ConnectivityManager.NetworkCallback` registration from `MainActivity` into `TradingForegroundService`
- WorkManager periodic watchdog for service resurrection
- `RECEIVE_BOOT_COMPLETED` broadcast receiver for boot restore
- Additional notification action changes

# Ankit AI Trader — Full System Audit, Spot Accounting Repair & Risk Management (`CHANGES.md`)

## 1. Branch Verification
- Active working branch: `feature/dual-portfolio-foundation` (non-main development branch).
- `main` branch and private backup repository (`ankit-ai-trader-backup`) were never modified.

## 2. Root Causes Identified & Resolved
1. **Spot vs. Leveraged Margin Accounting Discrepancy (`$37.64` Cash, `$62.30` Used Margin, `$37.15` Free Margin, `-$0.55` P&L, `0` Closed Trades)**:
   - Forensic reconciliation of the OnePlus screenshot values proved that `CRYPTO PORTFOLIO` had 1 active spot position with `$62.30` invested notional (`entryPrice * quantity`) and `$0.0623` (`0.1%`) entry fee deducted from `$100.00` starting balance, leaving `$37.6377` (`$37.64`) available cash. With mark-to-market position value at `$61.81` (net of estimated `0.1%` exit fee), total equity was `$37.64 + $61.81 = $99.45` (`Unrealised P&L = -$0.55`, `Drawdown = $0.55`, `Realised P&L = $0.00` across `0` closed trades).
   - **Bug A (CFD Free Margin Formula on Spot Account)**: `freeMarginUsdt` previously computed `accountEquityUsdt - usedMarginUsdt` (`$99.45 - $62.30 = $37.15`), falsely subtracting the `-$0.55` unrealised position loss from unallocated cash (`$37.64`) and displaying `Free Margin: $37.15` next to `Available: $37.64`. Fixed so Spot `freeMarginUsdt == availableCashUsdt` and replaced leveraged margin labels with `Available Cash` and `Reserved (Spot)`.
   - **Bug B (Home Stat Strip Mixing Closed Trade Count with Unrealised P&L)**: The Home stat strip showed `Trades (W/L): 0 (0/0)` (closed trades only) next to `Total Profit: -$0.55` (which included unrealised P&L), without showing `Positions: 1/5` or separating `Realised P&L ($0.00)` from `Unrealised P&L (-$0.55)`. Fixed across `Home`, `Trades`, and `Reports`.
   - **Bug C (Background Isolate Race & Legacy `portfolioId` Filtering on `open_positions`)**: `backgroundServiceMain()` previously invoked `acknowledgeEngineInitialized` before loading persisted SQLite state into `AuthoritativeTradingEngine`, allowing an early `"START"` command to overwrite `open_positions` in SQLite. Additionally, `TradingCoordinator._applySnapshotToFields()` previously updated `DualPortfolioManager` asynchronously rather than synchronously in the same frame. Fixed by calling `await engine.loadPersistedStateIntoMemory()` before `acknowledgeEngineInitialized`, querying `(portfolioId = 'CRYPTO' OR portfolioId IS NULL OR portfolioId = '')`, and calling `dualPortfolioManager.syncCryptoPortfolioInMemory(snap)` synchronously inside `_applySnapshotToFields()`.
2. **Automatic Startup -> Shutdown (`START -> RUNNING -> STOPPED`)**:
   - Fixed in `MainActivity.kt`, `TradingForegroundService.kt`, `TradingCoordinator.startBot()`, and `AuthoritativeTradingEngine` with a single idempotent startup pathway (`_isStartupInFlight` mutex), native readiness polling (`waitForServiceAndEngineReady`), command retry queue (`invokeCommandWithRetry`), immediate state/heartbeat persistence, continuous timer polling during `waitingForFreshData`, and rotating 12-pair candle batching.

## 3. Risk Management & Portfolio Enhancements (Sections 5, 6, 7, 10, 11)
- **15% Overall Portfolio Loss Protection (`$85.00` Floor on `$100.00`)**:
  - Implemented configurable per-portfolio `maxPortfolioLossPct` (default `15.0%` / `$15.00` max cumulative loss / `$85.00` equity floor on `$100.00` starting balance) in `RiskConfig`, `IndependentRiskSupervisor`, `PortfolioAccountSnapshot`, `DualPortfolioManager`, and `PersistenceDatabase` (Schema v6).
  - At `<= $85.00` equity (`15%` loss), triggers `portfolioLossLockoutActive = true`, blocks new entries, persists the lockout state in SQLite, preserves existing open positions without forced liquidation, and requires `authorizePortfolioLossLimitReset` before resuming.
  - Preserved the existing `$2.00` (`2%`) daily loss limit and `$1.00` (`1%`) per-trade risk cap.
- **Configurable Maximum 5 Open Positions (`x / 5`)**:
  - Updated `RiskConfig`, `PortfolioAccountSnapshot`, `IndependentRiskSupervisor`, and `DualPortfolioManager` to support up to `5` simultaneous open positions per portfolio (`configuredMaxOpenPositions = 5`, configurable `1..5` in `Settings`), counting both open positions and pending orders and blocking duplicate symbols.
- **Distinct Portfolio Execution & Research Status Indicators**:
  - Added explicit status indicators distinguishing `Crypto Engine: RUNNING / STOPPED`, `High-Vol Research: ACTIVE / IDLE`, and `High-Vol Execution: DISABLED (Research-Only)`.

## 4. Modified & Newly Created Files in Delta ZIP
- `CHANGES.md`
- `ankit_ai_trader_mobile_v1/android/app/src/main/AndroidManifest.xml`
- `ankit_ai_trader_mobile_v1/android/app/src/main/kotlin/com/ankit/aitrader/MainActivity.kt`
- `ankit_ai_trader_mobile_v1/android/app/src/main/kotlin/com/ankit/aitrader/TradingForegroundService.kt`
- `ankit_ai_trader_mobile_v1/android/app/src/main/res/mipmap-*/ic_launcher.png` (5 density icons)
- `ankit_ai_trader_mobile_v1/lib/main.dart`
- `ankit_ai_trader_mobile_v1/lib/models/dual_portfolio_models.dart`
- `ankit_ai_trader_mobile_v1/lib/models/trading_models.dart`
- `ankit_ai_trader_mobile_v1/lib/screens/dashboard_screen.dart`
- `ankit_ai_trader_mobile_v1/lib/services/authoritative_engine.dart`
- `ankit_ai_trader_mobile_v1/lib/services/coindcx_market_service.dart`
- `ankit_ai_trader_mobile_v1/lib/services/dual_portfolio_service.dart`
- `ankit_ai_trader_mobile_v1/lib/services/execution_and_risk_hub.dart`
- `ankit_ai_trader_mobile_v1/lib/services/persistence_db.dart`
- `ankit_ai_trader_mobile_v1/lib/services/risk_manager.dart`
- `ankit_ai_trader_mobile_v1/lib/services/trading_coordinator.dart`
- `ankit_ai_trader_mobile_v1/test/stages_1_to_20_test.dart`
- `ankit_ai_trader_mobile_v1/test/phase1_trading_test.dart`
- `ankit_ai_trader_mobile_v1/test/service_watchdog_test.dart`
- `ankit_ai_trader_mobile_v1/test/stage47_1_market_discovery_test.dart`

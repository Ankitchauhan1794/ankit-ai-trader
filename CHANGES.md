# Ankit AI Trader — High-Volatility Crypto Paper Trading & Startup Fix (`CHANGES.md`)

## 1. Branch Verification
- Active working branch: `feature/dual-portfolio-foundation` (non-main development branch).
- `main` branch and private backup repository (`ankit-ai-trader-backup`) were never modified.

## 2. Engine Startup Failure Fix (`FAILED — STARTUP ERROR: Background engine rejected command 'START'`)
- **Root Cause**:
  1. `TradingCoordinator.startBot()` saved `userIntention = UserSessionIntention.running` to SQLite before `ensureServiceStartedAndReady()`, and `backgroundServiceMain()` auto-called `engine.startEngine()` concurrently with `TradingCoordinator`'s explicit `handleCommand('START')` dispatch.
  2. `TradingCoordinator` also instantiated a fallback `verifierEngine` with a different `ownerId` (`authoritative_paper_engine_lock` vs `bg_service_engine_1`), which could leave a 55-second SQLite lock that caused `AuthoritativeTradingEngine.startEngine()` to return `false` (`Background engine rejected command 'START'`).
- **Fixes Applied**:
  - `lib/services/authoritative_engine.dart`: Added `_activeStartFuture` coalescing so concurrent `startEngine()` calls share the same execution, made running-state `startEngine()` idempotent, and passed `forceTakeover: true` to `acquireExecutionLock` for the authoritative engine on explicit user `START`.
  - `lib/main.dart`: Updated `backgroundServiceMain()` to skip auto-starting when `engine.state == BotEngineState.starting` (leaving `handleCommand('START')` as the single authoritative startup pathway).
  - `lib/services/persistence_db.dart`: Added `forceTakeover` support to `acquireExecutionLock`.
  - `lib/services/trading_coordinator.dart`: Aligned fallback `ownerId` to `'bg_service_engine_1'` and surfaced persisted `lastStartupError` diagnostics on failure.

## 3. High-Volatility Crypto Paper Trading Enabled (Gold & Silver Kept Research-Only)
- **Separated Execution Permissions by Instrument Category**:
  - **High-Volatility Cryptocurrency (ENABLED — Paper Only)**: `UnverifiedHighVolatilityProvider` and `DualPortfolioManager` now authorize verified, eligible CoinDCX Spot crypto pairs (USDT pairs, `BTCUSDT`, `ETHUSDT`, and high-volatility pairs passing `HighVolatilityMarketClassifier` liquidity, spread, freshness, and ATR/volatility checks) for simulated execution via the internal `PaperBroker`.
  - **Gold (`XAUUSD`) & Silver (`XAGUSD`) (RESEARCH-ONLY)**: Explicitly blocked from execution (`PRECIOUS_METALS_RESEARCH_ONLY_LOCK`) with zero fabricated prices or contract specifications until a verified metals provider is selected.
- **Independent High-Volatility Cycle & Database Migration (`Schema v7`)**:
  - Added `_executeHighVolatilityCryptoCycle()` inside `AuthoritativeTradingEngine.executeTradingCycle()` so High-Volatility crypto opportunities execute and close independently with their own `$100.00` balance, `openPositions`, `orders`, `closedTrades`, `IndependentRiskSupervisor` (`5` max positions, `15%` / `$85.00` overall portfolio loss limit, `$2.00` daily loss limit), strategy configuration, and learning context.
  - Updated `PersistenceDatabase` to Schema v7 to migrate `HIGH_VOLATILITY` in `portfolio_accounts` (`executionEnabled = 1, isResearchOnly = 0`) while preserving all existing balances and records.

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

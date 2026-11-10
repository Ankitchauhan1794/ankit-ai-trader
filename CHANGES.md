# Ankit AI Trader — Complete Professional Mobile UI Redesign (`CHANGES.md`)

## 1. Overview of Changes
Implemented a complete XM / Exness-inspired dark cryptocurrency terminal UI redesign across all 6 screens (`Home`, `Markets`, `Trades`, `AI Lab`, `Reports`, `Settings`) while strictly preserving the existing trading engine, strategies, market discovery, paper broker, SQLite database, `$100.00` paper account, and deterministic Risk Supervisor parameters.

## 2. Modified & Added Files
1. `ankit_ai_trader_mobile_v1/lib/main.dart`
   - Implemented the XM/Exness dark obsidian theme (`#080B12` primary background, `#101622` card surface, `#1E293B` 1px borders, `#10B981` profit emerald, `#EF4444` loss crimson, `#3B82F6` primary electric blue).
   - Built the 6-tab bottom navigation bar (`Home`, `Markets`, `Trades`, `AI Lab`, `Reports`, `Settings`).
   - Built **Screen 1 — Home (Executive Portfolio Dashboard)**:
     - Top header with logo, `PAPER` badge, and live status badge (`RUNNING`, `PAUSED`, `STOPPED`, `OFFLINE`).
     - Conditional error banner that only renders when an actual network/exchange issue is active.
     - Account Overview card (`Equity`, `Balance`, `Available`, `Used Margin`, `Free Margin`, `Daily P&L`, `Overall P&L`, `Drawdown`).
     - 4-column Trading Statistics strip (`Trades`, `Win Rate`, `Profit Factor`, `Total Profit`).
     - Interactive Equity Curve (`1D`, `7D`, `30D`, `ALL`) with custom area/line chart painter.
     - Risk Status card showing Trade Risk (`$1.00 / 1%`), Daily Loss Limit (`$2.00 / 2%`), Max Drawdown (`$10.00 / 10%`), Remaining Risk Budget, Max Open Positions (`1`), and Cooldown (`30m`).
     - Market Overview card (`See All >`), Open Positions card (`History >`), and honest System Status card (`Local Android Mode (VPS Not Configured)`).
     - Removed `Start`, `Pause`, and `Stop` buttons from the Home screen and relocated them exclusively to `Settings`.
   - Built **Screen 2 — Markets (Complete CoinDCX Market Watch & Chart)**:
     - Instant search bar (`BTC`, `INR`, `SOL`), quote currency filter chips (`ALL`, `USDT`, `INR`, `BTC`, `ETH`, `OTHER`), eligibility filter chips (`ELIGIBLE`, `ALL`, `SPREAD`, `LOW VOL`, `INACTIVE`), favourites toggle (`★ Favs`), and sort selector (`Rank`, `Volume`, `24h Change`, `Spread`).
     - Tapping any pair opens the interactive **Pair Detail Bottom Sheet** with Candlestick Chart (`1m`, `5m`, `15m`, `1h`), EMA 9 / EMA 21 / RSI 14 / ATR 14 strip, Bid/Ask/Spread/24h High-Low/Volume grid, Exchange Rules (min qty, min notional, price/qty precision), and latest strategy evaluation reason.
   - Built **Screen 3 — Trades (Open Positions & Closed Trades)**:
     - Sub-tab switcher for `Open Positions` and `Closed Trades`.
     - Open Positions cards with entry/mark price, quantity, notional, SL/TP distance, unrealized P&L (`$` and `%`), duration, and confirmation-guarded manual close button.
     - Closed Trades filterable by outcome (`ALL`, `PROFIT`, `LOSS`) and symbol, with expandable trade cards showing entry/exit timestamps, fees, slippage, strategy name, exit reason, and trade ID.
   - Built **Screen 4 — AI Lab (Honest AI & Strategy Centre)**:
     - Clearly separates active local components (`EMA_9_21_RSI_Cross v1.0.0`, `MarketRegimeClassifier`, `Stage 47.2 StatisticalValidator`, `Stage 47.3 ModelGovernanceEngine`) from unconfigured external cloud LLM agents (`INACTIVE — Not Configured in Local Android Mode`).
     - Displays multi-pair evaluation summary, per-pair signal table, and rejection breakdown chart.
   - Built **Screen 5 — Reports (Performance Analytics & Export)**:
     - Period P&L strip (`Today`, `7D`, `30D`, `All-Time`), Win/Loss/Payoff metrics, Drawdown Curve chart, Trade Duration analytics, Performance by Pair, and `Export CSV` dialog.
   - Built **Screen 6 — Settings (Bot Controls, Risk & System Diagnostics)**:
     - Houses `START`, `PAUSE`, `STOP` (with confirmation dialog), `FORCE SCAN`, and `RESET $100` (with confirmation dialog) plus all 9 required settings sections.
2. `ankit_ai_trader_mobile_v1/lib/services/trading_coordinator.dart`
   - Added read-only UI analytics and filter helpers (`favouriteMarketPairs`, `showOnlyFavouriteMarkets`, `toggleFavouriteMarket`, `selectedEquityTimeframe`, `filteredEquityCurve`, `usedMarginUsdt`, `freeMarginUsdt`, `remainingDailyRiskBudgetUsdt`, `remainingDrawdownBudgetUsdt`, `closedTradesOutcomeFilter`, `closedTradesPairFilter`, `filteredClosedTrades`, `realizedPnlByPair`, `tradeDurationStats`) without altering any trading engine or risk logic.
3. `ankit_ai_trader_mobile_v1/test/stages_1_to_20_test.dart` (and synced test suites)
   - Added `UI Redesign Test 23` verifying the new UI state helpers, favourites, equity curve timeframes, margin/risk budget getters, and closed trade filters alongside all existing Stages 1–47.1 and Multi-Pair tests.

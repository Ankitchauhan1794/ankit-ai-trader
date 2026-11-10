# Changelog (`CHANGELOG.md`)

## [2.5.0] — 2026-11-10 — Complete Professional Mobile UI Redesign (XM / Exness Dark Terminal)
### Added
- **6-Screen Professional Dark Trading Terminal UI** (`lib/main.dart`):
  - **Home**: Executive Portfolio Dashboard with top `PAPER` & status pills, conditional network alert banner, Account Overview card (Equity, Balance, Available, Used/Free Margin, Daily/Overall P&L, Drawdown), 4-column Trading Statistics strip, interactive Equity Curve (`1D`/`7D`/`30D`/`ALL`), Risk Status card, Market Overview preview (`See All >`), Open Positions preview (`History >`), and honest System Status card.
  - **Markets**: Full CoinDCX Spot market watch with instant search, quote tabs (`ALL`, `USDT`, `INR`, `BTC`, `ETH`, `OTHER`), status filters, favourites star filter, sorting, and interactive **Pair Detail Bottom Sheet** with Candlestick Chart (`1m`, `5m`, `15m`, `1h`), EMA 9/21, RSI 14, ATR 14, and exchange precision rules.
  - **Trades**: Dedicated `Open Positions` and `Closed Trades` sub-tabs with outcome (`ALL`/`PROFIT`/`LOSS`) and pair filters, expandable execution audit details, and confirmation-guarded manual position close.
  - **AI Lab**: Honest AI & Strategy Centre displaying active local deterministic engines (`EMA_9_21_RSI_Cross`, `MarketRegimeClassifier`, `StatisticalValidator`, `ModelGovernanceEngine`), marking unconfigured cloud LLM agents as `INACTIVE`, and showing live signal rejection breakdowns.
  - **Reports**: Period P&L cards (`Today`, `7D`, `30D`, `All-Time`), Win/Loss/Profit Factor/Expectancy grid, Drawdown Curve chart, Trade Duration statistics, P&L by Pair, and CSV export modal.
  - **Settings**: Relocated Bot Controls (`START`, `PAUSE`, `STOP`, `FORCE SCAN`, `RESET $100`) off the Home screen into Settings with confirmation dialogs on `STOP` and `RESET $100`, plus 9 organized configuration & diagnostic panels.
- **UI Analytics & Filter Helpers** (`lib/services/trading_coordinator.dart`) & **Automated Test 23** (`test/stages_1_to_20_test.dart`).

### Preserved Unchanged
- Authoritative multi-pair trading engine, `EMA_9_21_RSI_Cross` strategy rules, Stage 47.1 CoinDCX market discovery, deterministic Risk Supervisor (`$100` balance, `$1` trade risk, `$2` daily loss limit, `$10` max drawdown, `1` max open position, `30m` cooldown), candle-based SL/TP, SQLite persistence, and Android foreground service watchdog.

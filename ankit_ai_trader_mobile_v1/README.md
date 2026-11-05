# Ankit AI Trader — Phase 1 Final Candidate (with Trade Alert Notifications & Toggle)

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
      trade_alert_formatter.dart
      trading_coordinator.dart
  test/
    phase1_trading_test.dart
    widget_test.dart
```

## Trade Alert Notifications & In-App Toggle

1. **Dedicated High-Importance Notification Channel (`Trade Alerts`)**:
   - `TradingForegroundService.kt` creates a dedicated `NotificationChannel("trade_alerts_channel", "Trade Alerts", NotificationManager.IMPORTANCE_HIGH)` completely separate from the ongoing service channel (`"ankit_trader_service"`).
   - Every trade alert is posted as a normal dismissible notification (`setOngoing(false)`, `setAutoCancel(true)`) with a unique notification ID (`>= 2000`) so it never replaces or overwrites the persistent `"Ankit AI Trader — PAPER BOT ACTIVE"` foreground notification (`ID 1101`).

2. **Events & Mandatory `PAPER TRADE` Labeling (`TradeAlertFormatter`)**:
   - **Simulated ENTRY**: Includes `[PAPER TRADE]`, symbol, side (`BUY`), entry price, quantity, stop-loss, take-profit, and dollar amount risked.
   - **Simulated EXIT**: Includes `[PAPER TRADE]`, symbol, exit price, exit reason (`STOP_LOSS`, `TAKE_PROFIT`, `BEARISH_EMA_CROSSOVER`, etc.), net P&L after fees and slippage, and new account equity.
   - **Safety Locks**: Fires when the `$2.00` Daily Loss Limit, `$90.00` Maximum Drawdown / Equity Floor, or Internet Loss Pause triggers.

3. **In-App Toggle (`Trade alert notifications` ON/OFF)**:
   - Persisted in SQLite `engine_kv_state` under key `'tradeAlertsEnabled'` (default: `true` / ON).
   - `AuthoritativeTradingEngine.dispatchAlertIfEnabledAndNew` reads `getTradeAlertsEnabled()` from SQLite before sending each alert, so flipping the switch takes effect immediately without restarting the bot and without hiding the ongoing foreground service notification.
   - Duplicate alerts are prevented via SQLite-persisted `notifiedAlertIds` and `lastNotifiedOrderId`.
   - If Android 13+ (`POST_NOTIFICATIONS`) permission is denied, the app never crashes; the dashboard displays a warning banner with a **NOTIFICATION SETTINGS** button.

## Device Test Checklist (Manual QA Verification)

- [ ] **Closed-App Entry & Exit Alert Verification**: Start the paper bot with **Trade alert notifications** set to **ON**, swipe/close the app UI so only the background foreground service is running, trigger a simulated entry and exit, and verify that separate dismissible heads-up notifications appear under the **"Trade Alerts"** channel labeled `[PAPER TRADE]`.
- [ ] **Toggle OFF Verification**: Turn **Trade alert notifications** **OFF** on the dashboard, trigger a simulated trade event or safety lock, and verify that **no** trade alert notification appears while the persistent **"Ankit AI Trader — PAPER BOT ACTIVE"** foreground service notification remains visible and the bot continues running.
- [ ] **Android 13+ Permission Denied Handling**: Deny notification permission in Android system settings, open the dashboard, and verify the app does not crash, displays the blocked-alerts notice, and opens system settings when tapping **NOTIFICATION SETTINGS**.

# Ankit AI Trader — Dual Portfolio Architecture & Android Resource Fix (`CHANGES.md`)

## 1. Resolved AAPT `mipmap/ic_launcher` Build Error
- Added standard Android launcher icons (`ic_launcher.png`) across all 5 density directories under `ankit_ai_trader_mobile_v1/android/app/src/main/res/`:
  - `mipmap-mdpi/ic_launcher.png` (48x48)
  - `mipmap-hdpi/ic_launcher.png` (72x72)
  - `mipmap-xhdpi/ic_launcher.png` (96x96)
  - `mipmap-xxhdpi/ic_launcher.png` (144x144)
  - `mipmap-xxxhdpi/ic_launcher.png` (192x192)
- Added an automatic pre-build safeguard in `.github/workflows/build-apk.yml` that verifies/creates `mipmap-*/ic_launcher.png` before running `flutter build apk --release`.

## 2. Dual Portfolio Architecture Foundation
- **Portfolio A (`CRYPTO`)**: Preserves existing CoinDCX Spot integration, `$100.00` paper account balance, open positions, orders, trade history, and deterministic risk configuration.
- **Portfolio B (`HIGH_VOLATILITY`)**: Independent `$100.00` paper account supporting high-volatility cryptocurrency research and precious metals (`XAUUSD` Gold, `XAGUSD` Silver) in strict `RESEARCH-ONLY` mode (`executionEnabled = false`) until a verified provider and contract specifications are approved.

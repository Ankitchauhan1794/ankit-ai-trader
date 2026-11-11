# Changelog (`CHANGELOG.md`)

## [2.6.1] — 2026-11-11 — Android `mipmap/ic_launcher` Resource Fix & Dual Portfolio Foundation
- Added `mipmap-mdpi`, `mipmap-hdpi`, `mipmap-xhdpi`, `mipmap-xxhdpi`, and `mipmap-xxxhdpi` `ic_launcher.png` resources required by `AndroidManifest.xml` (`android:icon="@mipmap/ic_launcher"`).
- Added CI pre-build icon verification in `.github/workflows/build-apk.yml`.
- Verified all 43 unit, widget, multi-pair, UI redesign, and Dual Portfolio tests in `test/stages_1_to_20_test.dart`.

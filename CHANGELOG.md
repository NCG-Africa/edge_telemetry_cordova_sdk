# Changelog

All notable changes to `@nathanclaire/rum-cordova` are documented here. Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## 1.0.0

First release. Real User Monitoring for Cordova apps on Android (cordova-android ≥ 15) and iOS (cordova-ios ≥ 8).

⚠ **Install the Edge RUM backend release before shipping a build with this plugin.** It sends contract 4.0.0 batches with `sdk.name=cordova`; an older backend drops them.

### Added

- **Install-and-go**: `cordova plugin add @nathanclaire/rum-cordova --variable EDGE_RUM_API_KEY=… --variable EDGE_RUM_ENDPOINT=…`. Capture starts on launch; `init()` is optional.
- **Errors and crashes**: JS uncaught errors and rejections with `app:///` frames and breadcrumbs; `captureError()`; native crashes (Android JVM + NDK, iOS signals / Mach), sent on next launch; WebView content-process deaths; Android ANRs, hangs on both platforms, Android exit reasons; `deviceready` timeouts.
- **Launch time**: one `app.start` per cold launch with native and WebView phases, ended by `markReady()` if called.
- **Screens, requests, taps**: URL-driven screen changes or `trackScreen()` from your router; `fetch` / XHR with scrubbed URLs and opt-in `traceparent`; taps with rage and dead tap detection.
- **Performance**: Web Vitals, rendering smoothness, Cordova plugin call timings, opt-in resource timings, memory readings and pressure.
- **Your events**: `track`, `measure`, `time`, `startTask` / `completeTask` / `failTask`, `identify`, `setAttribute`.
- **Privacy and consent**: `beforeSend`, `[data-edge-private]`, opt-in mode (`EDGE_RUM_ENABLED=false`), `enable()` / `disable()` / `reset()`.
- **Delivery**: on-disk outbox, gzip batches, retry with backoff and offline replay, session sampling, per-session caps, drop counts in `sdk.health`.
- Docs: [events](docs/events.md), [privacy](docs/privacy.md), [troubleshooting](docs/troubleshooting.md).

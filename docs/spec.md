---
title: Edge RUM Cordova SDK 1.0.0 — build spec
status: approved 2026-10-25
source: map "Cordova SDK 4.0 — build spec" (NCG-Africa/edge_telemetry_cordova_sdk#1)
---

# Edge RUM Cordova SDK 1.0.0 — build spec

Package `@nathanclaire/rum-cordova` 1.0.0, wire contract 4.0.0. Each rule is stated **once**, numbered, and links the ticket that decided it. Tickets hold the reasoning; this doc holds the rules. Impl issues cite rules by number ("spec T7").

Wire contract rules **R1–R16** live in `edge_rum/wayfinder/assets/06-batch-header-draft.md` and are not restated. Research baselines: [sibling telemetry](research/sibling-sdk-telemetry.md), [competitors](research/cordova-competitor-sdks.md), [platform capabilities](research/cordova-platform-capabilities.md).

Rule prefixes: **K** packaging · **A** architecture/bridge · **W** wire/contract fit · **E** event catalogue · **N** naming/keys · **C** config/API · **T** transport · **S** sampling/caps · **P** privacy/consent · **Y** symbols · **Q** tests · **V** release/versioning.

Ticket links: [#5 SDK architecture](https://github.com/NCG-Africa/edge_telemetry_cordova_sdk/issues/5) · [#6 Telemetry catalogue](https://github.com/NCG-Africa/edge_telemetry_cordova_sdk/issues/6) · [#7 Contract 4 fit](https://github.com/NCG-Africa/edge_telemetry_cordova_sdk/issues/7) · [#8 Public API](https://github.com/NCG-Africa/edge_telemetry_cordova_sdk/issues/8) · [#9 Transport](https://github.com/NCG-Africa/edge_telemetry_cordova_sdk/issues/9) · [#10 Packaging](https://github.com/NCG-Africa/edge_telemetry_cordova_sdk/issues/10) · [#11 Symbols](https://github.com/NCG-Africa/edge_telemetry_cordova_sdk/issues/11) · [#12 Release](https://github.com/NCG-Africa/edge_telemetry_cordova_sdk/issues/12) · [#13 Privacy](https://github.com/NCG-Africa/edge_telemetry_cordova_sdk/issues/13) · [#14 Sampling](https://github.com/NCG-Africa/edge_telemetry_cordova_sdk/issues/14) · [#15 Tests](https://github.com/NCG-Africa/edge_telemetry_cordova_sdk/issues/15) · [#16 Router adapters](https://github.com/NCG-Africa/edge_telemetry_cordova_sdk/issues/16) · [#17 Processor surfacing](https://github.com/NCG-Africa/edge_telemetry_cordova_sdk/issues/17)

---

## 1. Overview

```
 WebView (JS, www/edge-rum.js)                       Native plugin (onload=true)
 ┌──────────────────────────────┐   cordova.exec    ┌───────────────────────────────────────┐
 │ capture: errors, http, nav,  │  enqueue(batch)   │ prefs (config.xml) · identity · session│
 │ taps, vitals, frames, bridge,│ ────────────────▶ │ sampling + caps gate (at append)       │
 │ app.start JS phases, API     │                   │ NDJSON outbox ── seal ── gzip ── POST  │
 │ beforeSend → buffer (2s/20)  │ ◀──────────────── │ native capture: crash, ANR, hang,      │
 │ pre-deviceready buffer (500) │   state events    │ renderer death, start, memory, network │
 └──────────────────────────────┘                   └───────────────────────────────────────┘
```

| Term | Meaning |
|---|---|
| **JS core** | TypeScript bundle in the WebView: capture, `beforeSend`, buffer, hand-off. |
| **Native core** | Java (Android) / Swift (iOS) plugin code: prefs, identity, session, gates, outbox, sender, native capture. |
| **Hand-off** | One `cordova.exec` carrying an array of events from JS to native. |
| **Segment** | One append-only NDJSON file in the outbox. Sealed segment = one batch. |
| **Exempt set** | Events that bypass the sampling roll and caps (S2). |

---

## 2. Packaging — K

- **K1** npm + plugin.xml `id` = `@nathanclaire/rum-cordova` (public). Install `cordova plugin add @nathanclaire/rum-cordova --variable EDGE_RUM_API_KEY=… --variable EDGE_RUM_ENDPOINT=…`. Keywords `ecosystem:cordova`, `cordova-android`, `cordova-ios`. ([#10](https://github.com/NCG-Africa/edge_telemetry_cordova_sdk/issues/10))
- **K2** One plugin, JS + native always shipped together. `<feature name="EdgeRum">` with `onload=true` on both platforms. No JS-only variant. ([#5](https://github.com/NCG-Africa/edge_telemetry_cordova_sdk/issues/5), [#10](https://github.com/NCG-Africa/edge_telemetry_cordova_sdk/issues/10))
- **K3** Android: Java `<source-file>`s, package `com.nathanclaire.rum.cordova`. **Zero `<framework>` Maven deps** (androidx.webkit from cordova-android 15 only; gzip `java.util.zip`). No Kotlin. Do not embed `edge_telemetry_android`. ([#5](https://github.com/NCG-Africa/edge_telemetry_cordova_sdk/issues/5), [#10](https://github.com/NCG-Africa/edge_telemetry_cordova_sdk/issues/10))
- **K4** iOS: Swift via plugin `Package.swift` + `<platform name="ios" package="swift">`, depends only on `Cordova`. No podspec, no CocoaPods. Do not embed `edge_telemetry_ios_sdk`. ([#10](https://github.com/NCG-Africa/edge_telemetry_cordova_sdk/issues/10))
- **K5** `<engines>`: cordova-android ≥ 15.0.0, cordova-ios ≥ 8.0.0, cordova CLI ≥ 13.0.0; Node ≥ 20.17. minSdk 24, iOS deployment target 14.0. ([#10](https://github.com/NCG-Africa/edge_telemetry_cordova_sdk/issues/10))
- **K6** JS: TypeScript in `src/` → esbuild → one ES2017 `www/edge-rum.js` `<js-module>` clobbering `EdgeRum`. `types/index.d.ts` generated from `src/` (`declare global { interface Window { EdgeRum } }`). Tarball = `www/` + `types/` + native sources + `plugin.xml`; never `src/`. ([#8](https://github.com/NCG-Africa/edge_telemetry_cordova_sdk/issues/8), [#10](https://github.com/NCG-Africa/edge_telemetry_cordova_sdk/issues/10))
- **K7** No Ionic Native / awesome-cordova-plugins wrapper; no router adapter packages; no subpath exports; no peer deps. ([#10](https://github.com/NCG-Africa/edge_telemetry_cordova_sdk/issues/10), [#16](https://github.com/NCG-Africa/edge_telemetry_cordova_sdk/issues/16))

## 3. Architecture and bridge — A

- **A1** Native owns: config prefs, app identity, `device_id`, session id + timeout/rotation, sampling roll, caps, user/attr persistence, enabled state, outbox, sender, contract-4 envelope. JS owns WebView capture, `beforeSend`, global attrs, the in-memory buffer. ([#5](https://github.com/NCG-Africa/edge_telemetry_cordova_sdk/issues/5))
- **A2** Exec service `EdgeRum`. Actions (JSON args; all fire-and-forget except `getState`/`subscribe`):

  | Action | Args | Result |
  |---|---|---|
  | `getState` | — | `{ enabled, sessionId, userId?, sampled, configured, sdkVersion, deviceStartedAt }` |
  | `subscribe` | — | keep-callback stream of `{ type: "session" \| "enabled", …state }` |
  | `enqueue` | `{ events: Event[], breadcrumbs: Breadcrumb[] }` | ok / error |
  | `configure` | `{ apiKey?, endpoint? }` (from `init()`, not persisted) | ok |
  | `identify` / `clearUser` | `{ id?, name?, email?, phone? }` / — | ok |
  | `enable` / `disable` / `reset` | — | ok |
  | `markPhase` | `{ phase, ts }` (JS `app.start` phases, A5) | ok |

  `sdkVersion` comes from plugin metadata (V3); action names are internal, not public API. Bridge tests (Q2) pin this table.
- **A3** Breadcrumbs: JS keeps a ring (last 50: navigation, taps, http, `console.*`) and ships new entries with every `enqueue`; native mirrors them into its own ring (last 50) and attaches it to native crash / renderer-death records. ([#5](https://github.com/NCG-Africa/edge_telemetry_cordova_sdk/issues/5))
- **A4** Before `deviceready`: JS buffers in memory (cap 500, drop-oldest, drops counted) and flushes on `deviceready`. If native is unavailable or `exec` errors → drop + count; **no JS fallback sender**. ([#5](https://github.com/NCG-Africa/edge_telemetry_cordova_sdk/issues/5), [#9](https://github.com/NCG-Africa/edge_telemetry_cordova_sdk/issues/9))
- **A5** `app.start` is assembled natively: native records process start + WebView created; JS sends `markPhase` for `responseEnd`, `DOMContentLoaded`, `load`, `deviceready`, and host `markReady()`. Native emits one `app.start` per cold launch when `deviceready` (or `markReady()` if called within 30 s of `deviceready`) arrives. ([#6](https://github.com/NCG-Africa/edge_telemetry_cordova_sdk/issues/6))
- **A6** iOS content-process termination: swizzle the private `CDVWebViewEngine` navigation-delegate `webViewWebContentProcessDidTerminate:` via the ObjC runtime, only on tested cordova-ios 8.x, off when `EdgeRumIosWebViewHook=false`. Otherwise **inference**: a page load with no clean shutdown marker since the previous one → renderer-death record. ([#5](https://github.com/NCG-Africa/edge_telemetry_cordova_sdk/issues/5))
- **A7** No `deviceready` within `EdgeRumDevicereadyTimeoutMs` → native persists a marker; `cordova.deviceready_timeout` is sent next launch. ([#5](https://github.com/NCG-Africa/edge_telemetry_cordova_sdk/issues/5))
- **A8** On `browser` / `electron` (no native), `EdgeRum` is a silent no-op: every method exists, nothing captured (R16). ([#7](https://github.com/NCG-Africa/edge_telemetry_cordova_sdk/issues/7))

## 4. Wire contract fit — W

- **W1** `sdk.name = "cordova"` always (incl. Ionic 1–4 / Framework7 / Quasar on Cordova). No framework attribute. ([#7](https://github.com/NCG-Africa/edge_telemetry_cordova_sdk/issues/7))
- **W2** `contract_version = "4.0.0"` (constant); `sdk.version` = package version, starts `1.0.0`. ([#7](https://github.com/NCG-Africa/edge_telemetry_cordova_sdk/issues/7), [#12](https://github.com/NCG-Africa/edge_telemetry_cordova_sdk/issues/12))
- **W3** App identity read natively, no override: Android `PackageManager` (`applicationId`, `versionName`, `versionCode`); iOS `Bundle.main` (bundle id, `CFBundleShortVersionString`, `CFBundleVersion`). `app.platform` = `android`|`ios`. Nil → key omitted (R15). ([#7](https://github.com/NCG-Africa/edge_telemetry_cordova_sdk/issues/7))
- **W4** `device_id` (R9): Android = port `IdGenerator` from `edge_telemetry_android` (SharedPreferences UUID, persisted fallback pinned per process, in-memory last resort); iOS = Keychain `device.id`, UserDefaults fallback, as `edge_telemetry_ios_sdk` `Recorder`. Never JS/localStorage. ([#7](https://github.com/NCG-Africa/edge_telemetry_cordova_sdk/issues/7))
- **W5** No collector/processor code change. **Doc amendment only:** add `cordova` to the R2 enum and glossary "SDK name" in `edge_rum/wayfinder/spec.md` (§1 glossary + R2 row) and `assets/06-batch-header-draft.md` R2. ([#7](https://github.com/NCG-Africa/edge_telemetry_cordova_sdk/issues/7))
- **W6** Processor stores Cordova-only events generically in `rum_telemetry_events`; no typed tables, no contract amendment. Surfacing = NCG-Africa/edge_telemetry_processor_go#19 (not this effort). ([#17](https://github.com/NCG-Africa/edge_telemetry_cordova_sdk/issues/17))

## 5. Event catalogue — E

`E:` event, `M:` metric. Src JS = WebView, N = native. "API" = emitted only when the host calls the method.

| # | Wire name | Src | Default | Rule |
|---|---|---|---|---|
| E1 | `session.started` / `session.finalized` | N | on | Native session id/rotation; finalized carries Flutter-style counters (`session.duration_ms`, `event_count`, `metric_count`, `screen_count`, `visited_screens`, …) counted **before** gates (S6). |
| E2 | `app_lifecycle` | JS+N | on | `lifecycle.state` from Cordova `pause`/`resume`, `visibilitychange`, native fg/bg. |
| E3 | `app.start` | N+JS | on | One row per cold launch: `app.start.type`, `app.start.duration_ms`, phase ms (process start → WebView created → `responseEnd` → `DOMContentLoaded` → `load` → `deviceready` → optional `markReady`). Never `page_load`. (A5) |
| E4 | `navigation` | JS | on | Patch `pushState`/`replaceState`/`popstate`/`hashchange`; name per P2; `trackScreen()` overrides. |
| E5 | `screen.duration` | JS | on | On leaving a screen. |
| E6 | `http.request` | JS | on | `fetch` + XHR; URL per P1; own endpoint and `ignoreUrls` skipped. No native HTTP stacks. |
| E7 | M:`resource_timing` | JS | opt-in | `PerformanceObserver('resource')`, `captureResourceTiming`. |
| E8 | `traceparent` injection | JS | opt-in | Only to hosts in `correlateRequestsTo`. |
| E9 | `app.crash` JS unhandled | JS | on | `error` + `unhandledrejection`; `handled=false`, `is_fatal=true`, `runtime=webview`, frames per Y2, `crash.breadcrumbs`, optional `release` (Y1). |
| E10 | `app.crash` handled | JS | on (API) | `captureError()` → `handled=true`, `is_fatal=false`. |
| E11 | `app.crash` console.error | JS | opt-in | `captureConsoleErrors`; default `console.*` → breadcrumbs only. |
| E12 | `app.crash` native | N | on | JVM uncaught + NDK signal (Android); signal/Mach (iOS). Persisted, sent next launch as solo segment (T4/R14), native breadcrumb ring attached. |
| E13 | `app.crash` `cause=WebViewTerminated` | N | on | Renderer death. `webview.reason ∈ crash\|oom_killed\|unknown`, `webview.detected_by ∈ callback\|inference`, `screen_name` (last), breadcrumbs. Same path as E12. Android `onRenderProcessGone`; iOS A6. |
| E14 | `app.anr` | N | on | Android, main thread blocked ≥ 5 s (`EdgeRumAnr`). Separate event, not folded into crash. |
| E15 | `app.hang` | N | on | Main-thread hang ≥ 2 s, Android + iOS (`EdgeRumHang`). |
| E16 | `app.exit` | N | on | Android `getHistoricalProcessExitReasons` (API 30+), once per new exit record. |
| E17 | `cordova.deviceready_timeout` | N | on | A7. |
| E18 | `bridge.summary` | JS | on | Per screen / flush window, grouped by `bridge.service` + `bridge.action`: `bridge.count`, `bridge.error_count`, `bridge.p50_ms`, `bridge.p95_ms`, `bridge.max_ms`. Timing via `cordova.callbacks` proxy. SDK's own `EdgeRum` service excluded. |
| E19 | `bridge.call` | JS | on | One call ≥ `slowBridgeCallMs` (1000) or never called back within 30 s: `bridge.service`, `bridge.action`, `bridge.duration_ms`, `bridge.outcome ∈ slow\|no_callback\|error`. |
| E20 | `frame.summary` | JS | on | rAF only, while visible, windowed per screen; processor `frame.*` keys (N1), `frame.source=raf`, `frame.long_task_count` where `longtask` exists. No native frame sampler. |
| E21 | M:`LCP` `INP` `CLS` `FCP` `TTFB` | JS | on | `web-vitals` (bundled); emit only what the WebView supports. |
| E22 | M:`memory_usage` bookends | N | on | RSS/PSS at session start/end. |
| E23 | M:`memory_usage` periodic | N | opt-in | `EdgeRumMemorySampling` + interval. |
| E24 | `memory_pressure` | N | on | `onTrimMemory` / iOS memory warning. |
| E25 | `ui.interaction` | JS | on | Capture-phase click/touch; `ui.type`, `ui.target`, `ui.name_source`, `ui.screen`, `ui.x`, `ui.y`; `ui.rage=true` (≥3 taps same target < 1 s), `ui.dead=true` (no DOM mutation/nav/request within 1 s). Name per P4. |
| E26 | `network_change` | N | on | Native reachability; JS `online`/`offline` before `deviceready`. |
| E27 | `custom_event` | JS | on (API) | `track()`; `event.name`. |
| E28 | M:(host name) | JS | on (API) | `measure()` / `time()`. |
| E29 | `task.complete` | JS | on (API) | Copy Flutter: `task.name`, `task.outcome`, `task.abandon_source`, `span.duration_ms`; open tasks abandoned at session end. |
| E30 | `user.profile.update` | JS→N | on (API) | P6. |
| E31 | `sdk.health` | N | on | R4 shape; drop counts by reason (T8, S7, P5), queue depth, disabled captures. Never in a crash batch. |
| E32 | device/app/network context | N | on | Contract-4 envelope + event attrs assembled natively. |

Never emit `page_load`, `user.interaction`, `frame_render_time`. Not captured: native HTTP clients, CPU sampling, native frames, session replay. ([#6](https://github.com/NCG-Africa/edge_telemetry_cordova_sdk/issues/6))

## 6. Naming and keys — N

- **N1** Events the processor already types use the **processor extractor key names** (`edge_telemetry_processor_go/internal/telemetry/extract.go`), not sibling dotted variants ([#17](https://github.com/NCG-Africa/edge_telemetry_cordova_sdk/issues/17)):

  | Event | Keys |
  |---|---|
  | `app.crash` / `app.anr` / `app.hang` | `message`, `stacktrace`, `exception_type`, `cause`, `error_context`, `error_code`, `crash_thread`, `crash_is_main_thread`, `is_fatal`, `handled`, `anr_duration_ms`, `hang_duration_ms`, `screen_name`, `user_action` |
  | `http.request` | `http.url`, `http.method`, `http.status_code`, `http.duration_ms`, `http.success`, `trace.id`, `span.id`, `parent.span.id` |
  | `navigation` | `navigation.from_screen`, `navigation.to_screen`, `navigation.method`, `navigation.route_type`, `navigation.has_arguments`, `navigation.timestamp` |
  | `screen.duration` | `screen.name`, `screen.duration_ms`, `screen.exit_method` |
  | `ui.interaction` | `ui.type`, `ui.target`, `ui.x`, `ui.y`, `ui.direction`, `ui.screen`, `ui.name_source` |
  | `frame.summary` | `frame.max_total_duration_ms`, `frame.slow_frames`, `frame.frozen_frames`, `frame.total_frames`, `frame.slow_frame_rate`, `frame.window_duration_ms` |
  | `memory_usage` / `memory_pressure` | `memory.usage_mb`, `memory.type`, `memory.source`, `memory.pressure_level` |
  | `user.profile.update` | `user.id`, `user.name`, `user.email`, `user.phone` |
  | `session.*` | `session.id`, `session.start_time`, `session.duration_ms`, `session.event_count`, `session.metric_count`, `session.screen_count`, `session.visited_screens`, `session.is_first_session`, `session.total_sessions`, `network.type` |
  | device attrs | `device.*` / `display.refresh_rate` as extracted in `extract.go` |

- **N2** Cordova-only events and attrs keep dotted keys from §5 (`bridge.*`, `app.start.*`, `webview.*`, `ui.rage`, `ui.dead`, `frame.source`, `frame.long_task_count`, `task.*`, `runtime`, `release`). ([#17](https://github.com/NCG-Africa/edge_telemetry_cordova_sdk/issues/17))
- **N3** Names with no Android equivalent take the iOS/Flutter 4.0 name. ([#6](https://github.com/NCG-Africa/edge_telemetry_cordova_sdk/issues/6))
- **N4** Terminology firewall (Ionic sibling `CLAUDE.md` Rule 1): no `telemetry`, `span`, `trace`, `tracer`, `metric(s)`, `instrumentation`, `otel`, `otlp` in public API names, typings, consumer docs, thrown errors, production console, package/plugin id. Consumer words: event, performance data, capture, timer. Wire names exempt. Enforced by a CI check (V1). ([#8](https://github.com/NCG-Africa/edge_telemetry_cordova_sdk/issues/8))

## 7. Configuration and public API — C

- **C1** config.xml preferences (plugin variables), read natively at launch:

  | Pref | Default |
  |---|---|
  | `EDGE_RUM_API_KEY`, `EDGE_RUM_ENDPOINT` | — (plugin variables) |
  | `EdgeRumEnabled` | `true` (`false` = opt-in mode, P7) |
  | `EdgeRumAnr` / `EdgeRumAnrTimeoutMs` | `true` / `5000` |
  | `EdgeRumHang` / `EdgeRumHangTimeoutMs` | `true` / `2000` |
  | `EdgeRumMemorySampling` / `EdgeRumMemorySamplingIntervalMs` | `false` / `30000` |
  | `EdgeRumIosWebViewHook` | `true` |
  | `EdgeRumDevicereadyTimeoutMs` | `10000` |
  | `EdgeRumSampleRate` | `1.0` (clamped 0..1) |
  | `EdgeRumDebug` | `false` |

  Missing key/endpoint → native still captures to disk; sends once `init()` supplies them via `configure`. ([#8](https://github.com/NCG-Africa/edge_telemetry_cordova_sdk/issues/8), [#14](https://github.com/NCG-Africa/edge_telemetry_cordova_sdk/issues/14))
- **C2** `EdgeRum.init(opts?)` — JS-only, optional: `apiKey?`, `endpoint?` (runtime, not persisted); `captureErrors`, `captureRequests`, `captureScreens`, `captureInteractions`, `captureFrames`, `captureVitals`, `captureBridge` (all `true`); `captureResourceTiming`, `captureConsoleErrors` (`false`); `correlateRequestsTo: (string|RegExp)[]`; `ignoreUrls`; `sanitizeUrl(url)`; `screenName(path) → string`; `beforeSend(event) → event | null`; `release?: string`; `slowBridgeCallMs` (1000); `frameSlowThresholdMs` (16.7 × 2 = 34); `debug`. No other knobs. ([#8](https://github.com/NCG-Africa/edge_telemetry_cordova_sdk/issues/8), [#11](https://github.com/NCG-Africa/edge_telemetry_cordova_sdk/issues/11), [#13](https://github.com/NCG-Africa/edge_telemetry_cordova_sdk/issues/13))
- **C3** Auto-start: no `init()` → JS capture starts with defaults on load. `init()` before `deviceready` reconfigures fully; later calls apply to new captures only. ([#8](https://github.com/NCG-Africa/edge_telemetry_cordova_sdk/issues/8))
- **C4** Methods — all sync, fire-and-forget, safe pre-`deviceready`, no-op per A8:
  ```
  init(opts?)
  identify({ id?, name?, email?, phone? })     // P6
  clearUser()
  track(name, attrs?)                          // custom_event
  measure(name, value, attrs?)                 // host-named numeric
  time(name) → { end(attrs?) }                 // → measure
  trackScreen(name, attrs?)                    // overrides auto navigation name
  captureError(err, attrs?)                    // app.crash handled=true
  startTask(name, attrs?) / completeTask(name) / failTask(name, reason?)
  markReady()                                  // app.start host phase
  setAttribute(k, v) / removeAttribute(k)      // global attrs on every JS event
  enable() / disable() / reset()               // P7
  getSessionId(): Promise<string>
  ```
  ([#8](https://github.com/NCG-Africa/edge_telemetry_cordova_sdk/issues/8), [#13](https://github.com/NCG-Africa/edge_telemetry_cordova_sdk/issues/13))
- **C5** Router recipes (README, docs only): Angular Router, Vue Router, React Router, AngularJS ui-router; each sets `init({ captureScreens: false })` and calls `trackScreen(template)` on the router's end event. ([#16](https://github.com/NCG-Africa/edge_telemetry_cordova_sdk/issues/16))

## 8. Transport — T

- **T1** JS hand-off: `enqueue` every **2 s or 20 events**, and immediately on `visibilitychange→hidden`, `pause`, and any captured `app.crash`. ([#9](https://github.com/NCG-Africa/edge_telemetry_cordova_sdk/issues/9))
- **T2** Outbox: append-only NDJSON segments in no-backup app storage (Android `filesDir/edge_rum/`; iOS Application Support, `isExcludedFromBackup`). Each hand-off appended + flushed. Torn trailing line discarded on read. No DB. ([#9](https://github.com/NCG-Africa/edge_telemetry_cordova_sdk/issues/9))
- **T3** Seal at **50 events or 30 s** after first event, and on background (Android `onPause`/`onStop`; iOS `didEnterBackground` inside `beginBackgroundTask`); leftovers sealed + sent on next launch. One send in flight, oldest first. One sealed segment = one batch. ([#9](https://github.com/NCG-Africa/edge_telemetry_cordova_sdk/issues/9))
- **T4** Identity frozen at seal: segment's first line = `app.version`/`build_number`/`name` + `device_id` at seal time; envelope uses it. `sdk`, `contract_version` current at send. Native crash / ANR / hang / renderer-death records = own single-record segment with the crashed build's identity (realizes R14). ([#9](https://github.com/NCG-Africa/edge_telemetry_cordova_sdk/issues/9))
- **T5** Envelope `timestamp` = UTC RFC 3339 `Z`, stamped per send attempt (R13). Body always gzip, `Content-Encoding: gzip`. POST to endpoint as given (R10), `X-API-Key`. ([#9](https://github.com/NCG-Africa/edge_telemetry_cordova_sdk/issues/9))
- **T6** R12: 429 / 5xx / network → 3 in-process attempts at 1 s / 4 s / 16 s + jitter, honour `Retry-After`; then park and retry on next trigger (launch, foreground, connectivity regained, 30 s tick). Other 4xx → delete, count. A parked segment never blocks newer ones beyond its backoff. No WorkManager / BGTaskScheduler. ([#9](https://github.com/NCG-Africa/edge_telemetry_cordova_sdk/issues/9))
- **T7** Caps: 5 MB or 200 segments, drop-oldest; segments > 7 days dropped. ([#9](https://github.com/NCG-Africa/edge_telemetry_cordova_sdk/issues/9))
- **T8** Every drop (JS pre-ready, exec failure, cap, age, 4xx) counted by reason and sent in the next normal batch as `sdk.health` (R4). ([#9](https://github.com/NCG-Africa/edge_telemetry_cordova_sdk/issues/9))
- **T9** No public knobs for T1–T7; native constants. ([#9](https://github.com/NCG-Africa/edge_telemetry_cordova_sdk/issues/9))

## 9. Sampling and caps — S

- **S1** One session-level roll at session start, native, secure RNG, persisted with the session id. Rate = `EdgeRumSampleRate`. No event-level sampling, no `init()` override. ([#14](https://github.com/NCG-Africa/edge_telemetry_cordova_sdk/issues/14))
- **S2** Exempt set (never sampled out, never capped): `session.started`, `session.finalized`, fatal `app.crash` (E9, E12, E13), `app.anr`, `app.exit`, `app.start`, `cordova.deviceready_timeout`, `sdk.health`. Handled `app.crash`, `app.hang`, metrics follow the roll. ([#14](https://github.com/NCG-Africa/edge_telemetry_cordova_sdk/issues/14))
- **S3** Wire: `session.sampled=true|false` on `session.started`/`session.finalized` only when rate < 1. No `sample_rate` attr. ([#14](https://github.com/NCG-Africa/edge_telemetry_cordova_sdk/issues/14))
- **S4** Per-session caps: non-fatal `app.crash` 5 per dedup key (`exception_type` + top frame, local only) + 50 total; `ui.interaction` 200; `bridge.call` 5 per service+action + 50 total; `custom_event` + host metrics + `task.complete` 500 combined. Uncapped: `http.request`, `navigation`, `screen.duration`, vitals, `frame.summary`, lifecycle, network. ([#14](https://github.com/NCG-Africa/edge_telemetry_cordova_sdk/issues/14))
- **S5** Sampling gate + caps enforced **natively at outbox append**, counters keyed by session id (survive WebView reload). ([#14](https://github.com/NCG-Africa/edge_telemetry_cordova_sdk/issues/14))
- **S6** `session.finalized` counters count what happened, before gates. ([#14](https://github.com/NCG-Africa/edge_telemetry_cordova_sdk/issues/14))
- **S7** Cap drops → `sdk.health` reasons `cap.error`, `cap.interaction`, `cap.bridge`, `cap.custom`. Sampled-out drops not counted. ([#14](https://github.com/NCG-Africa/edge_telemetry_cordova_sdk/issues/14))
- **S8** Breadcrumbs keep recording in sampled-out sessions. No public cap knobs. ([#14](https://github.com/NCG-Africa/edge_telemetry_cordova_sdk/issues/14))

## 10. Privacy and consent — P

- **P1** `http.url` (Flutter tier, `edge_telemetry_flutter/lib/src/capture/http_url.dart`): keep scheme + host + explicit port + path; drop query, fragment, userinfo; path segments that are all digits, a canonical UUID, or ≥ 20 hex → `{id}`. Host `sanitizeUrl(url)` runs after (can only remove more). ([#13](https://github.com/NCG-Africa/edge_telemetry_cordova_sdk/issues/13))
- **P2** Screen names (`navigation.*_screen`, `screen.name`, `ui.screen`): route part only (hash route if present, else path), query dropped, ids → `{id}` per P1. `screenName(path)` overrides. ([#13](https://github.com/NCG-Africa/edge_telemetry_cordova_sdk/issues/13))
- **P3** Request/response headers and bodies never captured. ([#13](https://github.com/NCG-Africa/edge_telemetry_cordova_sdk/issues/13))
- **P4** `ui.target` name chain `data-edge-action` → `aria-label` → `id` → visible text. Text only for `button`, `a`, `[role=button|link|tab|menuitem]`; never `input`/`textarea`/`select` values or `contenteditable`. Trim, 64-char cap, digits → `#`. Else tag name. Anything inside `[data-edge-private]` → no name. ([#13](https://github.com/NCG-Africa/edge_telemetry_cordova_sdk/issues/13))
- **P5** `beforeSend` (RN model, `edge_telemetry_react_native/src/core/beforeSend.ts`): sync, at JS enqueue before `exec`; `null` or throw → drop, counted in `sdk.health`; identity/session/sequence keys re-stamped after. JS events only; native-origin events bypass (documented). No automatic message regex scrubbing. ([#13](https://github.com/NCG-Africa/edge_telemetry_cordova_sdk/issues/13))
- **P6** `identify()`: `user.id` on every event; `name`/`email`/`phone` only on one `user.profile.update` per call where traits changed. Native persists until `clearUser()`. ([#13](https://github.com/NCG-Africa/edge_telemetry_cordova_sdk/issues/13))
- **P7** Consent: `EdgeRumEnabled=false` = opt-in mode — nothing captured or buffered, native handlers not armed, until `enable()` (persisted). `disable()` persists across launches, deletes unsent outbox + persisted traits. `reset()` rotates `device_id`, new session, clears user + outbox, stays enabled. No data-collection levels. ([#8](https://github.com/NCG-Africa/edge_telemetry_cordova_sdk/issues/8), [#13](https://github.com/NCG-Africa/edge_telemetry_cordova_sdk/issues/13))

## 11. Symbols — Y

- **Y1** Wire-ready only. No upload hooks, Xcode phases, Gradle tasks, upload API, Debug IDs. JS map key = R1 envelope + normalised path; optional `init({ release })` stamped as `release` on JS `app.crash`. ([#11](https://github.com/NCG-Africa/edge_telemetry_cordova_sdk/issues/11))
- **Y2** JS frame normalisation before batching (stack string + parsed frames): same-origin frames (`https://localhost`, `http://localhost`, `app://localhost`, `ionic://localhost`, `file:///…/www/`) → `app:///<path under www>`, line:col kept, query/hash stripped. Other origins untouched. No raw copy. ([#11](https://github.com/NCG-Africa/edge_telemetry_cordova_sdk/issues/11))
- **Y3** Native frames copy sibling formats: iOS `edge_telemetry_ios_sdk` StackFrames (image name, Mach-O UUID, base address, image-relative offset, `dladdr` hint); Android JVM raw Throwable stack; NDK ELF build-id + relative pc. ([#11](https://github.com/NCG-Africa/edge_telemetry_cordova_sdk/issues/11))

## 12. Tests — Q

- **Q1** JS unit: Vitest + jsdom, `cordova.exec` stubbed. Capture, batching, scrubbing, `beforeSend`, exempt routing, typings, terminology, pack audit (Ionic sibling `test/` set). Every PR. ([#15](https://github.com/NCG-Africa/edge_telemetry_cordova_sdk/issues/15))
- **Q2** JS browser harness: Playwright + mock-ingest, copied from `edge_telemetry_ionic_angular_capacitor/e2e`; fake native bridges `exec` to mock-ingest; pins the A2 action table. Every PR. ([#15](https://github.com/NCG-Africa/edge_telemetry_cordova_sdk/issues/15))
- **Q3** Native unit: Android JUnit (MockWebServer), iOS XCTest via `Package.swift` (URLProtocol stub). Outbox seal/replay, R12, caps → `sdk.health`, crash solo segment + frozen identity, device_id/session/sampling, envelope. **Golden-batch snapshot per event type** (iOS `GoldenBatchSnapshotTests` pattern). Every PR. ([#15](https://github.com/NCG-Africa/edge_telemetry_cordova_sdk/issues/15))
- **Q4** Device e2e: Android emulator + `adb` intent extras, iOS simulator + `xcrun simctl` URL scheme; Node assertions against mock-ingest; drives `example/`. Nightly + required on release tag. Gate = happy path + envelope on both platforms: `session.started`, phased `app.start`, `navigation`, `http.request`, `bridge.summary`; R1/R2 header, gzip, `sdk.name=cordova`, `contract_version=4.0.0`. No Appium. ([#15](https://github.com/NCG-Africa/edge_telemetry_cordova_sdk/issues/15))
- **Q5** `example/`: committed vanilla-JS plain Cordova app, hash router, plugin by local path; one button + deep link per scenario: JS error, native crash, renderer kill, ANR/hang, slow bridge call, offline toggle, rage/dead tap, `markReady`, task. ([#15](https://github.com/NCG-Africa/edge_telemetry_cordova_sdk/issues/15))
- **Q6** `docs/release-checklist.md`: manual run of every `example/` scenario on a real Android + iOS device, ticked in the release PR, required before `v1.0.0`. Covers native crash + relaunch, `WebViewTerminated`, offline replay/R12, ANR/hang, caps. ([#15](https://github.com/NCG-Africa/edge_telemetry_cordova_sdk/issues/15))

## 13. Release and versioning — V

- **V1** CI (GitHub Actions, every PR + push to main): `ubuntu-latest` `npm ci` → lint → typecheck → Q1 → esbuild → typings check → terminology check (N4) → pack audit → Q2 → Android Q3; fixture `cordova create` + `platform add android@15` + `plugin add <local>` + `cordova build android`; `macos-latest` same on `ios@8` (simulator, unsigned) + iOS Q3. Node pinned ≥ 20.17. ([#12](https://github.com/NCG-Africa/edge_telemetry_cordova_sdk/issues/12))
- **V2** Release: copy `edge_telemetry_react_native/.github/workflows/release.yml`. `vX.Y.Z` tag on `main`, tag == `package.json` version; re-run CI; `npm publish --access public --provenance` via npm trusted publishing (OIDC, Node 24); GH Release body from CHANGELOG (`gh release create --verify-tag`); `-rc.N` → `next` dist-tag. Tag ruleset limits `v*` to maintainers. ([#12](https://github.com/NCG-Africa/edge_telemetry_cordova_sdk/issues/12))
- **V3** `sdk.version` injected from `package.json` at build into the JS bundle and plugin metadata (single source); native reads it, never hard-coded. Contract major bump ⇒ package major bump. ([#12](https://github.com/NCG-Africa/edge_telemetry_cordova_sdk/issues/12))
- **V4** CHANGELOG.md, Keep a Changelog, `## X.Y.Z` headings. README = install, prefs, `init()`, API, floors, router recipes (C5). `docs/` = event catalogue, privacy, troubleshooting. Typings carry per-method docs. Release notes repeat sibling S2 (backend release first). ([#12](https://github.com/NCG-Africa/edge_telemetry_cordova_sdk/issues/12))

---

## 14. Reconciled conflicts

Earlier tickets disagreed in small ways; later or more specific decisions win.

| Conflict | Resolution |
|---|---|
| #15 names `session.start` / `screen.view` | Catalogue names `session.started` / `navigation` (E1, E4). |
| #13 `navigation.from\|to` | `navigation.from_screen` / `to_screen` (N1, #17 key rule). |
| #5 inference event `webview.terminated` | `app.crash cause=WebViewTerminated webview.detected_by=inference` (E13). |
| #6 "query stripped" for `http.url` | P1 (Flutter tier). |
| #6 "thresholds tunable in config" vs #9/#14 "no knobs" | Only C1 prefs and C2 `slowBridgeCallMs` / `frameSlowThresholdMs` are tunable; rest constants. |

## 15. Implementation order

Issues on this repo, labelled `impl`; blocking is native GitHub "blocked by". Each issue lists the rules it realizes.

```
01 Scaffold ─┬─▶ 02 And core ─▶ 03 And session/gates ─▶ 04 And crash/ANR ─▶ 05 And WebView/start ─┐
             ├─▶ 06 iOS core ─▶ 07 iOS session/gates ─▶ 08 iOS crash/hang ─▶ 09 iOS WebView/start ─┤
             └─▶ 10 JS core ─┬─▶ 11 JS errors ─────────────────────────────────────────────────────┤
                             ├─▶ 12 JS network ────────────────────────────────────────────────────┼─▶ 16 example + device e2e ─▶ 17 docs + release 1.0.0
                             ├─▶ 13 JS screens/taps ───────────────────────────────────────────────┤
                             └─▶ 14 JS performance ────────────────────────────────────────────────┤
                                 15 contract doc amendment (none) ─────────────────────────────────┘
```

| # | Issue | Rules | Blocked by |
|---|---|---|---|
| [01](https://github.com/NCG-Africa/edge_telemetry_cordova_sdk/issues/19) | Plugin scaffold, JS build, CI checks | K1–K7, N4, V1 (JS + fixture jobs), V3 | — |
| [02](https://github.com/NCG-Africa/edge_telemetry_cordova_sdk/issues/20) | Android native core: identity, envelope, outbox, sender | A2 (`getState`/`enqueue`/`configure`), W1–W4, T2–T9, R1–R16, Q3 | 01 |
| [03](https://github.com/NCG-Africa/edge_telemetry_cordova_sdk/issues/21) | Android session, sampling, caps, consent, user store | A2 rest, E1, E31, S1–S8, P6, P7, C1 | 02 |
| [04](https://github.com/NCG-Africa/edge_telemetry_cordova_sdk/issues/22) | Android crash, ANR, hang, exit, breadcrumb mirror | A3, E12, E14–E16, Y3, T4 | 03 |
| [05](https://github.com/NCG-Africa/edge_telemetry_cordova_sdk/issues/23) | Android renderer death, app.start, lifecycle, memory, network, deviceready timeout | A5, A7, E2, E3, E13, E17, E22–E24, E26, E32 | 04 |
| [06](https://github.com/NCG-Africa/edge_telemetry_cordova_sdk/issues/24) | iOS native core: identity, envelope, outbox, sender | as 02 | 01 |
| [07](https://github.com/NCG-Africa/edge_telemetry_cordova_sdk/issues/25) | iOS session, sampling, caps, consent, user store | as 03 | 06 |
| [08](https://github.com/NCG-Africa/edge_telemetry_cordova_sdk/issues/26) | iOS crash, hang, breadcrumb mirror | A3, E12, E15, Y3, T4 | 07 |
| [09](https://github.com/NCG-Africa/edge_telemetry_cordova_sdk/issues/27) | iOS content-process termination, app.start, lifecycle, memory, network, deviceready timeout | A5–A7, E2, E3, E13, E17, E22–E24, E26, E32 | 08 |
| [10](https://github.com/NCG-Africa/edge_telemetry_cordova_sdk/issues/28) | JS core: buffer, hand-off, public API, `beforeSend`, harness | A2, A4, A8, C2–C4, T1, T8, P5, P6, E27–E30, Q1, Q2 | 01 |
| [11](https://github.com/NCG-Africa/edge_telemetry_cordova_sdk/issues/29) | JS errors, `app:///` frames, breadcrumbs | E9–E11, A3 (JS side), Y1, Y2 | 10 |
| [12](https://github.com/NCG-Africa/edge_telemetry_cordova_sdk/issues/30) | JS network: fetch/XHR, URL scrub, traceparent, resource timing | E6–E8, P1, P3 | 10 |
| [13](https://github.com/NCG-Africa/edge_telemetry_cordova_sdk/issues/31) | JS screens and interactions | E4, E5, E25, P2, P4, C5 (unit tests only) | 10 |
| [14](https://github.com/NCG-Africa/edge_telemetry_cordova_sdk/issues/32) | JS performance: app.start phases, vitals, frames, bridge timing | A5 (JS side), E3, E18–E21 | 10 |
| [15](https://github.com/NCG-Africa/edge_telemetry_cordova_sdk/issues/33) | Contract doc: add `cordova` to R2 | W5 | — |
| [16](https://github.com/NCG-Africa/edge_telemetry_cordova_sdk/issues/34) | Example app, device e2e, release checklist | Q4–Q6 | 05, 09, 11–14 |
| [17](https://github.com/NCG-Africa/edge_telemetry_cordova_sdk/issues/35) | Docs, CHANGELOG, release workflow, publish 1.0.0 | V2, V4, C5 | 15, 16 |

JS (10–14) builds against the A2 table with the Q2 fake native, so it runs in parallel with both native tracks.

# Cordova competitor SDKs: how third parties monitor Cordova apps

Input for Cordova SDK 4.0.0 planning. Researched 2026-10-25 from source (GitHub clones, `npm pack` tarballs read as data, never run) and official docs. READMEs are used only where they are the vendor's docs. Where something could not be confirmed, the text says **unknown**. Companion to `docs/research/sibling-sdk-telemetry.md`.

## Citation legend

| Prefix | Expands to | Version / date looked at |
|---|---|---|
| `SC:` | https://github.com/getsentry/sentry-cordova/blob/3389b108da/ | 1.7.3, commit 2026-03-19 (repo **archived**) |
| `NR:` | https://github.com/newrelic/newrelic-cordova-plugin/blob/47bd828029/ | 7.1.13, commit 2026-10-23 |
| `DT:` | npm `@dynatrace/cordova-plugin@2.349.1` tarball, `package/` | 2.349.1, published 2026-10-21 |
| `AD:` | npm `appd-plugin-eum-mobile@25.4.1` tarball, `package/` | 25.4.1, published 2025-04-28 |
| `FXC:` | https://github.com/dpa99c/cordova-plugin-firebasex-crashlytics/blob/7c663cd030/ | 2.0.3, commit 2026-10-13 |
| `FXP:` | https://github.com/dpa99c/cordova-plugin-firebasex-performance/blob/f0af4793e6/ | 2.0.2, commit 2026-08-29 |
| `FX:` | https://github.com/dpa99c/cordova-plugin-firebasex/blob/18981bfa8b/ | 20.0.2 meta-plugin, commit 2026-06-06 |
| `RSC:` | https://github.com/ReallySmallSoftware/cordova-plugin-firebase-crashlytics/blob/566833f4f2/ | 1.2.0, commit 2020-08-07 |
| `RG:` | https://github.com/MindscapeHQ/raygun4js/blob/b12752cf0c/ | 3.1.4, commit 2026-04-21 |
| `BG:` | https://github.com/bugsnag/bugsnag-js/blob/8738aa6a5e/ | 9.1.0, commit 2026-10-13 |
| `IB:` | https://github.com/Instabug/Instabug-Cordova/blob/bcb42c1a6a/ | 15.1.2, commit 2025-09-16 (repo **archived**) |
| `CT:` | https://github.com/Countly/countly-sdk-cordova/blob/39326c0bf4/ | 22.09.0, commit 2023-04-04 (repo **archived**) |
| `CA:` | https://github.com/apache/cordova-android/blob/af7a3fb035/framework/src/org/apache/cordova/ | master, 2026-10-25 |
| `CI:` | https://github.com/apache/cordova-ios/blob/f9bb658eff/CordovaLib/Classes/ | master, 2026-10-25 |

Flag key (same as the sibling catalogue):
- **WV**: can be done from JS inside a Cordova WebView.
- **NAT**: needs a Cordova native plugin.
- **WV+NAT**: JS gives a partial answer; the full answer needs native code.

---

## 1. Summary matrix

| SDK | Maintained? | JS / native split | Network capture | Error capture | Native crash | Perf / vitals | Offline queue | Symbolication |
|---|---|---|---|---|---|---|---|---|
| Sentry `sentry-cordova` | **No.** npm-deprecated, repo archived 2026-03; says move to Capacitor | `@sentry/browser` 7.119.1 in WV + sentry-android / sentry-cocoa. JS envelopes go to the native transport | XHR/fetch **breadcrumbs only** (browser `breadcrumbsIntegration`). No spans unless the app adds tracing itself | `globalHandlersIntegration` (onerror + unhandledrejection), plus `browserApiErrors` wrapping timers/listeners | Yes: JVM, NDK, ANR, iOS app hang, watchdog/OOM | None by default | Yes, the native SDK disk outbox | Build hook: Debug ID inject + JS source-map upload. Xcode dSYM upload script. Stack paths rewritten to `app://` |
| New Relic `newrelic-cordova-plugin` | Yes (2026-10) | Thin JS patch layer + full NR native agents. All data goes through `cordova.exec` | JS monkey-patches XHR + fetch → native `noticeHttpTransaction`. Native agents' bytecode/swizzle instrumentation for native HTTP | `window` `error` + `unhandledrejection` → `recordError` (handled exception). console.* → NR Logs | Yes (native agents) | Native agent interactions/traces. iOS "WebView instrumentation" flag | Yes, native `OFFLINE_STORAGE_ENABLED` (default true), size cap API | Gradle plugin (ProGuard mapping), Xcode "New Relic dSYM Upload" phase. JS source maps **unknown** |
| Dynatrace `@dynatrace/cordova-plugin` | Yes (2026-10) | **Two agents**: closed RUM JavaScript is downloaded at build time and injected into `index.html`; OneAgent for Mobile runs natively. Sessions stitched with cookie / localStorage / User-Agent | RUM JS auto (XHR/fetch, closed source). Native HTTP plugins need manual `x-dynatrace`/`x-dtc` headers | RUM JS auto + `dtrum.reportError` | Yes (OneAgent) | RUM JS page loads / user actions; OneAgent app start + lifecycle | **unknown** (closed agents) | Not handled by the plugin (**unknown**) |
| AppDynamics `appd-plugin-eum-mobile` | **No.** End of support 2024-01-01 (still on npm, 2025) | Native agent `startFromHybrid` injects ADRUM JS into the WebView. JS API is a thin `exec` wrapper | Native agent forces WebView Ajax instrumentation (`ForceAjaxInstrumentation`); manual `HttpRequestTracker` | Via injected ADRUM (**unknown** detail) | Yes (native agent) | Timers, session frames, screenshots | **unknown** | Gradle `adeum` plugin (mapping) |
| Firebase Crashlytics (`cordova-plugin-firebasex-crashlytics`) | Yes (modular v20+; monolithic `firebasex` deprecated at v20) | Native SDKs. JS is a manual API only | n/a | **Manual.** `logError(msg, stackFrames)`. Docs say add your own `window.onerror` + stacktrace.js | Yes: JVM + **NDK**, iOS | n/a | Native SDK | Xcode dSYM run-script hook. JS frames sent as fake native frames, **no source maps** |
| Firebase Performance (`cordova-plugin-firebasex-performance`) | Yes | Native only. JS = custom traces | Native auto (iOS always; Android only with the opt-in Gradle plugin). WebView traffic is **probably not** captured (**unknown**, docs silent) | n/a | n/a | Custom traces/counters; native app start (SDK default) | Native SDK | n/a |
| ReallySmallSoftware `cordova-plugin-firebase-crashlytics` | **Stale** (last commit 2020) | Native + manual JS | n/a | Manual `logException(message)` | Yes | n/a | Native | **unknown** |
| Raygun `raygun4js` | Yes (2026-04), but **pure JS**, no Cordova plugin | WV only | XHR + fetch patch (RUM + breadcrumbs) | onerror (TraceKit) + unhandledrejection | **No** | RUM page/SPA timings, LCP/INP via `web-vitals` | Opt-in `saveIfOffline` → localStorage, flushed on next 202 | Server-side source maps from line+col |
| Bugsnag `@bugsnag/js` | JS yes. A Cordova plugin **no longer exists** (`bugsnag/bugsnag-cordova` 404, npm 404); only a 2015 community plugin | WV only | XHR/fetch breadcrumbs | onerror + unhandledrejection plugins | **No** | None in browser notifier | None in browser delivery (**unknown** retry) | Source maps (`@bugsnag/source-maps`) |
| Instabug `instabug-cordova` | **No.** Support ended 2025-06-30, repo archived | Native SDK + exec wrapper | **unknown** (no network API in JS modules) | Repro steps for crash reports | Yes (native) | n/a | Native | **unknown** |
| Countly `countly-sdk-cordova` | **No.** Sunset, archived 2023 | Native SDK + exec wrapper | Manual `recordNetworkTrace` | Manual `logException` (no auto onerror) | Yes (`enableCrashReporting`) | Manual `startTrace`, `enableApm` | Native SDK | **unknown** |

Excluded: no real Cordova support found for **Datadog** (RN/Flutter/browser only), **Embrace** (no Cordova SDK), **Splunk Observability RUM** (no Cordova page; AppD is Splunk's Cordova path), **Elastic APM RUM**, or **LogRocket**. All of these work only as generic browser JS inside a WebView.

---

## 2. Per SDK

### 2.1 Sentry `sentry-cordova` (deprecated)

- **Status.** README banner says "no longer maintained", points to Sentry Capacitor/RN/Flutter (SC:README.md:9-10). npm `deprecated` set. The repo is archived. It pins `@sentry/browser` 7.119.1, which is a v7 line (SC:package.json:26-32).
- **Split.** `init()` starts the native SDK first, then `@sentry/browser` (SC:src/js/sdk.ts:86-90). Native is sentry-android (default 7.22.6) and a bundled Sentry.xcframework (SC:plugin.xml:12, 42, 58).
- **JS capture.** Browser default integrations: inboundFilters, functionToString, browserApiErrors, breadcrumbs, globalHandlers, linkedErrors, dedupe, httpContext ([sentry-javascript 7.119.1 `packages/browser/src/sdk.ts:35-44`](https://github.com/getsentry/sentry-javascript/blob/7.119.1/packages/browser/src/sdk.ts#L35-L44)). Cordova adds SdkInfo, EventOrigin and Cordova (SC:src/js/sdk.ts:64-70). Network data is breadcrumbs only, with no automatic tracing.
- **Transport / offline.** JS envelopes are serialized to a byte array and sent over `Cordova.exec('captureEnvelope')` (SC:src/js/transports/cordova.ts:13-30). Android writes the bytes into the native SDK's **outbox directory** (SC:src/android/io/sentry/SentryCordova.java:67-89). iOS calls `PrivateSentrySDKOnly captureEnvelope` / `storeEnvelope` (SC:src/ios/SentryCordova.m:144-177). Result: JS events get the native offline cache and retry for free.
- **Scope sync.** `CordovaScope` mirrors setUser, setTag, setExtra and addBreadcrumb into native (SC:src/js/scope.ts:9-60). A native crash therefore carries JS breadcrumbs and the user.
- **Native.** Uncaught handler, ANR and NDK can be toggled (SC:src/android/io/sentry/SentryCordova.java:214-218). iOS app-hang and watchdog-termination options are passed through (SC:src/js/sdk.ts:27-55; SC:src/js/options.ts:41, 61). `attachThreads` defaults off so JS stacks are not hidden (SC:src/android/io/sentry/SentryCordova.java:207-211).
- **Tagging.** Every event gets `event.origin=cordova` and `event.environment=javascript|native` (SC:src/js/integrations/eventorigin.ts:21-24).
- **Symbolication.**
  - A `before_compile` hook hashes the www JS to make a release id, injects `window.SENTRY_RELEASE` into `index.html`, runs `sentry-cli sourcemaps inject` (Debug IDs), then uploads the maps (SC:scripts/before_compile.js:61-148; SC:plugin.xml:72).
  - The frame normalizer rewrites `file:///…/App.app/www/x.js` to `app:///www/x.js`, so stack paths stay the same across installs (SC:src/js/normalize.ts:2-30).
  - dSYM upload is done by `xcode-upload-debug-files.sh` (SC:scripts/xcode-upload-debug-files.sh:54).
- **Cordova signals.** None beyond the above: no deviceready, pause/resume or bridge timing.

### 2.2 New Relic `newrelic-cordova-plugin`

- **Status.** Active. 7.1.13 bundles Android agent 7.8.4 and iOS agent 7.7.9 (NR:CHANGELOG.md:1-5).
- **Config.** Install-time plugin preferences: crash reporting, distributed tracing, interaction tracing, `WEB_VIEW_INSTRUMENTATION`, `OFFLINE_STORAGE_ENABLED`, `CONSOLE_LOGS_ENABLED`, `BACKGROUND_REPORTING_ENABLED` and others (NR:plugin.xml:21-36). Android maps these to agent FeatureFlags and starts the agent with `ApplicationFramework.Cordova` (NR:src/android/NewRelicCordovaPlugin.java:56-123). The plugin is `onload=true`, so the agent starts before the page (NR:plugin.xml:105-106).
- **XHR.**
  - `open`/`send` are patched. Each request gets `traceparent`/`tracestate` from a W3C payload and is reported over `exec('noticeHttpTransaction')` (NR:www/js/newrelic.js:496-580).
  - The state lives in **one module-global `networkRequest` object** (NR:www/js/newrelic.js:495), so concurrent requests can overwrite each other. Do not copy this.
- **fetch.**
  - Before every fetch it waits on **two bridge round-trips** (`getHTTPHeadersTrackingFor`, `generateDistributedTracingHeaders`), which adds latency to every request.
  - It clones the response and reads the **full body** with `response.text()` (NR:www/js/newrelic.js:612-700). Do not copy this either.
- **Network failures.** Manual `noticeNetworkFailure` with a fixed enum: `BadURL`, `TimedOut`, `CannotConnectToHost`, `DNSLookupFailed`, `BadServerResponse`, `SecureConnectionFailed` (NR:www/js/newrelic.js:249-255).
- **Errors.** `window` `error` → `recordError`. On iOS it sends only `event.message`, no stack (NR:www/js/newrelic.js:586-601). `unhandledrejection` → `recordError(new Error(reason))` (NR:www/js/newrelic.js:604-607). Native records these as handled exceptions plus a `Supportability/Mobile/Cordova/JSError` counter (NR:src/android/NewRelicCordovaPlugin.java:246-279).
- **Console.** `console.log/warn/error/debug/assert` are wrapped and sent to NR Logs. Each call does a bridge round-trip to read the feature flag (NR:www/js/newrelic.js:138-160, 780-809).
- **Custom data.** `startInteraction`/`endInteraction`, breadcrumbs, custom events, metrics with units, `currentSessionId`, `setMaxOfflineStorageSize` and `setMaxEventBufferTime` (NR:www/js/newrelic.js:26-320).
- **deviceready.** Used only to fetch trace account IDs (NR:www/js/newrelic.js:763-769).
- **Native HTTP and symbols.**
  - Android: a hook injects the `com.newrelic.agent.android:agent-gradle-plugin` (bytecode instrumentation + mapping upload) into `app/build.gradle` (NR:hooks/android/android.js:36-44).
  - iOS: a hook adds a "New Relic dSYM Upload" build phase (NR:hooks/ios/ios.js:34, 72).
  - iOS can disable WebView instrumentation (NR:src/ios/NewRelicCordovaPlugin.m:53). What it records is **unknown** (closed agent).

### 2.3 Dynatrace `@dynatrace/cordova-plugin`

- **Status.** Active. Bundles OneAgent Android 8.349.1.1010 and iOS 8.349.1.1007 (DT:README.md changelog 2.349.1; DT:plugin.xml:39, 45).
- **Two-agent model.** The package says the mobile agent covers device and lifecycle, and RUM JS covers network calls (DT:package.json description; DT:README.md:5).
- **Build-time JS injection.**
  - The `after_prepare` hook runs the instrumentation (DT:plugin.xml:9-13).
  - It downloads RUM JavaScript from the tenant at **build time**, with retries (DT:scripts/DownloadAgent.js:66-146).
  - It prepends the script to `<head>` of each HTML file and removes any old copy (DT:scripts/html/HtmlModifier.js:94-124).
  - Live reload skips the injection (DT:README.md "Troubleshooting").
- **Android native instrumentation.** The Gradle plugin `com.dynatrace.instrumentation` runs with `instrumentationFlavor = 'cordova'` (DT:files/dynatrace.gradle:1-2).
- **Session stitching** (native ↔ WebView):
  - Cookies `dtAdk`/`dtAdkSettings` are set by OneAgent for the configured domains (DT:README.md:336-338).
  - iOS `DTXHybridApplicationMode=cookies` (default) injects JS into the WKWebView. `useragent` mode appends `DTHybrid/x.x dtAdk=… dtAdkSettings=…` to the UA (DT:README.md:342-366).
  - On custom schemes (`ionic://`, `capacitor://`) WebKit refuses the cookies, so OneAgent writes the session into **localStorage** instead (DT:README.md "iOS Session Correlation Issues").
  - The JS side reads `dtAdk` from cookie → UA → localStorage, in that order (DT:networking/NativeNetworkInterceptorUtils.js:7-21).
  - **Surprise:** WKWebView script injection breaks **Apple Pay**. The workaround is `useragent` mode (DT:README.md "Using Apple Pay with WebKit/WKWebView").
- **Cookie proxy.** Optional `dt-cookie-proxy.js` redefines `document.cookie` and mirrors Dynatrace cookies into sessionStorage, because cookies are unreliable in Cordova/Ionic WebViews (DT:scripts/snippets/dt-cookie-proxy.js:11-30; DT:README.md:232-247).
- **Native HTTP plugins** (`cordova-plugin-advanced-http`, `@ionic-native/http`, IBM MobileFirst):
  - These bypass RUM JS. The app must open an action and add headers by hand: `enterNativeRequestAction` → `getHeadersForNativeRequest` (`x-dtc`) → `leaveNativeRequestAction` (DT:README.md:646-683; DT:networking/NativeNetworkInterceptorUtils.js:89-126).
  - iOS native timing must then be turned off to avoid double counting (`DTXInstrumentWebRequestTiming=false`).
- **Lifecycle / API.**
  - Only the native agent can end a session (`endVisit`) (DT:README.md:532; DT:other/DynatraceCordovaPlugin.js:17-21).
  - Privacy: `DataCollectionLevel` + crash opt-in (DT:other/DynatraceCordovaPlugin.js:25-49; DT:model/).
  - iOS calls go through `window.webkit.messageHandlers.MobileAgent` when `window.MobileAgent` is undefined (DT:other/DynatraceCordovaPlugin.js:8-16).
- **Size cost.** About +0.2 MB on Android and about **+8.4 MB on iOS** (DT:README.md "Instrumentation Overhead").
- **Offline / symbolication.** **unknown** (closed agents; the plugin does not handle it).

### 2.4 AppDynamics `appd-plugin-eum-mobile` (end of support)

- **Status.** Security fixes only from 2023-01-01, unsupported from 2024-01-01 ([Splunk AppD notice](https://help-preview.splunk.com/en/appdynamics-saas/product-announcements-and-alerts/appdynamics-end-of-support-notices/end-of-support-notice-deprecation-of-the-cordova-plugin)). Still published to npm as 25.4.1 (2025-04).
- **Split.**
  - The native agent starts in `initialize` "before the Cordova WebView loads the default page" via `Instrumentation.startFromHybrid`, with `withJSAgentAjaxEnabled(true)` (AD:src/android/com/appdynamics/cordova/plugin/ADEUMMobilePlugin.java:48-100).
  - iOS Info.plist sets `ForceWebviewInstrumentation`, `ForceAjaxInstrumentation` and the ADRUM CDN URLs. The native agent injects the ADRUM JS agent into the WKWebView (AD:plugin.xml:54-61; [AppD Cordova docs](https://help.splunk.com/en/appdynamics-saas/end-user-monitoring/26.10.0/end-user-monitoring/mobile-real-user-monitoring/instrument-cordova-applications)).
- **JS API.** Thin `exec` wrapper: timers, `reportMetric`, breadcrumbs, user data, screenshots (block/unblock), `CallTracker`, `HttpRequestTracker` (manual network, including `withInstrumentationSource`), `startNextSession`, session frames, `crash`, `flush` (AD:www/ADEUMMobilePlugin.js:27-342).
- **Cordova signal.** `onReset()` (WebView navigated or reloaded) clears in-flight tracker handles (AD:src/android/com/appdynamics/cordova/plugin/ADEUMMobilePlugin.java:213-220; AD:src/ios/ADEUMMobilePlugin.m:81-87). This is the only competitor using `onReset`.
- **Hack.** `flush()` reports a fake request to `http://flush.queue` to kick the native queue (AD:…/ADEUMMobilePlugin.java:537-543).
- **Build.** The `adeum` Gradle plugin is applied through `build-extras.gradle` (AD:android_hooks/build-extras.gradle:1; AD:plugin.xml:40).

### 2.5 Firebase: `cordova-plugin-firebasex-*`, `cordova-plugin-firebase-crashlytics`

- **Status.** The FirebaseX monolith is deprecated at v20; the modular plugins replace it (FX:README.md:5-26). ReallySmallSoftware's plugin was last touched in 2020 (RSC).
- **Crashlytics (FXC).**
  - Native Crashlytics plus **NDK** (FXC:plugin.xml:45-51).
  - No automatic JS capture. `logError(message, stackTrace[])` (FXC:www/firebasex-crashlytics.js:81-92). The JS frames become Java `StackTraceElement`s with class `"undefined"` (FXC:src/android/JavaScriptException.java:47-63) or `FIRExceptionModel`/`FIRStackFrame` on iOS (FXC:src/ios/FirebasexCrashlyticsPlugin.m:93-125).
  - The README tells you to wire your own `window.onerror` with stacktrace.js (FXC:README.md:274-290). There are no JS source maps, so minified frames stay minified.
  - `didCrashOnPreviousExecution()` (FXC:www/firebasex-crashlytics.js:125-126).
  - dSYM upload run-script added on install (FXC:scripts/ios/after_plugin_install.js:10-14).
- **Performance (FXP).**
  - JS API is only `startTrace`, `incrementCounter`, `stopTrace` and the enable flag (FXP:www/firebasex-performance.js:28-81).
  - Automatic network monitoring is always on for iOS. On Android it needs the opt-in `firebase-perf-plugin` Gradle plugin, which the README warns slows builds (FXP:README.md:57-68).
  - Firebase docs say "each network request issued by your app" and say nothing about WebView ([firebase.google.com/docs/perf-mon/network-traces](https://firebase.google.com/docs/perf-mon/network-traces)). Whether WebView XHR/fetch is captured is **unknown**. It is likely not, because that traffic runs on the WebView's own network stack.
- **RSC.** `initialise(hasConsent)`, `logException(message)` (no stack), custom keys (RSC:www/*.js:9-35).

### 2.6 Raygun `raygun4js`

- **Status.** Active, but JS-only, with no Cordova plugin. The V1 docs name Cordova WebViews as the reason to keep the synchronous loader (RG:V1Documentation.md:3).
- **Capture.**
  - Errors: TraceKit `window.onerror` plus `unhandledrejection` (RG:src/raygun.js:192, 454-476).
  - Network: XHR patch (RG:src/raygun.network-tracking.js:71-73) and fetch replace, which respects a snippet-saved `__raygunOriginalFetch` (RG:src/raygun.network-tracking.js:141-245).
  - Vitals: LCP and INP via `web-vitals` (RG:src/raygun.rum/core-web-vitals.js:13-39). RUM is flushed on `visibilitychange` (RG:src/raygun.rum/index.js:151).
- **Offline.** Opt-in `saveIfOffline`. A failed send (anything except 400/403/429) is stored in localStorage under `raygunjs+<key>`. All saved errors are replayed after the next 202 response (RG:src/raygun.js:311-315, 564-605, 1018-1027; RG:README.md:695-707).
- **Surprise.** RUM drops every resource whose URL starts with `file://` (RG:src/raygun.rum/index.js:1249-1251). On `file://` Cordova builds (iOS legacy, Android before `AndroidInsecureFileModeEnabled=false`), all bundled assets disappear from RUM.
- **Symbolication.** Line + column are sent and source maps resolve them server-side (RG:README.md:689-693).

### 2.7 Bugsnag

- **Status.** No official Cordova SDK any more: `github.com/bugsnag/bugsnag-cordova` returns 404, npm `bugsnag-cordova` and `@bugsnag/cordova` return 404, and `docs.bugsnag.com/platforms/javascript/cordova/` returns 404 (checked 2026-10-25). The bugsnag-js packages list has no Cordova package (BG:packages/). The only remaining plugin is the community `cordova-bugsnag-plugin` 1.0.0 (2015), a native wrapper with `start`/`notify`.
- **What remains.** `@bugsnag/browser` in the WebView. Defaults: window-onerror, unhandled-rejection, console, network, navigation and interaction breadcrumbs, browser session, strip-query-string. Delivery is XHR or XDomainRequest (BG:packages/browser/src/notifier.js:17-35). No offline persistence in browser delivery (**unknown** whether there is retry).

### 2.8 Instabug, Countly (both dead)

- **Instabug.** Cordova support ended 2025-06-30 (IB:README.md:1-2). JS modules cover bug reporting, surveys, feature requests, replies and repro-step config for crashes (IB:src/modules/Instabug.ts:128-148). No network or JS-error auto-capture was found in the JS layer.
- **Countly.** Sunset and archived (CT:README.md:1). Everything is manual: `recordView`, `logException`, `enableCrashReporting` (native), `startTrace`, `recordNetworkTrace`, `enableApm` (CT:Countly.js:47-62, 330-376, 958-1034). It auto-binds `deviceready` (CT:Countly.js:1038).

---

## 3. Cordova-specific signals we do not have yet

Checked against the sibling catalogue (§1 matrix, §3.4, §3.5). Neither the siblings nor any competitor plugin source surveyed here emits these as first-class signals.

| Signal | Who does it / where it comes from | Flag | Notes |
|---|---|---|---|
| **WebView renderer crash** (Android) | Nobody, in plugin code. Cordova gives every plugin `onRenderProcessGone(view, detail)`, and the javadoc names crash reporting as the use case (CA:CordovaPlugin.java:468-479; CA:engine/SystemWebViewClient.java:442-450) | NAT | `detail.didCrash()` vs killed-by-OOM; `rendererPriorityAtExit`. With no handler the app crashes or is killed |
| **WKWebView content process terminated** (iOS) | Nobody. Cordova silently reloads the page or start page (`CrashRecoveryBehavior`) (CI:Private/Plugins/CDVWebViewEngine/CDVWebViewEngine.m:566-576) | WV+NAT | No public plugin hook (**unknown**), so native would need delegate swizzling. JS proxy: a page load where the sessionStorage "alive" marker exists but no `pagehide` was seen = unexpected reload |
| **WebView reset / reload** | AppD clears handles in `onReset` (§2.4) | NAT (WV proxy via page-load + session marker) | Also needed to stop in-flight span leaks across reloads |
| **deviceready latency** | Nobody measures it. NR and Countly only listen for it | WV | `deviceready − navigationStart`; native start → deviceready if the plugin records a native t0 |
| **Plugin bridge (`cordova.exec`) timing / failures** | Nobody | WV | Wrap `cordova.exec`: per-service/action duration, error-callback rate. Watch for chatty plugins |
| **Native HTTP plugin traffic** (`cordova-plugin-advanced-http` etc.) | Dynatrace: manual header API (§2.3) | WV (wrap plugin JS API) / NAT | Siblings only see fetch/XHR (Ionic is fetch-only) |
| **Native ↔ WebView session stitching** | Dynatrace cookie / UA / localStorage (§2.3) | WV+NAT | Matters if the native plugin also emits (crashes, cold start) |
| **JS crash trail on native crash** | Sentry scope sync (§2.1) | WV+NAT | Ionic persists native crashes but does not push JS breadcrumbs to native |
| **Previous-run crash flag** | Firebase `didCrashOnPreviousExecution` (§2.5) | NAT | Cheap `session.previous_crashed` attribute |
| **Network failure taxonomy** | NR `noticeNetworkFailure` enum (§2.2) | WV (coarse) + NAT | fetch `TypeError` cannot tell DNS from TLS from timeout; native can |
| **Console → logs** | NR (all levels), RN siblings (error, opt-in) | WV | Siblings: breadcrumbs only (Ionic) |
| **Stable stack file paths** | Sentry `app://` rewrite (§2.1) | WV | iOS bundle path contains a per-install UUID, which breaks grouping and source-map lookup |
| **Build release id injected into www** | Sentry hook (§2.1) | build hook | Ties JS events to uploaded source maps without app code changes |
| **Native disk outbox for JS events** | Sentry (§2.1), NR (§2.2) | NAT | Ionic uses native transport (sibling §3.4), so check whether it persists |
| **Privacy / data-collection levels** | Dynatrace `DataCollectionLevel` + crash opt-in (§2.3); RSC `initialise(hasConsent)` | WV | |
| **Pause/resume with `pendingResult`** | Nobody | WV | Cordova Android `resume` carries `pendingResult` when the Activity was killed during a plugin call (e.g. camera). A good "process died in background" signal ([Cordova events docs](https://cordova.apache.org/docs/en/latest/cordova/events/events.html)) |

---

## 4. Borrow list

| # | Idea | Source SDK | Flag | Why |
|---|---|---|---|---|
| 1 | Hand JS batches to a native disk outbox (write to file, native sends with retry) | Sentry, New Relic | NAT | Survives WebView kill and reload. One transport for JS and native |
| 2 | Mirror user, attributes and last-N breadcrumbs JS → native on change | Sentry `CordovaScope` | WV+NAT | Native crash / ANR reports get the JS trail and identity |
| 3 | Rewrite stack frame URLs to a stable `app:///www/…` form | Sentry `normalize.ts` | WV | Per-install bundle UUIDs otherwise break grouping and source-map matching |
| 4 | Cordova `before_compile` hook: inject release/Debug ID into `index.html` and upload source maps | Sentry | build hook | Symbolicated JS with no app code |
| 5 | Plugin hooks that add dSYM upload phase + Gradle mapping upload | Sentry, NR, Firebase | NAT/build | Native crash symbolication without manual Xcode/Gradle edits |
| 6 | Implement `onRenderProcessGone` → `webview.crash` event (`did_crash`, priority), persisted, sent next launch | Nobody (gap); Cordova API | NAT | Top Cordova-only failure mode, invisible today |
| 7 | iOS: detect unexpected reload (session marker without `pagehide`) → `webview.terminated` | Nobody (gap) | WV (+NAT later) | WKWebView content-process death auto-reloads silently |
| 8 | Handle `onReset` / page reload: close open spans as `abandoned`, clear handle maps | AppDynamics | NAT (+WV) | Prevents leaked spans and false-long durations |
| 9 | Start native agent in `initialize` with `onload=true` (before page load) | AppD, NR | NAT | Captures native cold start and crashes before JS loads |
| 10 | Join native and WebView sessions with one id via UA suffix or localStorage (not cookies on custom schemes) | Dynatrace | WV+NAT | Cookies fail on `ionic://`/custom schemes. Avoid WKUserScript injection (breaks Apple Pay) |
| 11 | Wrapper / header helper for native HTTP plugins (`cordova-plugin-advanced-http`) | Dynatrace | WV | That traffic misses fetch/XHR patches |
| 12 | `deviceready` latency metric (+ native t0 → deviceready) | Nobody (gap) | WV (+NAT) | Cordova-specific startup cost users feel |
| 13 | `cordova.exec` wrapper: per-plugin/action latency + failure counters (sampled) | Nobody (gap) | WV | Bridge stalls and failing plugins are a common Cordova perf/bug source |
| 14 | `session.previous_crashed` / last-exit attribute at start | Firebase | NAT | Cheap crash-free-session metric |
| 15 | Network failure categories (`timeout`, `dns`, `tls`, `connect`, `bad_url`) | New Relic | WV (coarse) + NAT | Better than `status=0` |
| 16 | Opt-in console capture (levels configurable) | New Relic | WV | Parity with RN siblings; cache the flag in JS (NR does a bridge call per log) |
| 17 | Data-collection level + crash opt-in API | Dynatrace | WV | Consent control, finer than on/off |
| 18 | `resume.pendingResult` → mark "process restored after kill" | Nobody (gap); Cordova event | WV | Shows Android background kills during plugin calls |

**Do not copy:** NR's module-global XHR state and per-fetch bridge round-trips, plus full response-body reads (NR:www/js/newrelic.js:495, 612-700). Raygun's `file://` resource filter (§2.6). Firebase's fake-native-frame JS errors with no source maps (§2.5).

# Cordova platform capabilities for monitoring

Input for Cordova SDK 4.0.0 planning (issue #4). Question: what can a Cordova app expose to a monitoring SDK on current cordova-android and cordova-ios (Android + iOS only)?

Researched 2026-10-25 from Apache source (shallow clones and npm tarballs, read as data, never run), the Cordova docs source, MDN browser-compat-data, and Android/Apple docs. Where something could not be confirmed, the text says **unverified**. Companion to `docs/research/sibling-sdk-telemetry.md` (what our SDKs emit) and `docs/research/cordova-competitor-sdks.md` (what vendors do). This note does not repeat those; it points to them with `sibling §x` / `competitor §x`.

## Citation legend

| Prefix | Expands to | Version / date looked at |
|---|---|---|
| `CA:` | https://github.com/apache/cordova-android/blob/af7a3fb035/framework/src/org/apache/cordova/ | master, 2026-10-25 (same commit as the competitor note). Released: 15.1.0 (npm, 2026-07-22) |
| `CAJ:` | https://github.com/apache/cordova-android/blob/af7a3fb035/cordova-js-src/ | Android `exec` / `platform` JS |
| `CAT:` | https://github.com/apache/cordova-android/blob/af7a3fb035/ (repo root) | build templates, defaults |
| `CI:` | https://github.com/apache/cordova-ios/blob/f9bb658eff/CordovaLib/Classes/ | master, 2026-10-25. Released: 8.1.1 (npm, 2026-07-07); master is 8.2.0 (release notes written, **not on npm yet**) |
| `CIH:` | https://github.com/apache/cordova-ios/blob/f9bb658eff/CordovaLib/include/Cordova/ | public headers |
| `CIJ:` | https://github.com/apache/cordova-ios/blob/f9bb658eff/cordova-js-src/ | iOS `exec` JS |
| `CIR:` | https://github.com/apache/cordova-ios/blob/f9bb658eff/ (repo root) | templates, Package.swift |
| `CJ:` | https://github.com/apache/cordova-js/blob/6785bca03f/src/ | shared `cordova.js` runtime |
| `CD:` | https://github.com/apache/cordova-docs/blob/6177f9a50e/www/docs/en/latest/ | docs source (= cordova.apache.org/docs/en/latest/), 2026-10-21 |
| `BCD:` | npm `@mdn/browser-compat-data@8.1.7` (`data.json`), published 2026-10-22 | `webview_android` / `webview_ios` columns (MDN compat tables are generated from this) |

Flag key (same as the sibling and competitor notes):
- **WV**: can be done from JS inside a Cordova WebView.
- **NAT**: needs a Cordova native plugin.
- **WV+NAT**: JS gives a partial answer; the full answer needs native code.

---

## 1. Lifecycle events

### 1.1 Document events (JS)

| Event | Android | iOS | Source / notes |
|---|---|---|---|
| `deviceready` | yes | yes | Sticky: late listeners fire at once (CJ:common/init.js:59; CD:cordova/events/events.md "deviceready") |
| `pause` | yes | yes | Android: `CA:CordovaWebViewImpl.java:480-492`. iOS: on `UIApplicationDidEnterBackground` (CI:Public/CDVViewController.m:534-539) |
| `resume` | yes | yes | Android only after a prior pause, or after Activity recreation (CA:CordovaWebViewImpl.java:495-510; CA:CordovaInterfaceImpl.java:113-135). iOS: on `WillEnterForeground` (CI:Public/CDVViewController.m:546-551) |
| `resign`, `active` | no | yes | iOS-only, `WillResignActive` / `DidBecomeActive` (CI:Public/CDVViewController.m:523-559). Undocumented in the events table but still fired |
| `backbutton`, `menubutton`, `searchbutton`, `volumeupbutton`, `volumedownbutton` | yes | no | Key dispatch at CA:CordovaWebViewImpl.java:625-648; channels bound in CAJ:platform.js. Volume/menu only fire once JS subscribes (override) |
| `startcallbutton`, `endcallbutton`, `activated` | no | no | Listed but not fired on either platform (CD:cordova/events/events.md support table) |
| `cordovacallbackerror` (window) | yes | yes | A plugin success/error callback threw. `event.error` = original error; `window.onerror` also fires (CJ:cordova.js:233-237; CD:cordova/events/events.md "cordovacallbackerror") |

Quirks that matter for telemetry:
- **iOS `pause` runs synchronously and late.** It is fired with `bNoDetach=true` (no `setTimeout`) from `didEnterBackground` (CI:Public/CDVViewController.m:538; CJ:cordova.js:143-158). The docs say native plugin calls, `console.log` and alerts made in a `pause` handler only run on resume (CD:cordova/events/events.md "pause → iOS Quirks"). That text predates WKWebView. Whether a `postMessage`-based `exec` from a pause handler reaches native before suspension on current iOS is **unverified**. Treat `pause` as "too late to call native". Flush on `visibilitychange` → `hidden` (iOS 14.5+, BCD) or on `resign` instead, and let a native plugin flush on its own `didEnterBackground`.
- **Android `KeepRunning=false` stops JS timers** on pause (`engine.setPaused(true)` → all WebViews; CA:CordovaWebViewImpl.java:488-491; default `true`, CA:CordovaActivity.java:304). A JS-only flush timer will not fire in the background in that mode.
- **Android `resume.pendingResult`.** When the OS kills the Activity while a plugin is waiting on another Activity (camera, file picker), the page reloads and `resume` carries `{pendingResult:{pluginServiceName, pluginStatus, result}}` (CA:ResumeCallback.java:57-58; CAJ:platform.js:105-120; CD:guide/platforms/android/index.md "Retrieving plugin callback results"). A `resume` with no `pendingResult` is also sent after a kill with no result (CA:CordovaInterfaceImpl.java:117-131). **Measurable signal:** `resume` in a page context that never saw `pause` means the process was killed in the background and restored. `pendingResult` names the plugin.
- **`deviceready` is a join of channels**, each observable: `onDOMContentLoaded`, `onNativeReady`, `onPluginsReady`, `onCordovaReady`, plus any `channel.waitForInitialization(...)` added by plugins (CJ:common/init.js:87-108; CJ:common/channel.js:105-130). cordova.js logs `deviceready has not fired after 5 seconds` and lists the unfired channels (CJ:common/init.js:35-42).

### 1.2 Native hooks a plugin gets

**Android, `CordovaPlugin`** (CA:CordovaPlugin.java):
- `initialize` / `pluginInitialize` (72). `onPause(multitasking)` / `onResume` (154, 162), `onStart` / `onStop` (168, 174), `onNewIntent` (180), `onDestroy` (186), `onSaveInstanceState` / `onRestoreStateForActivityResult` (198, 210), `onActivityResult` (233), `onConfigurationChanged` (396).
- `onReset` (362): called from `onPageStarted`, i.e. on every main-frame navigation or reload (CA:CordovaWebViewImpl.java:552-556).
- `onMessage(id, data)` (219) receives `onPageStarted`, `onPageFinished`, `onReceivedError` (including errorCode `-6` on a `LoadUrlTimeoutValue` timeout, default 20 s), `exit`, `spinner`, and others (CA:CordovaWebViewImpl.java:147-200, 552-580).
- `onRenderProcessGone(view, detail)` (479). See §5.
- No `onTrimMemory`: Cordova does not forward it. A plugin registers its own `ComponentCallbacks2` on the Application.
- **onload.** `<param name="onload" value="true"/>` makes the plugin start with the WebView, before the page loads. Otherwise it starts on first `exec` (CD:guide/platforms/android/plugin.md "Plugin Initialization and Lifetime"). Plugins that are not loaded **do not get** `onRenderProcessGone` or the lifecycle calls: `PluginManager` only calls plugins already in `pluginMap` (CA:PluginManager.java:630-644).

**iOS, `CDVPlugin`** (CIH:CDVPlugin.h; CI:Public/CDVPlugin.m):
- `pluginInitialize` (h:129). `onAppTerminate` (`UIApplicationWillTerminate`), `onMemoryWarning` (`UIApplicationDidReceiveMemoryWarning`), `onReset`, `dispose`, `handleOpenURL` (h:136-174; m:74-77).
- `onReset` fires on `CDVPluginResetNotification`, which is posted from `didStartProvisionalNavigation`: every navigation or reload, **including the auto-reload after a content-process crash** (CI:Private/Plugins/CDVWebViewEngine/CDVWebViewEngine.m:536-538).
- Notifications any object can observe: `CDVPageDidLoadNotification` (from `didFinishNavigation`), `CDVViewWill/DidAppear`, `CDVViewWill/DidDisappear`, layout and size-transition notifications (CIH:CDVPluginNotifications.h:23-33).
- Optional delegate methods: `shouldOverrideLoadWithRequest:navigationType:info:`, `willHandleAuthenticationChallenge:`, `overrideSchemeTask:` / `stopSchemeTask:` (h:237-349).
- No foreground/background callbacks on `CDVPlugin`. A plugin observes `UIApplication*` (or `UIScene*`, since cordova-ios 8 adds `CDVSceneDelegate`) notifications itself.
- `onload=true` plugins are created in `viewDidLoad` before `loadStartPage`, each timed with `CDVTimer` (CI:Public/CDVViewController.m:379-390; CD:guide/platforms/ios/plugin.md "Configuring Plugin Initialization Timing").

---

## 2. The `cordova.exec` bridge

### 2.1 How it works

| | Android | iOS |
|---|---|---|
| JS → native | `addJavascriptInterface` object `_cordovaNative.exec(secret, service, action, callbackId, argsJson)` (CA:engine/SystemWebViewEngine.java:247; CA:engine/SystemExposedJsApi.java:39-42). `prompt()` fallback mode (CAJ:exec.js:39-42, 96-101) | `window.webkit.messageHandlers.cordova.postMessage([callbackId, service, action, args])` (CIJ:exec.js:112-113; CI:Private/Plugins/CDVWebViewEngine/CDVWebViewEngine.m:196-218) |
| Blocking? | **Yes, synchronous.** The JS thread waits while `plugin.execute()` runs on the WebView's JavaBridge thread (CA:CordovaBridge.java:44-71; CA:PluginManager.java:138-167). Async work must move to `cordova.getThreadPool()` | **No.** `postMessage` returns at once. The command runs later on the main thread (CI:Public/CDVCommandQueue.m:180-198) |
| Native → JS | Queue drained by exec chaining (results returned from `exec`) or `evaluateJavascript` (EVAL_BRIDGE default) (CAJ:exec.js:56, 102-106; CA:NativeToJsMessageQueue.java:363-380) | `evaluateJavaScript` → `cordova.require('cordova/exec').nativeCallback(...)` → callback in a microtask (CIJ:exec.js:116-122) |
| Built-in slow-call log | `THREAD WARNING: exec() call to S.a blocked the main thread for Nms` when over 16 ms (60 ms with a debugger attached) (CA:PluginManager.java:52, 150-153). It actually blocks the JS/bridge thread, not the UI thread | `THREAD WARNING: ['%@'] took '%f' ms` when over 10 ms (CI:Public/CDVCommandQueue.m:194-197) |

**Result/status model** (CJ:cordova.js:176-238): `callbackStatus` is `NO_RESULT`, `OK`, `CLASS_NOT_FOUND_EXCEPTION`, `ILLEGAL_ACCESS_EXCEPTION`, `INSTANTIATION_EXCEPTION`, `MALFORMED_URL_EXCEPTION`, `IO_EXCEPTION`, `INVALID_ACTION`, `JSON_EXCEPTION` or `ERROR`. `keepCallback=true` keeps the entry in `cordova.callbacks` for streaming results (listeners, the Android `messageChannel`). Without it, the first result deletes the entry.

### 2.2 Failure paths

- **Unknown plugin**: Android → `CLASS_NOT_FOUND_EXCEPTION` to the error callback (CA:PluginManager.java:139-145). iOS logs `ERROR: Method '%@' not defined` and returns NO (CI:Public/CDVCommandQueue.m:189-192). What JS receives on iOS is **unverified**.
- **Bad action**: `execute()` returns false → `INVALID_ACTION` (Android, CA:PluginManager.java:154-157).
- **Thrown exception**: `JSONException` → `JSON_EXCEPTION`. Any other exception → `error(e.getMessage())` (CA:PluginManager.java:158-165).
- **Callback throws in JS**: `cordovacallbackerror` + `window.onerror` (CJ:cordova.js:233-237).
- **Exec before native ready** (Android): throws `exec() called without bridgeSecret` (CAJ:exec.js:67-72).
- **Page reload with calls in flight**: the callback map is reset and `callbackId` restarts at a random number (CJ:cordova.js:176-178). Late results are dropped silently (`if (callback)`). Both platforms' `onReset` fires.
- **Never answered**: nothing times out. A plugin that never calls back leaves a dangling entry in `cordova.callbacks`.

### 2.3 Can calls be timed or wrapped from JS? Yes (WV), with caveats

- **`window.cordova.exec` is a clobber of the `cordova/exec` module** (CJ:common/init.js:77-79). Plugins normally do `var exec = require('cordova/exec')` and keep the original function. Replacing `window.cordova.exec` therefore only catches app code that calls the global.
- **Swapping the module export**: `cordova.define.moduleMap['cordova/exec'].exports = wrapper` (CJ:scripts/require.js:67-82). This catches plugins whose module factory runs *after* the swap. Factories run lazily during `modulemapper.mapModules` (CJ:common/init.js:95-96), in `cordova_plugins.js` order. Ordering our `<js-module><runs/>` early is not guaranteed. Coverage is **unverified** and needs a spike.
- **Robust option, no ordering dependency.**
  - Every async exec registers `cordova.callbacks[service + n]`; the service name is the id prefix (CAJ:exec.js:90-93; CIJ:exec.js:103-107).
  - Every result passes through the global `cordova.callbackFromNative(callbackId, isSuccess, status, args, keepCallback)` (CJ:cordova.js:212).
  - So: replace `cordova.callbacks` with a `Proxy` whose `set` trap stamps start time + service, and wrap `cordova.callbackFromNative` to stamp end time + status.
  - The result is round-trip latency, error status code and keepCallback streams per service. The action name is not available on this path.
  - Calls with no callbacks are invisible here.
- **Android sync cost**: on Android the wall time of the `exec()` call itself equals native `execute()` time, so a wrapper sees it exactly. On iOS it is ~0 and only the round trip means anything.
- **Native timing (NAT)**: no public per-call hook in either `PluginManager` or `CDVCommandQueue`. A native plugin cannot time other plugins without swizzling or subclassing. Prefer JS.
- **Competitor gap "cordova.exec timing" (competitor §3).** Measure with the Proxy + `callbackFromNative` wrap above. Emit a sampled metric per service: `bridge.service`, `bridge.status`, `bridge.keep_callback`, `duration_ms`. Add a counter for error statuses. Add a gauge for outstanding non-keepCallback entries older than N seconds (catches plugins that never answer).

### 2.4 Own channel for SDK traffic

The SDK does not have to use `cordova.exec` for its own high-volume calls:
- **iOS:** a plugin can register its own `WKScriptMessageHandler` name. `updateWithInfo:` with `kCDVWebViewEngineScriptMessageHandlers` exists for this (CI:Private/Plugins/CDVWebViewEngine/CDVWebViewEngine.m:414-428), or the plugin can call `userContentController addScriptMessageHandler` directly.
- **Android:** `addJavascriptInterface` (applies from the next page load) or androidx.webkit `WebViewCompat.addWebMessageListener` (origin-scoped; androidx.webkit 1.14.0 is bundled, CAT:framework/cdv-gradle-config-defaults.json). Feature availability depends on the installed WebView version and is **unverified** per device.

---

## 3. plugin.xml, preferences, hooks, dependencies

**Preferences a plugin can read**
- Android: `this.preferences.getString/getBoolean/getInteger` (CA:CordovaPlugin.java:46).
- iOS: `self.commandDelegate.settings` (`cordovaSettingForKey:`), e.g. CI:Private/Plugins/CDVWebViewEngine/CDVWebViewEngine.m:184.
- These are the `config.xml` `<preference>` values (CD:config_ref/index.md "preference"). The ones that matter to us: `scheme`, `hostname`, `AndroidInsecureFileModeEnabled`, `KeepRunning`, `CrashRecoveryBehavior` (iOS, `refresh` default or `reload`), `InspectableWebview`, `AppendUserAgent` / `OverrideUserAgent`, `LoadUrlTimeoutValue`, `ErrorUrl`, `deployment-target`, `android-minSdkVersion` / `android-targetSdkVersion`, `GradlePluginKotlinEnabled`.
- Correction to the brief: there is no `AndroidScheme` preference. Android uses `scheme` (`http` or `https`, default `https`) (CA:ConfigXmlParser.java:181-195; CD:config_ref/index.md "scheme").

**Plugin variables**: `<preference name="EDGE_API_KEY" default="…"/>` in plugin.xml. Values come from `cordova plugin add … --variable EDGE_API_KEY=…` and are substituted as `$EDGE_API_KEY` into `<config-file>` (CD:plugin_ref/spec.md "preference", "variables"). The usual pattern is `<config-file target="config.xml"><preference name="EdgeApiKey" value="$EDGE_API_KEY"/></config-file>`, which makes the value readable at runtime through the preference APIs above. `$PACKAGE_NAME` is reserved.

**JS loading**: `<js-module>` with `<clobbers>`, `<merges>` or `<runs/>`. Modules are loaded as `<script>` tags by the plugin loader (CJ:common/pluginloader.js), so they appear in Resource Timing. They run before `deviceready` but **after** `cordova.js` and after any inline `<head>` script. Catching errors that happen before `cordova.js` needs either a snippet in the app's `index.html` (build hook, like Dynatrace and Sentry, competitor §2.1, §2.3) or native document-start injection: Android `WebViewCompat.addDocumentStartJavaScript` (**unverified** feature support per WebView version), or iOS `WKUserScript` at document start (Dynatrace reports this breaks Apple Pay, competitor §2.3).

**Hooks** (CD:guide/appdev/hooks/index.md; Context7 `/apache/cordova-docs`):
- Plugins may declare any hook type in `<hook type=…>`, globally or per platform: `before_/after_prepare`, `before_/after_compile`, `before_/after_build`, `before_/after_plugin_install`, `before_plugin_uninstall`, `before_run`, `before_deploy`, and the rest. Plugin install/uninstall hooks fire only for that plugin.
- Hooks are Node modules (`module.exports = ctx => Promise`).
- Build order: `before_build > before_prepare > after_prepare > before_compile > after_compile > after_build`.
- **Hooks run only through the cordova CLI.** An Xcode Archive or Android Studio build skips them.

**Symbol / map upload feasibility**

| Artifact | Where it appears | Best mechanism | Notes |
|---|---|---|---|
| JS source maps | Produced by the app's bundler into `www/` *before* `cordova prepare` | `after_prepare` hook: read `platforms/*/www/**/*.map`, upload, inject a release id into `index.html`, strip the maps from the shipped bundle | Sentry pattern (competitor §2.1). CLI-only, which is fine because `prepare` is always CLI |
| iOS dSYM | Xcode build / archive output | Add a **Run Script build phase** to the app target at `after_plugin_install` / `after_prepare` (edit pbxproj via `xcode` npm, as NR, Sentry and Firebase do, competitor §2.1, 2.2, 2.5) | A phase still runs on Xcode-only archives; a hook would not |
| Android R8 mapping | `app/build/outputs/mapping/<variant>/mapping.txt` | Gradle task wired in through `<framework src="edge.gradle" custom="true" type="gradleReference"/>` (CD:plugin_ref/spec.md "framework") | The Cordova app template does not enable `minifyEnabled` (no match in CAT:templates/project/app/build.gradle). Only apps that opt in to R8 need it |
| NDK symbols | only if the SDK or app ships `.so` | Gradle task | Out of scope unless we add an NDK handler |

**Native dependencies**
- Android: `<framework src="group:artifact:ver"/>` for Gradle deps, or `type="gradleReference"` for a custom `.gradle` file. Kotlin source needs the app to set `GradlePluginKotlinEnabled=true` (default false; CAT:framework/cdv-gradle-config-defaults.json; CD:config_ref/index.md). **Implication:** write the Android plugin in Java, or ship a prebuilt AAR (Kotlin inside an AAR does not need the app flag; **unverified** for Cordova 15, needs a spike).
- iOS:
  - CocoaPods via `<podspec>` / `<framework type="podspec">`. The docs warn that the CocoaPods trunk goes read-only after 2026-12-02 (CD:plugin_ref/spec.md "podspec").
  - **SPM since cordova-ios 8:** a plugin `Package.swift` + `<platform name="ios" package="swift">`, plus `nospm="true"` on pods for older platforms (CD:guide/platforms/ios/plugin.md "Supporting Swift Package Manager"; CD:plugin_ref/spec.md "platform", "pod").
  - Cordova itself is the SPM package `Cordova`, iOS 13+ (CIR:Package.swift).

---

## 4. WebView performance APIs

### 4.1 Support (BCD 8.1.7; Android WebView = Chromium version, WKWebView = iOS version)

| API | Android System WebView | WKWebView (iOS) | At our iOS floor (13.0)? |
|---|---|---|---|
| Navigation Timing L2 (`PerformanceNavigationTiming`) | 57 | 15.1 | No. Use L1 `performance.timing` (iOS 9) on 13–15.0 |
| `performance.timeOrigin` | 62 | 15 | No |
| Resource Timing | yes (4.4) | 11 | Yes |
| ↳ `transferSize` | 54 | 16.4 | No |
| ↳ `responseStatus` | 109 | **no** | — |
| ↳ `renderBlockingStatus` | 107 | **no** | — |
| ↳ `deliveryType` | 117 | 26.4 | No |
| Server-Timing | 65 | 16.4 | No |
| `PerformanceObserver` | 52 | 11 | Yes (`supportedEntryTypes` from 13) |
| Paint: `first-paint` | 60 | **no** | — |
| Paint: `first-contentful-paint` | 60 | 14.5 | No |
| LCP (`largest-contentful-paint`) | 77 | **26.2** | No |
| CLS (`layout-shift`) | 77 | **no** | — |
| Event Timing / INP (`event`, `interactionId`, `eventCounts`) | 76 / 96 / 85 | **26.2** | No |
| Long Tasks (`longtask`) | 58 | **no** | — |
| Long Animation Frames (`long-animation-frame`) | 123 | **no** | — |
| Element Timing | 77 | **no** | — |
| `performance.memory` (non-standard) | yes | **no** | — |
| `measureUserAgentSpecificMemory` | 89 (needs cross-origin isolation) | **no** | — |
| `visibilitychange` | 62 | 14.5 | No |
| `pagehide` | yes | yes | Yes |
| `sendBeacon` | 40 | 11.3 | Yes |
| `navigator.connection` / `deviceMemory` | 50 / 63 | **no** | — |
| `ReportingObserver` | 69 | 16.4 | No |
| `unhandledrejection` | 49 | 11.3 | Yes |

- Safari 26.2 (2025-12-12) added LCP and Event Timing. That is BCD plus secondary coverage ([ppc.land](https://ppc.land/major-browsers-achieve-cross-platform-parity-on-web-performance-metrics/), [Search Engine Journal](https://www.searchenginejournal.com/apple-safari-update-enables-tracking-two-core-web-vitals-metrics/563465/)). The Apple release-notes page did not render for the fetcher, so a WebKit primary source is **unverified**.
- WKWebView features track the iOS version. BCD's `webview_ios` column equals `safari_ios` for all rows above.
- Current versions per BCD: WebView 156 (2026-10-20); iOS Safari 27 (2026-09-14).
- **Bottom line:**
  - Android has the full Web Vitals and longtask/LoAF set.
  - iOS has FCP from 14.5, LCP/INP from 26.2, and **never** CLS, longtask, LoAF or JS heap.
  - This fixes the open "per-vital support is unverified" items in sibling §2.8 and §3.5.
  - On iOS, jank needs a rAF-gap detector (WV) or native `CADisplayLink` sampling (NAT, Ionic pattern, sibling §2.8).

### 4.2 Origin quirks

| | Android (default) | iOS (default) |
|---|---|---|
| Page origin | `https://localhost` (`scheme` `http`/`https`, `hostname` default `localhost`) (CA:ConfigXmlParser.java:181-195) | `app://localhost`. Scheme default `app` (CI:Public/CDVViewController.m:665). WebKit-reserved schemes such as `http`/`https` fall back to `app` (CI:Private/Plugins/CDVWebViewEngine/CDVWebViewEngine.m:172-189) |
| How assets are served | `WebViewAssetLoader` inside `shouldInterceptRequest`, plus a ServiceWorker client (CA:engine/SystemWebViewClient.java:76-131, 437-439) | `WKURLSchemeHandler` (`CDVURLSchemeHandler`), plugins can override with `overrideSchemeTask:` (CI:Private/Plugins/CDVWebViewEngine/CDVURLSchemeHandler.m) |
| Legacy `file://` | Only with `AndroidInsecureFileModeEnabled=true` (CA:engine/SystemWebViewEngine.java:162-169) | `scheme=file` (CI:Private/Plugins/CDVWebViewEngine/CDVWebViewEngine.m:175) |

Implications:
- **Stack trace paths are stable by default.** `https://localhost/main.js` and `app://localhost/main.js` contain no per-install UUID. Sentry's `app:///` rewrite (competitor §2.1, borrow #3) is only needed for `file://` builds. Normalise only when the scheme is `file`.
- **Every API call is cross-origin.** Requests go from `https://localhost` or `app://localhost` to `https://api…`.
  - CORS: servers must allow `Origin: https://localhost` (Android) and `Origin: app://localhost` (iOS).
  - Resource Timing detail is zeroed unless the server sends `Timing-Allow-Origin`: DNS/connect/TLS phases, `transferSize`/sizes, and `responseStatus` on Android. Use `*`, or list both origins.
  - Duration (`startTime → responseEnd`) is always available.
  - So the fetch/XHR wrapper (sibling §2.6) stays the source of truth for status and timing. Resource Timing only adds phases where TAO is set.
- **Local assets** appear in Resource Timing on Android as `https://localhost/...` (served via interception, so network phases ≈0). Whether WebKit emits Resource Timing entries for `app://` scheme-handler loads is **unverified**; Raygun-style `file://` filters (competitor §2.6) do not apply.
- **Navigation Timing** for the start page reflects interception or scheme-handler latency, not the network. Useful values: `responseEnd`, `domContentLoadedEventEnd`, `loadEventEnd`.
- **Cookies on `app://`** are unreliable (competitor §2.3, Dynatrace). Keep session state in JS memory, localStorage, or the native plugin.
- **Mixed content / secure context:** `https://localhost` is a secure context. Whether WebKit treats `app://` as secure for `sendBeacon`, `crypto.randomUUID` and similar is **unverified**; feature-detect.

---

## 5. Native-only visibility

| Signal | Android | iOS | Notes |
|---|---|---|---|
| Native crash | `Thread.setDefaultUncaughtExceptionHandler` (chain the previous one). NDK needs a signal handler / native lib. `ApplicationExitInfo` (API 30+) gives exit reasons on next launch ([docs](https://developer.android.com/reference/android/app/ApplicationExitInfo)) | `NSSetUncaughtExceptionHandler` + POSIX signal/Mach handlers (PLCrashReporter/KSCrash class), or MetricKit `MXCrashDiagnostic` (iOS 14+, delivered next launch) ([docs](https://developer.apple.com/documentation/metrickit/mxcrashdiagnostic)) | Sibling Android/iOS SDKs already do this (sibling §1, §3.4). Persist, then send on next launch |
| ANR / hang | Main-thread watchdog. `ApplicationExitInfo.REASON_ANR` | Main run-loop watchdog. MetricKit `MXHangDiagnostic` | **JS jank is not an ANR.** JS runs on the renderer thread (separate process on modern Android/iOS), so a busy JS loop does not block the app main thread. Exception: Android `exec()` blocks JS, not UI (§2.1) |
| WebView renderer hang | androidx.webkit `WebViewRenderProcessClient.onRenderProcessUnresponsive` (API 29+, feature-gated) ([docs](https://developer.android.com/reference/androidx/webkit/WebViewRenderProcessClient)) | none public | Android: NAT, no conflict with Cordova's `WebViewClient`. iOS: JS heartbeat to native; a missed heartbeat while foregrounded = hang (WV+NAT) |
| **WebView renderer death** | `onRenderProcessGone(view, detail)` (API 26+). `detail.didCrash()` vs OOM-kill, `rendererPriorityAtExit()` ([docs](https://developer.android.com/reference/android/webkit/WebViewClient#onRenderProcessGone(android.webkit.WebView,%20android.webkit.RenderProcessGoneDetail))). Cordova fans out to every **loaded** plugin; if none returns `true`, the app crashes (crash) or is killed (OOM) (CA:engine/SystemWebViewClient.java:441-450; CA:PluginManager.java:622-644) | `webViewWebContentProcessDidTerminate`, handled privately by `CDVWebViewEngine`: silent `reload` or start-page reload per `CrashRecoveryBehavior` (CI:Private/Plugins/CDVWebViewEngine/CDVWebViewEngine.m:566-576) | See measurement notes below |
| Memory pressure | `ComponentCallbacks2.onTrimMemory` (plugin registers it; Cordova does not forward). `ActivityManager.getProcessMemoryInfo` | `CDVPlugin.onMemoryWarning` (CI:Public/CDVPlugin.m:75). `DispatchSource.makeMemoryPressureSource` | The renderer / WebContent process memory is **not** in the app process footprint. Its OOM shows up as renderer death above |
| Cold start | `Process.getStartUptimeMillis()` (API 24, which is exactly our floor) → `CordovaActivity.onCreate` → `onPageStarted` / `onPageFinished` (`onMessage`) → `deviceready`. `ApplicationStartInfo` API 35+ | Process start via `sysctl` `kinfo_proc` → `viewDidLoad` (onload plugins, `CDVTimer` "TotalPluginStartup") → `CDVPageDidLoadNotification` → `deviceready`. MetricKit `MXAppLaunchMetric` (aggregate) | Ionic and siblings: sibling §2.3 |
| Warm start / resume | `onResume` → `resume` → next rAF | `willEnterForeground` → `resume` → next rAF | WV proxy is fine. NAT gives the true start |
| Native network | Only clients the SDK can instrument: OkHttp interceptor / event listener, or bytecode instrumentation for everything else (NR/Dynatrace Gradle plugins, competitor §2.2, §2.3) | `URLProtocol` registration or `URLSession` swizzling | Covers `cordova-plugin-advanced-http`-style plugins (competitor §3) |
| WebView fetch/XHR seen natively? | **Partial only.** `shouldInterceptRequest` sees URL, method and headers but **not** request bodies and **not** the response or timing unless the plugin performs the request itself (it returns `WebResourceResponse`) ([docs](https://developer.android.com/reference/android/webkit/WebViewClient#shouldInterceptRequest(android.webkit.WebView,%20android.webkit.WebResourceRequest))). Cordova's override routes only to `WebViewAssetLoader` (CA:engine/SystemWebViewClient.java:437-439), so a plugin cannot hook it without replacing the client | **No.** WKWebView networking runs in a separate process. `URLProtocol` does not see it. `WKURLSchemeHandler` cannot register `http`/`https` (CI:Private/Plugins/CDVWebViewEngine/CDVWebViewEngine.m:179) | WebView traffic stays a **WV** signal (fetch/XHR patch), as in sibling §2.6 |

### Getting the WebView instance without breaking Cordova

- **Android:** `webView.getView()` (CA:CordovaWebView.java:42) is an `android.webkit.WebView` (`SystemWebView`) with the default engine.
  - Do **not** call `setWebViewClient` / `setWebChromeClient`. That replaces `SystemWebViewClient` and loses asset loading, the allow-list and `onRenderProcessGone` fan-out.
  - Use the `CordovaPlugin` callbacks and the androidx.webkit side APIs (render-process client, message listener) instead.
- **iOS:** `self.webView` / `self.webViewEngine.engineWebView` (CIH:CDVPlugin.h:70-83) is the `WKWebView`.
  - **Replacing `navigationDelegate` breaks Cordova.** `decidePolicyForNavigationAction` only consults plugins' `shouldOverrideLoadWithRequest` while `webView.navigationDelegate == self` (CI:Private/Plugins/CDVWebViewEngine/CDVWebViewEngine.m:603-605). A forwarding proxy fails this identity check, so the plugin hooks are skipped.
  - `updateWithInfo:` can swap the delegate (CI:…/CDVWebViewEngine.m:432-434) but has the same problem.
  - Safe: add your own script message handler; observe notifications; KVO on `WKWebView` properties.
  - To catch content-process termination, **swizzle `-[CDVWebViewEngine webViewWebContentProcessDidTerminate:]`** (private class; call the original afterwards). Unsupported, so it needs a guard against class or selector renames.

### Measuring the competitor gaps (competitor §3)

- **Android renderer crash / kill:** an `onload=true` plugin implements `onRenderProcessGone`.
  - Write `{did_crash, priority_at_exit, url, ts}` to disk synchronously, and return **false** so Cordova's default (crash or kill) happens. Send the record on the next launch as `webview.crash`.
  - Returning `true` would mean taking over WebView recreation, which Cordova does not support.
  - Combine with `ApplicationExitInfo` on the next start (API 30+) to confirm.
- **iOS content-process termination (silent reload):**
  - NAT: the swizzle above, or detect `onReset` with no JS-initiated navigation since the last `CDVPageDidLoad`. Counter + event `webview.terminated` with `recovery=refresh|reload`.
  - WV fallback (competitor borrow #7): a sessionStorage "alive" marker plus a missing `pagehide` on the previous page means an unexpected reload. sessionStorage survival across a content-process crash is **unverified**; localStorage is safer.
- **`deviceready` latency:**
  - WV: `deviceready` time on the `performance.now()` clock, which is relative to navigation start (`timeOrigin`). Also time each channel (`onDOMContentLoaded`, `onNativeReady`, `onPluginsReady`, `onCordovaReady`, plugin `waitForInitialization` channels) by subscribing from our `<runs/>` module (CJ:common/channel.js) and report which channel was last.
  - NAT adds native t0 → `onPageStarted` / `didStartProvisionalNavigation` → `deviceready`.
  - A `deviceready` that has not fired after 5 s (cordova.js's own threshold, CJ:common/init.js:35-42) becomes an error event listing the unfired channels.
- **`cordova.exec` timing:** §2.3.

---

## 6. Version floors

| Component | Latest | Floors it implies | Source |
|---|---|---|---|
| cordova-android | **15.1.0** (2026-07-22); 15.0.0 2026-03-06 | minSdk **24** (Android 7.0), target/compile **36**, AGP 8.10.1, Gradle 8.14.2, Kotlin 2.1.21 (off by default), Java 11 source/target, JDK 17 to build, androidx.webkit 1.14.0 | CAT:framework/cdv-gradle-config-defaults.json; CD:guide/platforms/android/index.md "Android API Level Support" |
| cordova-ios | **8.1.1** (2026-07-07); 8.0.0 2025-11-23; 8.2.0 on master, unreleased | iOS **13.0** deployment target. Xcode ≥ 15. CocoaPods ≥ 1.16 or SPM. Template sets `IPHONEOS_DEPLOYMENT_TARGET[sdk=*27.*] = 15.0`, i.e. 15.0 when built with the iOS 27 SDK | CIR:Package.swift (`.iOS(.v13)`); CIR:templates/project/App.xcodeproj/project.pbxproj:347-348; CD:guide/platforms/ios/index.md |
| cordova CLI | **13.0.0** (2025-11-25) | Node `>=20.17.0 \|\| >=22.9.0` | npm `cordova@13.0.0` package.json `engines` |

**WebView engines those floors imply:**
- **Android:** minSdk does not fix the engine. System WebView updates through Play.
  - On Android 7–9 the WebView provider is Chrome ([Chromium WebView FAQ](https://chromium.googlesource.com/chromium/src/+/80.0.3987.149/android_webview/docs/faq.md)).
  - Chrome 119 was the last for Android 7 ([ghacks](https://www.ghacks.net/?p=203825)). Chrome 138 was the last for Android 8–9; 139+ needs Android 10 ([heise](https://heise.de/-10457380), [Android Authority](https://www.androidauthority.com/chrome-dropping-support-android-8-9-3571442)).
  - So API 24–25 devices are stuck at ≤ M119 and API 26–28 at ≤ M138. All of these are still ≥ 77, so every Chromium perf API in §4.1 exists except LoAF (123) on Android 7.
  - That the WebView itself follows the same cutoffs as Chrome is **unverified** (secondary sources; a third-party mirror lists WebView 139 as Android 10+).
  - Read the real version at runtime: UA `Chrome/x`, or natively `WebViewCompat.getCurrentWebViewPackage()`.
- **iOS:** WebKit = OS version. The iOS 13 floor means no Nav Timing L2 below 15.1, no FCP below 14.5, and no LCP/INP below 26.2. Report `webview.version` as the OS version.

---

## 7. Capability matrix

**JS** = visible from WebView JS (WV). **NAT** = needs a native plugin. **WV+NAT** = JS proxy, native for the full answer. **—** = not available.

| Signal | Android | iOS |
|---|---|---|
| deviceready latency + channel breakdown | JS | JS |
| Native t0 → deviceready (true startup) | NAT | NAT |
| pause / resume / fg-bg | JS (timers stop if `KeepRunning=false`) | JS (`pause` too late for native; use `visibilitychange` / `resign`) |
| Killed-in-background-and-restored | JS (`resume` w/o prior `pause`, `pendingResult`) | NAT (no equivalent event; `ApplicationExitInfo`-style data only from MetricKit, **unverified** fit) |
| Hardware buttons (back/menu/volume) | JS | — |
| `cordova.exec` latency / status per service | JS | JS |
| Plugin callback threw | JS (`cordovacallbackerror`) | JS |
| WebView navigation / reload (`onReset`) | WV+NAT | WV+NAT |
| Start-page load failure / timeout | NAT (`onReceivedError`, `-6`) | NAT (`didFailNavigation`; Cordova only logs, or loads `ErrorUrl`) |
| JS errors / unhandled rejections | JS | JS |
| fetch / XHR | JS | JS |
| Resource Timing phases (cross-origin) | JS if server sends TAO | JS if TAO; no `responseStatus` |
| Navigation Timing L2 | JS | JS (iOS 15.1+; L1 below) |
| FCP | JS | JS (14.5+) |
| FP | JS | — |
| LCP | JS | JS (26.2+) |
| INP / Event Timing | JS | JS (26.2+) |
| CLS | JS | — |
| Long tasks / LoAF | JS | — (rAF-gap proxy JS) |
| JS heap | JS (`performance.memory`) | — |
| Frames / jank | JS (rAF) + NAT (Choreographer) | JS (rAF) + NAT (CADisplayLink) |
| Native crash (JVM / NSException) | NAT | NAT |
| Native crash (NDK / signal / Mach) | NAT | NAT |
| ANR / main-thread hang | NAT | NAT |
| WebView renderer unresponsive | NAT (API 29+) | WV+NAT (heartbeat) |
| WebView renderer / content-process death | NAT (API 26+, `onRenderProcessGone`) | NAT via swizzle (unsupported); WV proxy (unexpected reload) |
| Memory warning | NAT (`onTrimMemory`) | NAT (`onMemoryWarning`) |
| Process memory (PSS/footprint) | NAT | NAT |
| Network type | JS (`navigator.connection`) + NAT | NAT (no `navigator.connection`) |
| Native HTTP (OkHttp / URLSession / HTTP plugins) | NAT | NAT |
| WebView traffic seen natively | — (`shouldInterceptRequest` taken by Cordova; no response/body) | — |
| JS source-map upload | build hook | build hook |
| dSYM / R8 mapping upload | Gradle task (R8 opt-in) | Xcode run-script phase |

---

## 8. Implications for decisions

- **#5 SDK architecture (JS vs JS + native plugin):**
  - JS-only covers deviceready, exec timing, errors, network, vitals (Android full; iOS FCP/LCP/INP only on recent OS) and lifecycle.
  - The top Cordova-specific failures need native code: renderer/content-process death, native crash, ANR, true cold start, memory pressure, and a background flush on iOS (`pause` is too late).
  - Recommend **JS core + optional `onload=true` native plugin**, Java on Android (avoids the `GradlePluginKotlinEnabled` dependency), plus an SPM package with CocoaPods `nospm` fallback on iOS.
  - The iOS termination hook means swizzling a private Cordova class. Gate it behind a version check.
- **#6 Telemetry catalogue:**
  - Add `webview.crash` (Android, `did_crash`, `priority_at_exit`) and `webview.terminated` (iOS, `recovery`).
  - Add `cordova.deviceready` (duration + `last_channel`) and `bridge.call` (sampled; `service`, `status`, `duration_ms`).
  - Add `app.restored_after_kill` (Android `resume` without `pause`, `pending_plugin`).
  - Mark CLS/longtask/LoAF/JS-heap as Android-only, and LCP/INP as iOS 26.2+. Do not emit "0"s where the API is missing.
- **#7 Contract 4 fit:**
  - Context should carry `webview.engine` (`chromium`|`webkit`) and `webview.version` (Chromium major from UA or native; iOS version on iOS), plus `cordova.platform_version` (`cordova.platformVersion`) and `cordova.scheme`.
  - On a JS-only install, app `package_name`/`version`/`build_number` and a durable `device_id` need native (or `cordova-plugin-device`/`app-version` plugins).
- **#8 Public API and configuration:**
  - Config sources: plugin variables → `config.xml` preference → read natively, plus JS `init()`.
  - Document the CORS/TAO server requirements for both origins (`https://localhost`, `app://localhost`).
  - Expose an `exec` instrumentation opt-out and a sample rate.
  - Normalise stack paths only for `file://`.
- **#9 Transport, batching, offline queue:**
  - Flush on `visibilitychange:hidden` / `pagehide` / `resign`, not `pause`.
  - With `KeepRunning=false`, JS timers are frozen in the background.
  - A native disk outbox (competitor borrow #1) survives renderer death and silent reloads. JS-only must use localStorage and replay after reload.
  - Use an SDK-owned message handler instead of `cordova.exec` for bulk transfer.
- **#10 Packaging and distribution:**
  - Floors: cordova-android ≥ 15 (minSdk 24, target 36), cordova-ios ≥ 8 (iOS 13; 15 with the iOS 27 SDK), cordova CLI ≥ 13, Node ≥ 20.17.
  - Ship SPM-first for iOS (CocoaPods trunk read-only after 2026-12-02).
  - Symbol upload: `after_prepare` hook for JS maps; Xcode run-script phase for dSYM (hooks don't run on Xcode archives); a Gradle task only when the app enables R8.

## Unverified (needs a spike or primary source)

1. iOS: whether an `exec` / `postMessage` from a `pause` handler reaches native before suspension on WKWebView (docs text predates WKWebView).
2. iOS: what JS receives for an unknown plugin method.
3. Coverage of swapping `define.moduleMap['cordova/exec'].exports` (plugin factory ordering).
4. Kotlin-in-AAR without `GradlePluginKotlinEnabled` on cordova-android 15.
5. Whether WebKit emits Resource Timing for `app://` scheme-handler loads, and whether `app://` counts as a secure context.
6. Whether sessionStorage survives WKWebView content-process termination.
7. WebView (not Chrome) cutoffs for Android 7 (≤ M119) and 8–9 (≤ M138).
8. A WebKit/Apple primary source for LCP and Event Timing in Safari 26.2 (BCD + secondary only).
9. androidx.webkit feature availability (`addDocumentStartJavaScript`, `addWebMessageListener`, render-process client) per installed WebView version.
10. MetricKit as an iOS "killed in background" signal.

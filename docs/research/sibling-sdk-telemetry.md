# Sibling SDK telemetry catalogue

Baseline for the Cordova SDK 4.0.0 (Android + iOS, WebView JS + optional native plugin). Everything below comes from the sibling source code as it stands on disk (2026-10-25). READMEs were not used. Where something is not known, the text says **unknown**.

## Citation legend

Paths are relative to `/Users/mktowett/Development/edge_rum/`. Prefixes:

| Prefix | Expands to |
|---|---|
| `A:` | `edge_telemetry_android/telemetry_library/src/main/java/com/androidtel/telemetry_library/` |
| `I:` | `edge_telemetry_ios_sdk/Sources/` |
| `F:` | `edge_telemetry_flutter/lib/src/` |
| `FA:` | `edge_telemetry_flutter/android/src/main/kotlin/com/ncgafrica/edge_telemetry_flutter/EdgeTelemetryFlutterPlugin.kt` |
| `FI:` | `edge_telemetry_flutter/ios/Classes/EdgeTelemetryFlutterPlugin.swift` |
| `R:` | `edge_telemetry_react_native/src/` |
| `X:` | `edge_telemetry_ionic_angular_capacitor/packages/` (core = WebView JS, capacitor = bridge + native plugin, angular = framework glue) |

Flag key:
- **WV**: can be done from JS inside a Cordova WebView.
- **NAT**: needs a Cordova native plugin.
- **WV+NAT**: JS gives a partial answer; the full answer needs native code.

---

## 1. Cross-SDK matrix (wire names)

`E:` = event (`eventName`), `M:` = metric (`metricName`). "—" = not emitted.

| Event type | Android | iOS | Flutter | React Native | Ionic/Capacitor | Flag |
|---|---|---|---|---|---|---|
| Session start | E:`session.started` | E:`session.started` | E:`session.started` | E:`session.started` | E:`session.started` | WV |
| Session end | E:`session.finalized` | E:`session.finalized` | E:`session.finalized` | E:`session.finalized` | E:`session.finalized` | WV |
| App lifecycle fg/bg | — | E:`app_lifecycle` | E:`app_lifecycle` | E:`app_lifecycle` | E:`app_lifecycle` | WV |
| App start (native cold start) | E:`app.start` | E:`page_load` + M:`launch_interactive` | E:`page_load` (M:`performance.startup_time` is dropped, see §3.6) | E:`app.start` | `lifecycle.cold_start_ms` attribute on the first `app_lifecycle` | NAT (true cold start) |
| Web page load (Navigation Timing) | — | — | — | — (retired, R:core/telemetry.ts:131-137) | E:`page_load` | WV |
| Screen / navigation | E:`navigation` | E:`navigation` | E:`navigation` | E:`navigation` | E:`navigation` | WV |
| Screen dwell | E:`screen.duration` | — (removed) | attribute on `navigation` | E:`screen.duration` | E:`screen.duration` | WV |
| View rollup | — | — | — | E:`view` | — | WV |
| Screen load / readiness | — | M:`screen_ready` | E:`screen.load` | `view.loading_time` attribute on `view` | — | WV |
| HTTP request | E:`http.request` | E:`http.request` | E:`http.request` | E:`http.request` | E:`http.request` | WV (JS) / NAT (native HTTP) |
| HTTP resource timing | — | M:`resource_timing` | — (on the canon list, never emitted) | — (retired) | M:`resource_timing` | WV |
| JS / unhandled error | n/a | n/a | E:`app.crash` (Dart) | E:`app.crash` | E:`app.crash` (`runtime:webview`) | WV |
| Handled / manual error | E:`app.crash` (`handled=true`) | E:`app.error` | E:`app.crash` (`is_fatal=false`) | E:`app.error` | E:`app.crash` (`handled=true`) | WV |
| console.error | — | — | — | E:`app.error` (opt-in) | breadcrumb only | WV |
| Native crash (JVM / NDK / signal / Mach) | E:`app.crash` | E:`app.crash` (replayed) | E:`app.crash` (native channel) | — | E:`app.crash` (`runtime:native`) | NAT |
| ANR (Android) | E:`app.anr` | n/a | `app.crash` with `cause=ANR` | — | `app.crash` with `cause=ANR` | NAT |
| Hang (main thread) | E:`app.hang` | E:`app.hang` | `app.crash` with `cause=Hang` (iOS MetricKit) | — | `app.crash` with `cause=Hang` (iOS) | NAT |
| Process exit reasons | E:`app.exit` | — | feeds `app.crash` | — | — | NAT |
| Long task | — | M:`long_task` | M:`long_task` (frozen frames, diagnostic tier) | — (retired) | M:`long_task` | WV (Chromium only) / NAT |
| Frames / jank | E:`frame.summary` | M:`frame_render_time` | E:`frame.summary` | M:`frame_render_time` | M:`frame_render_time` | WV (rAF) + NAT |
| Memory | M:`memory_usage`, M:`system_memory_available`, E:`memory_pressure`, E:`storage_usage` | M:`memory_usage` | M:`memory_usage` | M:`memory_usage` | M:`memory_usage` | WV (Chromium heap only) + NAT |
| CPU | — | M:`cpu_usage` | — | — | — | NAT |
| Web Vitals (LCP/INP/CLS/FCP/TTFB) | — | — | — | M:`LCP` `FCP` `TTFB` `CLS` `INP` (web build) | M:`LCP` `INP` `CLS` `FCP` `TTFB` | WV |
| User interaction (tap/click) | E:`ui.interaction` | E:`user.interaction` | E:`ui.interaction` | E:`ui.interaction` | E:`user.interaction` | WV |
| Network change | — | E:`network_change` | E:`network_change` (M:`network.quality_score` is dropped) | E:`network_change` | E:`network_change` | WV+NAT |
| Custom event | caller's own name, passed through | E:`custom_event` + `event.name` | E:`custom_event` + `event.name` | E:`custom_event` (anything off the allowlist is renamed to it) | E:`custom_event` + `event.name` | WV |
| Custom metric / timer | M:(any name) | M:`custom_timer` + `timer.name` | M:(name), dropped unless on the canon list | M:(any name) | M:(host name) via `time()` | WV |
| User profile / identity | E:`user.profile.update` | E:`user.profile.update` | E:`user.profile.update` | E:`user.profile.update` | E:`user.profile.update` | WV |
| Journeys / actions / tasks | trace keys only | E:`action.started` / `action.ended` | E:`task.complete` | trace keys only | — | WV |
| SDK health | E:`telemetry.capabilities_initialized` | E:`sdk.health` | counters on `session.finalized` | `sdk.*` counters on every row | `sdk.*` counters on `session.finalized` | WV |
| Device / app / network context | attributes | attributes | attributes | attributes | attributes | WV+NAT |
| Breadcrumbs (crash trail) | `crash.breadcrumbs` | `breadcrumbs` | `crash.breadcrumbs` | `error.breadcrumbs` | `crash.breadcrumbs` | WV |

Sources for every cell are in §2.

---

## 2. Per event type

### 2.1 Session start / end — WV

| SDK | Attributes | Technique / rotation | Cite |
|---|---|---|---|
| Android | started: `session.id, session.start_time, session.is_first_session, session.total_sessions, network.type`. finalized: `session.id, session.duration_ms, session.reason=timeout` | ProcessLifecycleOwner `onStart` timeout check. Persisted in SharedPreferences and resumed after process death | A:core/TelemetryManager.kt:504-514, 521-537, 559-579; A:core/services/SessionService.kt:45-64 |
| iOS | started: `session.rotation`. finalized: `session.id, session.start_time, session.sequence, session.end_time, session.rotation` | Rotation reasons `idle` (30 min) and `max_duration` | I:EdgeRumCore/Recorder.swift:424-434, 807-829; I:EdgeRumCore/Context/SessionContext.swift:72, 106-108 |
| Flutter | started: `session.id, session.start_time`. finalized: `session.{id,start_time,end_time,duration_ms,event_count,error_count,crash_count,screen_count,http_request_count,screen_journey,dropped_item_count,dropped_reasons,cardinality_capped_count,last_screen_duration_ms,recovered}` | 30 min idle timeout. Open tasks are abandoned on finalize | F:managers/session_manager.dart:125, 181-183, 430-449, 524-549 |
| RN | started: `session.reason ∈ launch\|idle\|max_duration, sdk.trace_allowlist_size`. finalized: `session.duration_ms, session.event_count, sdk.error_count, session.reason` | 30 min idle / 4 h max. Persisted record in the Store, which is `localStorage` on web | R:core/telemetry.ts:27-30, 79-80, 821-847 |
| Ionic | started: `session.start_reason ∈ init\|rotation_timeout\|resumed`. finalized: `session.{id,start_time,sequence,duration_ms,ended_at,end_reason∈backgrounded\|app_closed}, sdk.{error_count,dropped_count,disposed_captures}` + journey `session.{visited_screens,screen_count,event_count,metric_count,journey_truncated}` | 30 min timeout. Finalizes on **every** background. localStorage/sessionStorage | X:core/src/EdgeRum.ts:170; X:capacitor/src/LifecycleCapture.ts:174-225, 237-262; X:core/src/session/SessionManager.ts:3, 33-37, 214-231 |

Session context stamped on every event: Android `session.{id,start_time,duration_ms,event_count,metric_count,screen_count,visited_screens,is_first_session,total_sessions}` (A:core/TelemetryHttpClient.kt:216-225). iOS `session.{id,sequence,start_time}` (I:EdgeRumCore/Context/SessionContext.swift:178-180). RN `session.{id,start_time,sequence,sample_rate}` (R:core/telemetry.ts:1279-1284). Ionic `session.{id,start_time,sequence,is_first_session,total_sessions}` (X:core/src/session/SessionManager.ts:224-231). Flutter `session.*` snapshot (F:managers/session_manager.dart:597-612).

ID formats: Ionic `session_<ms>_<hex16>_<platform>` and `user_<ms>_<hex16>` (X:core/src/session/SessionIdGenerator.ts:30-32, 50-52). Android device-id fallback is a UUIDv4 (A:core/ids/IdGenerator.kt:86-94, R9). Other formats were not traced (**unknown**).

### 2.2 App lifecycle (foreground/background) — WV

| SDK | Attributes | Technique | Cite |
|---|---|---|---|
| Android | **not emitted**. Lifecycle only drives session, flush and ANR watchdog | `ProcessLifecycleOwner` `onStart`/`onStop` | A:core/TelemetryManager.kt:457-458, 559-618 |
| iOS | `lifecycle.state ∈ inactive\|backgrounded\|foregrounded\|active\|will_terminate`, `lifecycle.previous_state` | NotificationCenter `UIApplication.*Notification` | I:EdgeRumCapture/LifecycleCapture.swift:8-12, 99-123, 149-179 |
| Flutter | `lifecycle.state` = `AppLifecycleState.name` | `WidgetsBindingObserver.didChangeAppLifecycleState` | F:capture/lifecycle_capture_hook.dart:73, 97-113 |
| RN | `app_lifecycle.state ∈ foreground\|background` (only on a transition) | RN `AppState` (native) / `visibilitychange` (web) | R:adapters/appLifecycle.ts:5-9, 30-31 |
| Ionic | `lifecycle.event ∈ foreground\|background`; `lifecycle.cold_start_ms` on the first foreground | `@capacitor/app` `appStateChange`, falling back to `document.visibilitychange`. `pagehide`/`beforeunload` beacon: sync XHR on iOS, `navigator.sendBeacon` elsewhere | X:capacitor/src/LifecycleCapture.ts:237-262, 297-358, 368-389 |

Cordova note (not from sibling code): Cordova core fires `pause`/`resume` DOM events without any extra plugin. That puts this event in WV.

### 2.3 App start / cold start — NAT (true), WV (proxy)

| SDK | Wire | Attributes | Technique | Cite |
|---|---|---|---|---|
| Android | `app.start` | `app.start.type` (only `cold` today), `app.start.duration_ms` + launch trace keys | `Process.getStartUptimeMillis()` → first `Activity.onResume`. Dropped when importance at init > VISIBLE or duration > 60 s | A:core/TelemetryManager.kt:414-439; A:core/startup/AppStartTracker.kt:34-53 |
| iOS | `page_load` | `page_load.duration_ms, page_load.prewarmed, page_load.source=displaylink, launch.pre_sdk_duration_ms` | SDK launch instant → first `CADisplayLink` tick while active; `p_starttime` for the pre-SDK portion | I:EdgeRumCapture/PageLoadCapture.swift:3-21, 229-233, 268-269 |
| iOS | M:`launch_interactive` | `value` = ms, set by the host | Manual API | I:EdgeRum/EdgeRum.swift:452 |
| Flutter | `page_load` | `startup.{type,time_to_first_frame_ms,duration_ms,timestamp,first_frame}` | `addPostFrameCallback` at SDK init. `type` is a heuristic: `<2000ms` → warm | F:capture/perf_capture_hook.dart:32, 40-57, 75-76 |
| RN | `app.start` | trace keys only (`trace.id, span.id, rum.action.id, trace.root_type=launch, span.start_time`), no duration key | Once per process | R:core/telemetry.ts:720-728; R:adapters/traceManager.ts:120-121 |
| Ionic | (attribute) | `lifecycle.cold_start_ms` = first foreground − JS module load time | JS module-load timestamp. **Excludes native and WebView boot** | X:capacitor/src/LifecycleCapture.ts:9, 248-252 |

### 2.4 Web page load — WV (Ionic only)

Ionic `page_load`: `page.ttfb_ms, page.dom_content_loaded_ms, page.load_duration_ms, page.resource_count, page.route`, built from `performance.getEntriesByType('navigation')` after `load` (X:core/src/instrumentation/pageload.ts:3-9, 26-40, 78-92). RN retired the name (R:core/telemetry.ts:131-137). **The same wire name means native cold start on iOS and Flutter.** See §3.2.

### 2.5 Navigation / screen view — WV

| SDK | Attributes | Technique | Cite |
|---|---|---|---|
| Android | `navigation.{from_screen,to_screen,method,route_type,has_arguments,timestamp}` + trace | `ActivityLifecycleCallbacks`, Fragment observer, Compose `NavController` | A:core/TelemetryActivityLifecycleObserver.kt:66-75; A:core/TelemetryFragmentLifecycleObserver.kt:32; A:core/TelemetryManager.kt:698-712 |
| iOS | `navigation.screen, navigation.kind ∈ uikit\|swiftui\|manual, navigation.previous_screen` | Swizzles `UIViewController.viewDidAppear`/`viewWillDisappear`; `trackScreen()` | I:EdgeRumCapture/UIViewControllerCapture.swift:3-20, 287-295; I:EdgeRum/EdgeRum.swift:405-412 |
| Flutter | `navigation.{to,from,method,type=route_change,timestamp}, route.type, route.has_arguments, screen.previous_duration_ms, screen.previous_exit_method` | `NavigatorObserver` | F:widgets/edge_navigation_observer.dart:113-160 |
| RN | `navigation.{from_screen,to_screen,method,route_type}` | React Navigation ref (native). On web, `history.pushState`/`replaceState` patch + `popstate` | R:adapters/navigationTracker.ts:13-17; R:adapters/screenTiming.ts:21-25; R:adapters/web/navigationWeb.web.ts:40-65 |
| Ionic | `navigation.{to_screen,from_screen,method,route_type,has_arguments,timestamp}` | Angular Router `NavigationStart`/`NavigationEnd`, method from `navigationTrigger` (popstate → back); `trackScreen()` | X:angular/src/RouterCapture.ts:90-145; X:core/src/EdgeRum.ts:316-334 |

**Screen dwell** (`screen.duration`: `screen.name, screen.duration_ms, screen.exit_method, screen.timestamp`):
- Android: A:core/TelemetryManager.kt:729-738.
- RN: R:adapters/screenTiming.ts:54-57.
- Ionic: X:core/src/EdgeRum.ts:480-492, driven by Ionic `ionViewDidEnter`/`ionViewDidLeave` (X:angular/src/IonicLifecycleCapture.ts:11-12, 51-57).
- iOS removed it; the processor derives dwell from `navigation` (I:EdgeRumCapture/UIViewControllerCapture.swift:15-17).
- Flutter moved it onto `navigation` and no longer emits it (F:core/wire_canon.dart:26-31).

**RN `view`** (single row per view): `view.{host,referrer,load_type,name_source,time_spent,loading_time,loading_time_outcome,error_count,action_count,request_count}`. Every RN row also carries `view.id`/`view.name` (R:adapters/viewManager.ts:242-256; R:core/telemetry.ts:1277-1278). `view.loading_time` = in-flight fetch/XHR settle (R:adapters/loadingTime.ts:1-12).

**Flutter `screen.load`**: `screen.name, screen.id, screen.load.{outcome,source,first_frame_ms,settled_ms}` via `addPostFrameCallback` (F:capture/screen_load_hook.dart:141, 235-256). **iOS `screen_ready`** is a host-gated readiness metric (I:EdgeRumCore/Riders.swift:78).

### 2.6 HTTP request — WV for JS traffic; NAT for native-stack traffic

| SDK | Attributes | Technique | Cite |
|---|---|---|---|
| Android | `http.url` (query stripped), `http.method, http.status_code, http.duration_ms, http.success (200-299), http.request_size, http.response_size` + `traceparent` trace keys, `span.start_time, span.duration_ms` | OkHttp `Interceptor`; injects W3C `traceparent`; skips the collector host | A:core/TelemetryInterceptor.kt:32-80, 93-97 |
| iOS | `http.method, http.host, http.path, http.status_code, http.duration_ms, http.request_size, http.response_size, http.from_cache, http.error_domain, http.error_code, http.redirect_count, http.tls_protocol, http.tls_cipher, http.reused_connection, http.proxy_connection, http.network_protocol, http.request_body_bytes_before_encoding, http.cellular_fallback` | Global `URLProtocol` subclass + swizzle of `URLSessionConfiguration.default/.ephemeral`; reads `URLSessionTaskMetrics`; background sessions not covered. No traceparent | I:EdgeRumCapture/HTTPCapture.swift:7-16, 188, 335-353, 393-418 |
| Flutter | `http.url, http.url_redacted, http.method, http.status_code, http.duration_ms, http.{download,connect,dns,queue}_ms, http.connection_reused, http.redirect_count, http.timestamp, http.error, http.response_size, http.response_size_source, http.success, http.seam` | `HttpOverrides.global` (dart:io) + `CapturedClient` (`package:http` BaseClient); `traceparent` injection | F:capture/http_overrides.dart:26, 1192-1215; F:capture/http_client_capture.dart:37; F:capture/trace_injection.dart:17 |
| RN | `http.method, http.status_code (0 = no response), http.duration_ms, http.success (200-399), http.route` (normalized path), `http.host, http.request_size, http.response_size` + span keys. **No `http.url`** | `XMLHttpRequest.prototype.open/send/setRequestHeader` patch (native; RN fetch rides XHR). On web, `window.fetch` + XHR patch. Allowlisted `traceparent` | R:adapters/httpAttributes.ts:88-121; R:adapters/xhrIntercept.ts:61-148; R:adapters/web/interceptFetchWeb.web.ts:21, 47-49, 101 |
| Ionic | `http.url` (sanitized), `http.method, http.status_code (0 on throw), http.duration_ms, http.success (200-399), http.timestamp` | **`globalThis.fetch` patch only. No XHR.** Ignores own endpoint + `ignoreUrls` | X:core/src/instrumentation/requests.ts:3-10, 34-36, 48-97; X:core/src/EdgeRum.ts:206-230 |

**Resource timing** (metric `resource_timing`):
- iOS, per request, from `URLSessionTaskMetrics`: `resource.{host,dns_ms,connect_ms,tls_ms,ttfb_ms,download_ms,redirect_count,transaction_count,fetch_start_to_response_end_ms,protocol}` (I:EdgeRumCapture/HTTPCapture.swift:355-373).
- Ionic, via `PerformanceObserver('resource')`: `metric.{unit,resource_name,resource_type,screen,transfer_size}` (X:core/src/instrumentation/perf-observer.ts:67-91).

Cordova note: HTTP made by native plugins (for example a native HTTP plugin) never passes through WebView `fetch`/XHR, so a JS patch cannot see it.

Ionic sends its own batches through `CapacitorHttp` (a native request) instead of WebView fetch (X:capacitor/src/capacitor-http-fetch.ts:21-31). That is the closest precedent for a Cordova native transport. The code shown does not say why (CORS or another reason); **reason unknown**.

### 2.7 Errors and crashes

**JS / Dart / runtime errors — WV**

| SDK | Wire | Attributes | Technique | Cite |
|---|---|---|---|---|
| Ionic | `app.crash` | `exception_type, message, stacktrace, is_fatal=false, handled=false, error_context=screen:<route>, cause ∈ UnhandledError\|PromiseRejection\|ManualCapture\|AngularError\|NavigationError, runtime=webview, crash.breadcrumbs, crash.breadcrumb_count` | `window` `error` + `unhandledrejection` listeners; Angular `ErrorHandler`; Router `NavigationError`. Flushed immediately | X:core/src/instrumentation/errors.ts:4-15, 52-116; X:angular/src/ErrorCapture.ts:51-67; X:angular/src/RouterCapture.ts:161-171; X:core/src/internal/collector.ts:8, 68-72 |
| RN | `app.crash` (unhandled), `app.error` (`captureError`, `console.error` opt-in) | `error.type, error.source ∈ global_handler\|unhandled_rejection\|cross_origin\|console\|reported…, error.message, error.stacktrace, error.fatal` (native only), `error.breadcrumbs`. **No `handled` key: the event name carries it** | `ErrorUtils.setGlobalHandler` + `unhandledrejection` / `promise` rejection-tracking (native); `window.onerror`/`unhandledrejection` (web); console patch | R:adapters/crashCapture.ts:12-17, 99-128, 145-178; R:adapters/native/crashHandlerNative.native.ts:15-41; R:adapters/web/crashHandler.web.ts:21-25; R:core/telemetry.ts:553, 1115 |
| Flutter | `app.crash` | `message, stacktrace, exception_type, cause=Error, is_fatal=false, handled, error.category, error.category_source, crash.source`, `crash.breadcrumbs`. All values are strings | `FlutterError.onError`, `PlatformDispatcher.onError`, `Isolate.addErrorListener` | F:core/edge_event.dart:257-278, 337-357; F:facade/edge_telemetry.dart:379-405; F:core/collector.dart:243 |
| iOS | `app.error` (manual) | `error.class, error.message, error.kind ∈ nserror\|swift, error.domain, error.code, error.stack, error.stack.truncated, error.binary_images` | `EdgeRum.captureError()`; stack from the call site | I:EdgeRum/EdgeRum.swift:503-520; I:EdgeRumCore/AppErrorBuilder.swift:64-95 |
| Android | `app.crash` (handled) | `message, stacktrace, exception_type, cause, error_context, is_fatal, handled, crash.breadcrumbs` | `trackError()` / `recordCrash()` | A:core/services/CrashReportingService.kt:197-214, 253-260 |

**Native crashes — NAT** (all persist to disk at crash time and replay on the next launch)

| SDK | Attributes | Technique | Cite |
|---|---|---|---|
| Android | the error keys above + `crash.thread, crash.is_main_thread` + `device.{battery_level,battery_charging,power_save,thermal_status,orientation}` | `Thread.setDefaultUncaughtExceptionHandler` → single-event batch frozen to a file, replayed (WorkManager fallback) | A:core/services/CrashReportingService.kt:81, 99-130; A:core/device/DeviceStateSnapshot.kt:36-59; A:core/retry/CrashReplay.kt:34 |
| iOS | `crash.{report_format_version,signal,signal_code,exception_name,exception_reason,mach_exception,timestamp,os_version,binary_uuid,binary_name,registers.dropped,binary_images.dropped,report_json}`, `breadcrumbs` | PLCrashReporter; replayed with the crashed build's `app` identity (R14) | I:EdgeRumCrash/CrashReportEncoder.swift:75-129; I:EdgeRumCrash/PLCrashIntegration.swift:184; I:EdgeRumCore/Breadcrumbs.swift:176-182 |
| Flutter | `message, stacktrace, exception_type, cause ∈ NativeCrash\|ANR\|Hang, is_fatal=true, crash.source ∈ app_exit_info\|metrickit, native_capture_tier` | Android: JVM `UncaughtExceptionHandler` + `ApplicationExitInfo` (`REASON_CRASH_NATIVE`, `REASON_ANR`). iOS: MetricKit `MXCrashDiagnostic`/`MXHangDiagnostic`. "No signal handlers, no watchdog threads" | FA:25-43, 94-111, 155-180; FI:3-8, 155, 171-188 |
| RN | **none**: JS-only SDK, no native module | — | R:adapters/native/crashHandlerNative.native.ts:1-52 |
| Ionic | `exception_type, message, stacktrace, is_fatal, handled, error_context, cause ∈ NativeCrash\|ANR\|Hang, runtime=native, crash.{platform,id,captured_at,platform_version,signal,thread,symbolication}, anr.duration_ms` | Capacitor plugin `EdgeRumCrash`. Android: JVM handler + NDK signal handler (JNI, binary record file) + ANR watchdog. iOS: PLCrashReporter (BSD signals, no on-device symbolication) + HangDetector. JS fetches pending records via `fetchPending()` on the next launch, emits `app.crash`, then calls `markHandled` | X:capacitor/src/NativeCrashCapture.ts:61-70, 135-155, 240; X:capacitor/android/src/main/java/com/nathanclaire/rum/JvmCrashHandler.kt:12, 26-47; X:capacitor/android/src/main/java/com/nathanclaire/rum/NativeCrashBridge.kt:12, 104; X:capacitor/android/src/main/java/com/nathanclaire/rum/CrashRecordStorage.kt:15-25; X:capacitor/ios/Plugin/CrashReporter.swift:57, 150-188 |

**ANR / hang — NAT**

| SDK | Wire | Attributes | Technique | Cite |
|---|---|---|---|---|
| Android | `app.anr` (≥5 s, frozen + replayed), `app.hang` (≥2 s, live) | `is_fatal, handled, anr.duration_ms, anr.threads, screen.name` / `hang.duration_ms, hang.stack, screen.name` + device snapshot + trace | Main-looper heartbeat watchdog | A:core/anr/AnrWatchdog.kt:23-25, 52, 105; A:core/services/CrashReportingService.kt:146-191 |
| iOS | `app.hang` | `hang.{duration_ms,threshold_ms,cpu_usage,timestamp,stack,stack.truncated,binary_images}` | `CFRunLoopObserver` + 250 ms watchdog thread + Mach main-thread stack snapshot | I:EdgeRumCrash/HangDetector.swift:5-33, 131; I:EdgeRumCrash/HangEventEncoder.swift:63-83 |
| Flutter | `app.crash` with `cause=ANR`/`Hang` | see native crash | `ApplicationExitInfo` / MetricKit (post-mortem only) | FA:158-159; FI:180-188 |
| Ionic | `app.crash` with `cause=ANR` (Android) / `Hang` (iOS) | `anr.duration_ms` | Android: heartbeat every timeout/2 + `Thread.sleep(timeout)`. iOS: `DispatchSourceTimer` watchdog, default 5000 ms | X:capacitor/android/src/main/java/com/nathanclaire/rum/AnrWatchdog.kt:14-50, 74; X:capacitor/ios/Plugin/HangDetector.swift:4, 18-22, 59; X:capacitor/ios/Plugin/CrashReporter.swift:182-188 |
| RN | — | — | — | — |

**Android `app.exit`** (NAT): `exit.{reason,importance,description,status,pss_kb,rss_kb,timestamp,trace}` via `ActivityManager.getHistoricalProcessExitReasons()` (A:core/exit/ApplicationExitHarvester.kt:82-90; A:core/exit/ExitInfoReader.kt:12-18; A:core/TelemetryManager.kt:489).

### 2.8 Performance: frames, long tasks, vitals

**Frames — WV (WebView rAF) + NAT (native compositor)**

| SDK | Wire | Value / attributes | Technique | Cite |
|---|---|---|---|---|
| Android | E:`frame.summary` | `frame.{total_frames,slow_frames,frozen_frames,slow_frame_rate,max_total_duration_ms,max_build_duration_ms,max_raster_duration_ms,window_duration_ms}, display.refresh_rate, screen.name` | `Window.addOnFrameMetricsAvailableListener` (API 24+) | A:core/TelemetryFrameDropCollector.kt:9, 25, 36, 144-155 |
| iOS | M:`frame_render_time` | value = **max ms**; `frame.{max_ms,target_hz,source=displaylink,dropped_count,sample_count,window_ms}` | `CADisplayLink`; windows open on touch (`UIWindow.sendEvent` swizzle) and screen transitions | I:EdgeRumCapture/FrameSampler.swift:5-8, 228-253, 277 |
| Flutter | E:`frame.summary` (+ M:`long_task` = frozen >700 ms, diagnostic tier) | same `frame.*` keys as Android + `screen.id`; `long_task` carries `frame.{build,raster,total}_duration_ms` | `WidgetsBinding.addTimingsCallback` | F:capture/frame_capture_hook.dart:112, 252-276, 307-312; F:core/wire_canon.dart:56-61 |
| RN | M:`frame_render_time` | value = **p95**; `frame.{max_ms,p95_ms,dropped_count,target_fps,window_duration_ms,source=requestAnimationFrame}` | JS `requestAnimationFrame` loop, windowed per view | R:adapters/frameTracker.ts:31-39, 56-58; R:adapters/frameAggregate.ts:48-64 |
| Ionic | M:`frame_render_time` | value = **p95**; **dotless** `frames_total, slow_frames, dropped_frames, p50_ms, p95_ms, worst_ms, window_ms`, `metric.screen`. Sent only if the window had a slow frame; window capped at 30 s | WebView `requestAnimationFrame`. Native plugin samples Android `Choreographer` / iOS `CADisplayLink`; JS drains every 5 s | X:core/src/instrumentation/frames.ts:17-24, 83-117; X:capacitor/src/PerfSamplerCapture.ts:34, 46-57, 121; X:capacitor/android/src/main/java/com/nathanclaire/rum/FrameSampler.kt:10, 43-50; X:capacitor/ios/Plugin/FrameSampler.swift:13, 64 |

**Long task**:
- iOS: `CFRunLoopObserver` span >50 ms. `value`, `long_task.{threshold_ms,stack,stack.truncated,binary_images}` (I:EdgeRumCapture/RunLoopObserverCapture.swift:5-14, 102-128).
- Ionic: `PerformanceObserver('longtask')` where supported. `metric.{unit,name,screen}` (X:core/src/instrumentation/perf-observer.ts:43-65).
- RN calls the longtask APIs Chromium-only and retired the name (R:core/telemetry.ts:131-137). In a Cordova app that means Android System WebView only; WKWebView support is **unverified**.

**Web Vitals — WV**: `web-vitals` library.
- Ionic: `onLCP/onINP/onCLS/onFCP/onTTFB` → metric named after the vital, `metric.{unit ∈ ms|score, rating, screen}` (X:core/src/instrumentation/vitals.ts:1-32).
- RN web: `web-vitals/attribution`; CLS/INP held with `reportAllChanges`; `vital.{rating,navigation_type,target,load_state}`, `metric.unit` (R:adapters/web/webVitals.web.ts:50-58, 87; R:adapters/webVitals.ts:67-75; R:core/telemetry.ts:148-153).
- Per-vital support in Android WebView vs WKWebView is **unverified**.

**CPU — NAT**: iOS `cpu_usage` metric (I:EdgeRumCapture/MemorySampler.swift:274).

### 2.9 Memory — WV (Chromium JS heap only) + NAT

| SDK | Wire | Value / attributes | Technique | Cite |
|---|---|---|---|---|
| Android | M:`memory_usage` (MB); M:`system_memory_available`; E:`memory_pressure`; E:`storage_usage` | `metric.unit=MB, memory.{type=heap\|system, source, pressure_level, under_system_pressure, api_level, tracking_method, timestamp}`, `heap_{used,max,free}_mb`, `storage.{api_level,tracking_method}` | `Runtime.getRuntime()`, `ActivityManager.MemoryInfo`; sampled at session start / foreground | A:core/MemoryTracker.kt:98-111, 132-148, 220-256, 306-310; A:core/TelemetryMemoryUsage.kt:94-120, 155-170, 251; A:core/TelemetryManager.kt:539-555 |
| iOS | M:`memory_usage` | `memory.{pressure,resident_kb,virtual_kb,footprint_kb}` | `task_info` (`MACH_TASK_BASIC_INFO`, `TASK_VM_INFO.phys_footprint`) on a timer + `DispatchSource.makeMemoryPressureSource` | I:EdgeRumCapture/MemorySampler.swift:13-16, 113-122, 151-152, 176-203, 246-248 |
| Flutter | M:`memory_usage` | `memory.{unit=bytes, source, phase ∈ session_start\|session_end}` | Bookends only (v2's 10 s `ProcessInfo.currentRss` poll was removed) | F:capture/memory_bookend_hook.dart:9, 78, 88, 102-112 |
| RN | M:`memory_usage` (MB) | `memory.{type=rss, source=<OS>, total_mb}` | `react-native-device-info` `getUsedMemory()`/`getTotalMemory()` on `setInterval` | R:adapters/native/memoryNative.native.ts:31-53 |
| Ionic | M:`memory_usage` (MB) | **dotless** `unit=MB, memory_type ∈ heap\|rss\|pss, memory_source ∈ javascript\|native, memory_pressure_level` | WebView: `performance.memory.usedJSHeapSize` (Chromium-only), 10 s. Native plugin: Android `Debug.getMemoryInfo` PSS + `onTrimMemory`; iOS `mach_task_basic_info.resident_size` + memory-pressure source | X:core/src/instrumentation/memory-web.ts:26, 44-64; X:capacitor/src/PerfSamplerCapture.ts:59-72, 138; X:capacitor/android/src/main/java/com/nathanclaire/rum/MemorySampler.kt:20-22, 78, 152-153; X:capacitor/ios/Plugin/MemorySampler.swift:6, 111, 176-184 |

### 2.10 User interactions — WV

| SDK | Wire | Attributes | Technique | Cite |
|---|---|---|---|---|
| Android | `ui.interaction` | `ui.{type ∈ tap\|long_press\|swipe, target, name_source, x, y, direction, screen}` + trace | Wraps `Window.Callback` per Activity + `GestureDetector`; Compose semantics namer | A:core/interaction/UserInteractionTracker.kt:19-35, 88-111 |
| iOS | `user.interaction` | `interaction.{kind=tap, target (class name), name (accessibilityIdentifier / opt-in button title), name_source}` | Swizzles `UIWindow.sendEvent(_:)`; SwiftUI modifier | I:EdgeRumCapture/InteractionCapture.swift:3-20, 211, 253-259; I:EdgeRum/SwiftUI/ViewModifiers.swift:76 |
| Flutter | `ui.interaction` | `ui.{type ∈ tap\|long_press\|swipe, direction, screen, name_source, target}`, `span.id` | `GestureBinding.pointerRouter.addGlobalRoute` | F:capture/action_capture_hook.dart:40-43, 137, 212-226 |
| RN | `ui.interaction` | `ui.{type, target, name_source ∈ edge_action\|test_id\|aria_label\|title\|text\|none, tag, x, y, rage, dead}` | Web: `document` capture-phase `click` listener, dead-click window (1000 ms), rage detection. Native: **manual `trackTap(name)` only** | R:adapters/uiInteraction.ts:1-33, 196-202; R:adapters/web/interactionWeb.web.ts:61, 124, 146; R:index.native.ts:250-271 |
| Ionic | `user.interaction` | `interaction.{type=click, screen, timestamp, target_tag, target_id, target_class, target_role}` (64-char cap, 50 ms dedup) | `document` capture-phase `click` listener | X:core/src/instrumentation/interactions.ts:14-40, 61-87 |

### 2.11 Network change — WV+NAT

| SDK | Attributes | Technique | Cite |
|---|---|---|---|
| Android | — (only the `network.type` context key) | `getNetworkType(context)` per event | A:core/TelemetryManager.kt:526, 636 |
| iOS | `network.{type, expensive, constrained, unsatisfied_reason}` | `NWPathMonitor` | I:EdgeRumCapture/NetworkPathCapture.swift:3, 158-164, 264-265 |
| Flutter | `network.{previous_type, current_type, change_timestamp, available, change_direction}` | `connectivity_plus` | F:capture/network_capture_hook.dart:20, 79-90 |
| RN | `network.{previous_type, type}` | `@react-native-community/netinfo` (native); `navigator.connection` / `onLine` (web) | R:adapters/networkChange.ts:19-21; R:adapters/native/networkInfo.native.ts:16, 36; R:adapters/web/networkInfo.web.ts:8-22 |
| Ionic | `network.{connected, type, previous_type}`; context also `network.effectiveType, network.downlinkMbps` | `@capacitor/network` `networkStatusChange`; fallback `navigator.onLine` + `navigator.connection.type`. Flushes the queue when back online | X:capacitor/src/NetworkCapture.ts:72, 112-115, 126-160, 186-218, 241 |

### 2.12 Custom events, metrics, identity — WV

| | Android | iOS | Flutter | RN | Ionic |
|---|---|---|---|---|---|
| Custom event | `recordEvent(name, attrs)`, name sent as given (A:core/TelemetryManager.kt:644-662) | `track()` → `custom_event`, `event.name` (I:EdgeRum/EdgeRum.swift:394-398) | `trackEvent()` → `custom_event`, `event.name` (F:facade/edge_telemetry.dart:571-580) | off-allowlist name → `custom_event` + `event.name` (R:core/telemetry.ts:114-117, 1099) | `track()` → `custom_event`, `event.name` (X:core/src/EdgeRum.ts:306-312) |
| Custom metric | `recordMetric(name, value)` (A:core/TelemetryManager.kt:622-641) | `custom_timer`, `timer.name`; metric allowlist (I:EdgeRum/RumTimer.swift:65; I:EdgeRumCore/Recorder.swift:73-83) | `trackMetric()`, **dropped unless the name is on the canon list** (F:facade/edge_telemetry.dart:602-612; F:core/collector.dart:122-131) | `recordMetric()`, any name, no unit (R:core/telemetry.ts:146, 1437-1438) | `time(name).end()` → metric `<name>`, `metric.unit=ms` (X:core/src/EdgeRum.ts:341-354) |
| `user.profile.update` | `user.{name,email,phone,profile_updated_at}`, `""` when cleared (A:core/TelemetryManager.kt:1000-1007) | (I:EdgeRumCore/Recorder.swift:592) | `user.{name,email,phone,profile_updated_at,…}` (F:managers/user_profile_manager.dart:47-62; F:facade/edge_telemetry.dart:695, 720) | profile keys **only** on this event (R:core/telemetry.ts:990, 1295-1296) | `user.{name,email,phone,profile_version,profile_updated_at}` (X:core/src/EdgeRum.ts:286-302) |
| `user.id` | SDK-generated, required (A:core/TelemetryHttpClient.kt:200-206) | persisted (`edge.rum.user.id`) (I:EdgeRumCore/Persistence/UserDefaultsStore.swift:43) | SDK-held global (F:facade/edge_telemetry.dart:211) | **host-set; omitted when anonymous** (R:core/telemetry.ts:1272-1273) | SDK anonymous `user_…` in localStorage; `identify()` cannot change it (X:core/src/internal/context.ts:48-61) |

### 2.13 Journeys / actions / tasks — WV

- iOS: `action.started`/`action.ended` with `action.{id,name,parent_id,outcome,abandon_reason,background_count,background_duration_ms,error_message}` (I:EdgeRum/RumAction.swift:63, 105; I:EdgeRumCore/Actions.swift:136, 209-230).
- Flutter: `task.complete` with `task.{name,outcome,abandon_source}`, `span.duration_ms`. `startTask`/`completeTask`; open tasks are abandoned at session end (F:core/edge_event.dart:191-206; F:facade/edge_telemetry.dart:486-521).
- Android and RN: `trace.id, span.id, rum.action.id, trace.root_type` stamped on rows (A:core/interaction/UserInteractionTracker.kt:88-110; R:adapters/traceManager.ts:231-233, 337-342; R:core/telemetry.ts:155-168).
- Ionic: none.

### 2.14 Context attributes (on every event, or envelope) — WV+NAT

| Group | Android | iOS | Flutter | RN | Ionic |
|---|---|---|---|---|---|
| app.* | envelope `app` (A:core/TelemetryHttpClient.kt:152-158) | envelope `app` (I:EdgeRumCore/PayloadBuilder.swift:69-75) | envelope `app` (F:core/wire_canon.dart:124-129) | `app.{name,version,build_number,package_name}` per event via device-info lib; `app.build_id` (R:adapters/native/deviceInfo.native.ts:57-62; R:core/telemetry.ts:1269) | per event `app.{name,version,package_name,build_number,environment}` from config; build from `@capacitor/app` (X:core/src/internal/context.ts:23-32; X:capacitor/src/bootstrap.ts:52-59) |
| device.* | `platform, platform_version, model, manufacturer, brand, android_sdk, android_release, fingerprint, hardware, product` (+`cpu_abi, cpu_cores, low_ram, screen_*, dark_mode, locale, timezone` in the collector) (A:core/TelemetryHttpClient.kt:184-193; A:core/device/DeviceInfoCollector.kt:75-109) | `platform, platform_version, model, manufacturer, os, family, locale, timezone, timezone_offset_min, low_power_mode, thermal_state`, a11y `voiceover, bold_text, dynamic_type, reduce_motion, increase_contrast` (I:EdgeRumCore/Context/DeviceContext.swift:163-177; …/PowerContext.swift:56-57; …/AccessibilityContext.swift:78-82) | `platform, platform_version, model, manufacturer, brand, android_*`, `platform_brightness, text_scale_factor, reduce_motion` (F:collectors/flutter_device_info_collector.dart:58-59, 112-119; F:managers/context_manager.dart:82-87) | `platform, platform_version, model, manufacturer, brand, android_sdk, android_release, cpu_abi, low_ram, ios_system_name, …` (R:adapters/native/deviceInfo.native.ts:64-80) | `platform, model, manufacturer, os, platform_version, id` via `@capacitor/device`, falling back to **UA parsing** (X:capacitor/src/DeviceContext.ts:56, 253-293) |
| device_id | envelope root (R9) | envelope root | envelope root | per event `device.id`, `device.id_ephemeral` (R:core/telemetry.ts:1270-1271) | per event `device.id` = `device_<ms>_<hex>_<platform>` in localStorage (X:capacitor/src/DeviceContext.ts:274, 293) |
| network.* | `network.type` (A:core/TelemetryHttpClient.kt:225) | `network.{type,interface,expensive,constrained}` (I:EdgeRumCore/Context/NetworkContext.swift:65-69) | `network.type` (F:managers/context_manager.dart:70) | `network.{type,is_connected}` (R:core/telemetry.ts:1262) | `network.{connected,type,effectiveType,downlinkMbps}` (X:capacitor/src/NetworkCapture.ts:112-115, 164-165) |
| sdk.* | envelope `sdk{name:android}` | envelope `sdk{name:ios}` | envelope `sdk{name:flutter}` | per event `sdk.{platform=react-native-<os>, version, events_dropped, drop_reason, hook_*}` (R:core/telemetry.ts:25, 1287-1292) | per event `sdk.{version=4.0.0, platform=ionic-angular-capacitor, contract_version=3.1.0}` (X:core/src/index.ts:1-3; X:core/src/internal/context.ts:79-81) |

---

## 3. Agree / diverge

### 3.1 Envelope and batch shape

| | Android | iOS | Flutter | RN | Ionic |
|---|---|---|---|---|---|
| Envelope | contract 4.0.0, 8 keys `type, contract_version, timestamp, batch_size, device_id, sdk, app, events` (A:core/models/TelemetryBatch.kt:7-31) | same (I:EdgeRumCore/EventEnvelope.swift:40-44, 81-90) | same (F:core/wire_canon.dart:107, 148-154) | **legacy** `{type, timestamp, batch_size, events}` (R:adapters/batch.ts:5-11) | **legacy** `{type, timestamp, location?, batch_size, events}` (X:core/src/transport/PayloadBuilder.ts:20-26, 56-64) |
| Identity location | envelope only; stripped from events (A:core/TelemetryHttpClient.kt:176-177, 231) | envelope | envelope; strips `device.id/app.*/sdk.*` (F:core/wire_canon.dart:96-97) | every event | every event |
| Item shape | `{type, eventName\|metricName, value?, timestamp, attributes}` (A:core/models/TelemetryBatch.kt:34-40) | same | same | same (R:core/telemetry.ts:192-199) | same (X:core/src/transport/PayloadBuilder.ts:3-16) |
| Attribute value types | typed | typed | **strings only** (for example F:capture/frame_capture_hook.dart:254-262) | typed | typed |
| Auth headers | `X-API-Key`, UA (A:core/TelemetryHttpClient.kt:124-130) | `X-API-Key` (I:EdgeRumCore/Transport/BatchTransport.swift:99) | `X-API-Key`, gzip (F:core/retry_transport.dart:212-247) | `X-API-Key` **and** `Authorization: Bearer` (R:adapters/batch.ts:18-22) | `X-API-Key` (X:core/src/transport/RetryTransport.ts:68-70) |
| Health | `telemetry.capabilities_initialized` | `sdk.health` event (R4) (I:EdgeRumCore/SdkHealth.swift:15, 28-36) | `session.dropped_*` | `sdk.*` on every row | `sdk.*` on `session.finalized` |

Against the wayfinder contract (`wayfinder/spec.md` §4):
- Ionic and RN break R1 and R3: identity sits on every event and there is no `contract_version`, `device_id`, `sdk` or `app` block.
- Ionic also breaks R7 (envelope `location`; X:core/src/EdgeRum.ts:206-220) and R8 (`app.environment`; X:core/src/internal/context.ts:31).
- R2 names `ionic` and `react_native` for `sdk.name`, but the code today sends the attributes `sdk.platform=ionic-angular-capacitor` and `react-native-<os>`.
- Cordova 4.0.0 should follow the Android/iOS/Flutter envelope. Note that R2's enumerated `sdk.name` set has no `cordova` value; **open question**.

### 3.2 Naming inconsistencies (same concept, different names)

| Concept | Variants |
|---|---|
| Tap/click event | `ui.interaction` (Android, Flutter, RN) vs `user.interaction` (iOS, Ionic). RN calls `user.interaction` "off the list as of v4" (R:core/telemetry.ts:123-125) |
| Tap attribute namespace | `ui.*` (Android, Flutter, RN) vs `interaction.*` (iOS, Ionic). Ionic keys (`target_tag/id/class/role`) match no other SDK |
| Navigation keys | `navigation.to_screen/from_screen` (Android, RN, Ionic) vs `navigation.screen/previous_screen/kind` (iOS) vs `navigation.to/from/type` (Flutter) |
| Screen dwell | `screen.duration` event (Android, RN, Ionic) vs `screen.previous_duration_ms` on `navigation` (Flutter) vs none, processor-derived (iOS) |
| `page_load` | **native cold start** (iOS, Flutter) vs **WebView Navigation Timing** (Ionic). Same name, different meaning. Retired in RN |
| Cold start | `app.start` + `app.start.*` (Android); `app.start` with trace keys only (RN); `page_load` + `page_load.*`/`launch.*` (iOS); `page_load` + `startup.*` (Flutter); `lifecycle.cold_start_ms` attribute (Ionic) |
| Lifecycle attr | `lifecycle.state` (iOS: 5 UIKit states + `previous_state`; Flutter: `AppLifecycleState` names) vs `app_lifecycle.state` (RN) vs `lifecycle.event` (Ionic). Android emits nothing |
| Session reason | `session.reason` (Android `timeout`; RN `launch\|idle\|max_duration`) vs `session.rotation` (iOS `idle\|max_duration`) vs `session.start_reason`/`end_reason` (Ionic) vs none (Flutter, `session.recovered` only) |
| Handled error | `app.crash`+`handled=true` (Android, Ionic) vs `app.crash`+`is_fatal=false` (Flutter) vs `app.error` (iOS, RN) |
| Error keys | flat `exception_type, message, stacktrace, is_fatal, handled, cause, error_context` (Android, Ionic, Flutter) vs `error.{type,source,message,stacktrace,fatal}` (RN) vs `error.{class,kind,domain,code,stack}` + `crash.*` (iOS) |
| ANR / hang | separate `app.anr` + `app.hang` (Android); `app.hang` (iOS) vs folded into `app.crash` with `cause=ANR\|Hang` (Ionic, Flutter; Flutter documents why at F:core/wire_canon.dart:23-24) |
| Breadcrumb key | `crash.breadcrumbs` (Android, Ionic, Flutter) vs `breadcrumbs` (iOS) vs `error.breadcrumbs` (RN) |
| Frames | event `frame.summary` (Android, Flutter) vs metric `frame_render_time` (iOS value = max; RN and Ionic value = p95). Ionic attributes are dotless (`frames_total`, `p95_ms`); RN uses `frame.p95_ms`; iOS `frame.max_ms`, `frame.target_hz` vs RN `frame.target_fps` |
| Memory units | MB (Android, RN, Ionic) vs KB (iOS `*_kb`) vs bytes (Flutter `memory.unit=bytes`). Ionic keys are dotless (`memory_type`, `memory_source`, `memory_pressure_level`) vs `memory.*` elsewhere |
| HTTP URL | `http.url` (Android, Flutter, Ionic) vs `http.host`+`http.path` (iOS) vs `http.host`+`http.route` (RN, no raw URL) |
| `http.success` | 200-299 (Android) vs 200-399 (RN, Ionic). iOS and Flutter: not traced (**unknown**) |
| Network change | `network.type` (iOS, RN, Ionic) vs `network.current_type` (Flutter) |
| Custom event | `custom_event`+`event.name` (iOS, Flutter, RN, Ionic) vs raw name (Android) |

### 3.3 Present in some, absent in others

- Only Android: `app.exit`, `memory_pressure`, `storage_usage`, `system_memory_available`, `telemetry.capabilities_initialized`, a crash-time device snapshot (`device.battery_*`, `thermal_status`, `orientation`).
- Only iOS: `cpu_usage`, `sdk.health`, `action.*`, `screen_ready`, `launch_interactive`, TLS/protocol HTTP detail, `custom_timer`.
- Only Flutter: `task.complete`, `screen.load`, `error.category`.
- Only RN: `view` and `view.*` on every row, `app.error` from `console.error`, rage/dead clicks, `session.sample_rate` on every row.
- Only Ionic: Web Navigation Timing `page_load`, Angular/Ionic view hooks, `console.error` used as breadcrumbs only.
- Trace propagation (`traceparent`): Android (A:core/TelemetryInterceptor.kt:32-39), Flutter (F:capture/trace_injection.dart:17), RN (R:adapters/xhrIntercept.ts:109-120). **Not** iOS (key namespace only, I:EdgeRumCore/HostAttributes.swift:25) and **not** Ionic.
- Native crash capture: all except RN.
- XHR capture: RN only (Ionic patches `fetch` only).

### 3.4 Native-only signals for Cordova (need a plugin)

Native crashes (JVM uncaught, NDK signals, iOS Mach/signal or MetricKit), ANR, hang, `app.exit`, true cold start, native frame timing (Choreographer/CADisplayLink), process memory (PSS/RSS/footprint) and pressure callbacks, CPU, precise device model/OS, app version/build, durable device ID (Keychain), network type beyond `navigator.connection`, and HTTP made by native code. Ionic's plugin design is the template:
- crash records persisted natively and fetched by JS on the next launch;
- perf samples buffered natively and drained by JS every 5 s;
- native transport.

(X:capacitor/src/NativeCrashCapture.ts:61-70; X:capacitor/src/PerfSamplerCapture.ts:34; X:capacitor/src/capacitor-http-fetch.ts:21-31)

### 3.5 WebView-only signals

Session, `app_lifecycle` (visibility / Cordova `pause`/`resume`), JS errors/rejections, fetch/XHR, SPA navigation, DOM click, rAF frames, Web Vitals, PerformanceObserver resource/longtask, custom events/metrics, identity, breadcrumbs. Caveats from sibling code:
- `performance.memory` and `longtask` are Chromium-only, so Android System WebView only (X:core/src/instrumentation/memory-web.ts:44-46; R:core/telemetry.ts:135-137).
- A rAF loop measures the WebView's own frame production, not native UI.

### 3.6 Dead or dropped emissions (code that emits but nothing ships)

- Flutter metrics `performance.startup_time` (F:capture/perf_capture_hook.dart:58-64) and `network.quality_score` (F:capture/network_capture_hook.dart:93-103) are not in `kCanonMetrics`, so the collector drops them as `off_canon` (F:core/wire_canon.dart:62-67; F:core/collector.dart:122-131).
- Flutter canon lists `user.interaction`, `screen.duration`, `frame_render_time` and `resource_timing`, but no emitter exists in `lib/` (grep of emission sites). Those names are kept on the list on purpose (F:core/wire_canon.dart:26-31, 52-58).
- RN: any name off `ALLOWED_NAMES` is rewritten to `custom_event`, so `page_load`, `resource_timing` and `long_task` cannot be reached (R:core/telemetry.ts:131-138).

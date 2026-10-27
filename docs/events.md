# What is captured

Every event the plugin sends, by wire name. **JS** = captured in the WebView, **native** = by the plugin's Android / iOS code. "API" = only when your app calls the method.

## Sessions and app

| Event | From | Default | Notes |
|---|---|---|---|
| `session.started` / `session.finalized` | native | on | Finalized carries `session.duration_ms`, `session.event_count`, `session.metric_count`, `session.screen_count`, `session.visited_screens`. |
| `app.start` | native + JS | on | One per cold launch. `app.start.type`, `app.start.duration_ms` and phase times: process start → WebView created → `responseEnd` → `DOMContentLoaded` → `load` → `deviceready` → `markReady()` (if called within 30 s). |
| `app_lifecycle` | JS + native | on | `lifecycle.state` from `pause` / `resume`, `visibilitychange`, native foreground / background. |
| `app.exit` | native | on | Android 11+: process exit reasons, once per new record. |
| `cordova.deviceready_timeout` | native | on | `deviceready` never fired within `EDGE_RUM_DEVICEREADY_TIMEOUT_MS`; sent on the next launch. |
| `network_change` | native | on | Connectivity changes. |
| `memory_usage` | native | on | At session start and end. Periodic readings with `EDGE_RUM_MEMORY_SAMPLING_ENABLED`. |
| `memory_pressure` | native | on | Android `onTrimMemory`, iOS memory warning. |

## Errors and crashes

| Event | From | Default | Notes |
|---|---|---|---|
| `app.crash` (JS uncaught) | JS | on | `error` and `unhandledrejection`. `handled=false`, `is_fatal=true`, `runtime=webview`, `crash.breadcrumbs`, `release` if set. Same-origin stack frames are rewritten to `app:///<path under www>`. |
| `app.crash` (caught) | JS | API | `captureError()`. `handled=true`, `is_fatal=false`. |
| `app.crash` (console) | JS | off | `captureConsoleErrors: true` reports `console.error`. Otherwise `console.*` calls are breadcrumbs only. |
| `app.crash` (native) | native | on | Android JVM + NDK signals; iOS signals / Mach exceptions. Sent on the next launch, alone in its batch, with the build that crashed and the last 50 breadcrumbs. |
| `app.crash` `cause=WebViewTerminated` | native | on | The WebView's content process died. `webview.reason` (`crash` / `oom_killed` / `unknown`), `webview.detected_by` (`callback` / `inference`), `screen_name`. |
| `app.anr` | native | on | Android main thread blocked ≥ 5 s. |
| `app.hang` | native | on | Main thread blocked ≥ 2 s, Android and iOS. |

## Screens, requests and taps

| Event | From | Default | Notes |
|---|---|---|---|
| `navigation` | JS | on | `pushState` / `replaceState` / `popstate` / `hashchange`, or `trackScreen()`. `navigation.from_screen`, `navigation.to_screen`, `navigation.method`. |
| `screen.duration` | JS | on | On leaving a screen: `screen.name`, `screen.duration_ms`. |
| `http.request` | JS | on | `fetch` and XHR: `http.url` (scrubbed, see [privacy](privacy.md)), `http.method`, `http.status_code`, `http.duration_ms`, `http.success`. The plugin's own requests and `ignoreUrls` are skipped. Native HTTP clients are not captured. |
| `traceparent` header | JS | off | Added only to requests to `correlateRequestsTo` hosts. |
| `resource_timing` | JS | off | `captureResourceTiming: true`. |
| `ui.interaction` | JS | on | Taps / clicks: `ui.type`, `ui.target`, `ui.name_source`, `ui.screen`, `ui.x`, `ui.y`. `ui.rage=true` for ≥ 3 taps on one target within 1 s; `ui.dead=true` when nothing happened within 1 s. |

## Performance

| Event | From | Default | Notes |
|---|---|---|---|
| `LCP`, `INP`, `CLS`, `FCP`, `TTFB` | JS | on | Whatever the WebView supports. |
| `frame.summary` | JS | on | Per screen while visible: `frame.total_frames`, `frame.slow_frames`, `frame.frozen_frames`, `frame.slow_frame_rate`, `frame.max_total_duration_ms`, `frame.long_task_count`, `frame.source=raf`. |
| `bridge.summary` | JS | on | Cordova plugin calls per screen, by `bridge.service` + `bridge.action`: `bridge.count`, `bridge.error_count`, `bridge.p50_ms`, `bridge.p95_ms`, `bridge.max_ms`. |
| `bridge.call` | JS | on | One plugin call slower than `slowBridgeCallMs`, failed, or never called back within 30 s: `bridge.duration_ms`, `bridge.outcome` (`slow` / `error` / `no_callback`). |

## Your events

| Event | From | Default | Notes |
|---|---|---|---|
| `custom_event` | JS | API | `track(name)` → `event.name`. |
| *(your name)* | JS | API | `measure()` / `time()`: a numeric value under the name you give. |
| `task.complete` | JS | API | `startTask` → `completeTask` / `failTask`: `task.name`, `task.outcome`, `span.duration_ms`; open tasks are abandoned at session end (`task.abandon_source`). |
| `user.profile.update` | JS | API | `identify()` with changed `name` / `email` / `phone`. |

## Plugin health

`sdk.health` reports events the plugin had to drop, as `events_dropped.<reason>` counts:

| Reason | Cause |
|---|---|
| `js_buffer_full` | More than 500 events before `deviceready`. |
| `js_exec_failed` | The hand-off to native failed. |
| `before_send_null` / `before_send_error` | Your `beforeSend` returned `null` / threw or returned a non-event. |
| `cap.error`, `cap.interaction`, `cap.bridge`, `cap.custom` | A per-session cap was reached (below). |
| `outbox_full` / `expired` | Unsent data over 5 MB / 200 batches, or older than 7 days. |
| `rejected` | The backend rejected a batch (4xx other than 429). |
| `corrupt` | A batch on disk could not be read. |

## Sampling and caps

`EDGE_RUM_SAMPLE_RATE` keeps or drops whole sessions. These are always sent, whatever the rate and caps: `session.started`, `session.finalized`, fatal `app.crash`, `app.anr`, `app.exit`, `app.start`, `cordova.deviceready_timeout`, `sdk.health`. When the rate is below 1, session events carry `session.sampled`.

Per-session caps:

| Events | Cap |
|---|---|
| Non-fatal `app.crash` | 5 per error type + top frame, 50 total |
| `ui.interaction` | 200 |
| `bridge.call` | 5 per service + action, 50 total |
| `custom_event` + `measure()` / `time()` + `task.complete` | 500 combined |

Requests, screens, vitals, frames, lifecycle and network are not capped.

## Delivery

Events are written to disk and sent in gzip batches of up to 50, or every 30 s, and when the app goes to the background. Failed sends are retried (1 s / 4 s / 16 s, then on the next launch, foreground or reconnect), so events captured offline arrive later.

Never captured: native HTTP clients, CPU usage, native frame timing, session replay.

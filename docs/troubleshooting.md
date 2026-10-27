# Troubleshooting

Turn on JS warnings first: `init({ debug: true })`. Native errors are always logged: Android `adb logcat -s EdgeRum`, iOS Xcode console lines starting `[EdgeRum]`.

## Nothing arrives

- **Key or endpoint missing.** Check `config.xml` in the built platform for `EDGE_RUM_API_KEY` / `EDGE_RUM_ENDPOINT`. If they are missing, events are kept on disk until `init({ apiKey, endpoint })` supplies them. To change install-time variables: `cordova plugin rm @nathanclaire/rum-cordova` then add it again with the new `--variable`s.
- **Endpoint is used exactly as given.** It must be the full ingest URL, including path.
- **Batches leave on a schedule**, not per event: at 50 events, 30 s after the first event, or when the app goes to the background. Background the app to send now.
- **Capture is off.** `EDGE_RUM_ENABLED=false` (opt-in mode) or an earlier `disable()` is remembered until `enable()`.
- **Sampled out.** With `EDGE_RUM_SAMPLE_RATE` below 1, some sessions send only the always-kept events (see [events](events.md#sampling-and-caps)).
- **Backend too old.** The plugin sends contract 4.0.0 with `sdk.name=cordova`; install the backend release first.
- **Android cleartext.** An `http://` endpoint needs cleartext allowed for that host (network security config). Use `https://`.
- **Browser / electron.** The plugin does nothing there by design.

## Some events are missing

- **Dropped and counted.** Look at `sdk.health` → `events_dropped.<reason>` ([reasons](events.md#plugin-health)).
- **`beforeSend`** returned `null`, threw, or returned something that isn't an event. With `debug: true` the throw case logs a warning.
- **Per-session caps** reached (`cap.*` drop reasons).
- **Requests not captured**: requests to the plugin's own endpoint and to `ignoreUrls` are skipped; requests from native code (other plugins' HTTP clients) are never captured.
- **Native events skip `beforeSend`** and JS-only options; that is expected.

## Screens

- **Every screen is `/index.html`.** Your router uses neither the URL hash nor the History API. Set `captureScreens: false` and call `trackScreen()` from the router (see the README's router recipes).
- **Too many distinct screens** (one per id). Pass the route template (`/orders/:id`) to `trackScreen()`, not the URL, or map paths with `screenName(path)`.

## Launch time

- **No `app.start.mark_ready_ms`.** `markReady()` must be called within 30 s of `deviceready`, on a cold launch.
- **`cordova.deviceready_timeout`.** `deviceready` didn't fire within `EDGE_RUM_DEVICEREADY_TIMEOUT_MS` (default 10 s). Usually a plugin that never finished loading, or a JS error before Cordova started; check the console for that launch.

## Crashes

- **Native crash didn't show up.** It is sent on the *next* launch. Open the app again.
- **JS stack frames point at bundled code.** Frames are `app:///<path under www>`; set `init({ release })` and upload source maps for that release and path.
- **iOS WebView deaths reported with `webview.detected_by=inference`.** The direct hook only runs on tested cordova-ios 8.x, or `EDGE_RUM_IOS_WEBVIEW_HOOK=false` turned it off; the plugin then detects the death on the next page load.

## Build

- **Install fails on engine check.** Needs cordova CLI ≥ 13, cordova-android ≥ 15, cordova-ios ≥ 8.
- **iOS: Swift package not resolved.** The plugin is a Swift package (no CocoaPods). Open `platforms/ios/App.xcworkspace` and let Xcode resolve packages, or rebuild with `cordova build ios`.

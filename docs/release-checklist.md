# Release checklist

Spec Q6. Run every `example/` scenario by hand on a **real** Android phone and a **real** iPhone, tick each box in the release PR, and don't tag `v1.0.0` (or any later release) until every box is ticked. The device e2e workflow (Q4) only automates the happy path on an emulator and a simulator; this list covers the rest.

## Setup

1. Start mock-ingest on a laptop on the same network as the phones: `node e2e/mock-ingest-server.mjs`.
2. Build the example pointed at it, for each platform:
   ```sh
   EDGE_RUM_ENDPOINT=http://<laptop LAN ip>:4319/collector/telemetry scripts/example-build.sh android
   EDGE_RUM_ENDPOINT=http://<laptop LAN ip>:4319/collector/telemetry scripts/example-build.sh ios
   ```
3. Install on the phones: `cd example && npx cordova@13 run android --device`; for iOS open `example/platforms/ios/App.xcworkspace` in Xcode, set a signing team and run on the phone.
4. Each scenario is a button on the home screen. Run one, then send the app to the background so the batch seals and sends (spec T3). Read what arrived with `curl -s localhost:4319/__requests | jq '.requests[].parsed.events[] | {eventName, attributes}'`, and clear it between scenarios with `curl -X POST localhost:4319/__reset`.

Every batch must also have: `Content-Encoding: gzip`, `sdk.name = cordova`, `contract_version = 4.0.0`, `app.platform` matching the phone, and the same `device_id` across launches.

## Scenarios

| Scenario | Do | Expect | Android | iOS |
|---|---|---|---|---|
| `happy` | Tap it | `session.started`, `app.start` with phase keys, `navigation` to `/happy`, `http.request` for `ping.json`, `bridge.summary` for `ExampleScenarios` | [ ] | [ ] |
| `js-error` | Tap it | `app.crash` with `handled=false`, `is_fatal=true`, `runtime=webview`, frames as `app:///app.js`, `crash.breadcrumbs` | [ ] | [ ] |
| `native-crash` | Tap it (the app dies), then open the app again | On relaunch: `app.crash` from the native handler, alone in its batch (no `sdk.health`), with the native breadcrumbs | [ ] | [ ] |
| `renderer-kill` | Tap it | `app.crash` with `cause=WebViewTerminated`, `webview.detected_by=callback`, `screen_name=/renderer-kill` (on iOS, if the page reloads instead, open the app again: `detected_by=inference`) | [ ] | [ ] |
| `hang` | Tap it, keep the app open for 6 s | Android: `app.anr` (≥ 5 s) and `app.hang`; iOS: `app.hang` (≥ 2 s) | [ ] | [ ] |
| `slow-bridge` | Tap it | `bridge.call` with `bridge.outcome=slow`, `bridge.duration_ms` ≥ 1500 | [ ] | [ ] |
| `offline` | Turn on airplane mode, tap it, background the app, turn airplane mode off, open the app | Nothing arrives while offline; afterwards the 30 `custom_event`s (`event.name=offline.burst`) arrive once each (offline replay, R12) | [ ] | [ ] |
| `rage-tap` | Tap it (or tap “Does nothing” three times fast) | `ui.interaction` with `ui.rage=true` and `ui.dead=true` | [ ] | [ ] |
| `mark-ready` | Kill the app, open it, tap it within 30 s | That launch's `app.start` has `app.start.mark_ready_ms` | [ ] | [ ] |
| `task` | Tap it | `task.complete` with `task.name=checkout`, `task.outcome` completed, `span.duration_ms` ≈ 500 | [ ] | [ ] |
| `caps` | Tap it | 500 `custom_event`s with `event.name=caps.burst`, and `sdk.health` with `cap.custom=100` | [ ] | [ ] |

## Deep links

Each scenario also runs from a deep link with the same name. Check one per platform:

- [ ] Android: `adb shell am start -n com.nathanclaire.rum.example/.MainActivity --es scenario task`
- [ ] iOS: open `edgerumexample://task` in Safari on the phone

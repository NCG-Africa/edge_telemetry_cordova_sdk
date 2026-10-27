# 0003 — How performance capture reads the rules the spec leaves open

Status: accepted 2026-10-27 (#32)

## Context

E18 groups `bridge.summary` by `bridge.service` + `bridge.action` and times calls "via `cordova.callbacks` proxy". But the action never reaches `cordova.callbacks` (research §2.3). E18 and E20 say "per screen / flush window" and "windowed per screen". They do not say where a window ends, or what happens before the first screen. E19 lists `error` as an outcome but sets no threshold for it.

## Decision

- **Timing** runs from the `cordova.callbacks[id]` registration (Proxy `set` trap) to the first `cordova.callbackFromNative(id)`. The service is the id prefix (`service + cordova.callbackId++`). Calls without callbacks are not timed. A keep-callback stream is timed to its first result only.
- **Action** is read where exec hands the call to native, just after the callback is registered. On iOS that is `webkit.messageHandlers.cordova.postMessage([id, service, action, args])`. On Android it is `nativeApiProvider.get().exec(secret, service, action, id, args)`. If neither hook takes, the call is still timed with `bridge.action=unknown`.
- **Windows** are screen visits. A window ends when the screen is left or the app hides. Each window sends one `frame.summary` and one `bridge.summary` per service + action. Anything before the first screen counts toward the first screen. With no screens at all, only hiding ends a window, and the rows carry no `screen.name`.
- **`bridge.call`**: `error` on every failed call, whatever its duration. `slow` when a successful call takes at least `slowBridgeCallMs`. `no_callback` when nothing comes back within 30 s, and a late answer after that is ignored. A `no_callback` call is not counted in `bridge.summary`.
- **Frames**: a frame is the gap between two visible rAF ticks. Slow means at least `frameSlowThresholdMs`. Frozen means at least 700 ms, the Android vitals threshold. Hidden time never counts as a frame.

## Consequences

- A keep-callback plugin that stays silent for 30 s after it registers (for example, a listener that only answers on change) reports `no_callback`. Native caps (S4) bound how many of these are sent.
- The iOS action hook overrides a property on WebKit's handler object. This is unverified on a device. If WebKit hands out a fresh handler object on each access, iOS rows show `bridge.action=unknown`, and a device e2e (Q4) will catch it.

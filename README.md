# @nathanclaire/rum-cordova

Real User Monitoring for Cordova apps on Android and iOS.

> **Install the Edge RUM backend release before you ship a build with this plugin.** It sends contract 4.0.0 batches with `sdk.name=cordova`; an older backend drops them.

## Requirements

| | Minimum |
|---|---|
| cordova CLI | 13.0.0 |
| cordova-android | 15.0.0 (minSdk 24) |
| cordova-ios | 8.0.0 (iOS 14.0) |
| Node | 20.17 |

On `browser` and `electron` the plugin does nothing: every method exists and is a silent no-op.

## Install

```sh
cordova plugin add @nathanclaire/rum-cordova \
  --variable EDGE_RUM_API_KEY=<your key> \
  --variable EDGE_RUM_ENDPOINT=<your ingest URL>
```

That's all: capture starts on launch with the defaults below. No code is needed.

## Preferences

Set at install with `--variable NAME=value` (or in `package.json` → `cordova.plugins`). Read natively at launch.

| Variable | Default | What it does |
|---|---|---|
| `EDGE_RUM_API_KEY` | — | Your API key. |
| `EDGE_RUM_ENDPOINT` | — | Ingest URL, used exactly as given. |
| `EDGE_RUM_ENABLED` | `true` | `false` = opt-in mode: nothing is captured until `EdgeRum.enable()`. |
| `EDGE_RUM_ANR_ENABLED` / `EDGE_RUM_ANR_TIMEOUT_MS` | `true` / `5000` | Android: report the main thread blocked this long (`app.anr`). |
| `EDGE_RUM_HANG_ENABLED` / `EDGE_RUM_HANG_TIMEOUT_MS` | `true` / `2000` | Report main-thread hangs this long (`app.hang`). |
| `EDGE_RUM_MEMORY_SAMPLING_ENABLED` / `EDGE_RUM_MEMORY_SAMPLING_INTERVAL_MS` | `false` / `30000` | Periodic memory readings (start and end of each session are always sent). |
| `EDGE_RUM_IOS_WEBVIEW_HOOK` | `true` | iOS: catch WebView content-process deaths directly. `false` falls back to detecting them on the next page load. |
| `EDGE_RUM_DEVICEREADY_TIMEOUT_MS` | `10000` | Report launches where `deviceready` never fired within this time. |
| `EDGE_RUM_SAMPLE_RATE` | `1.0` | Share of sessions kept, 0–1. Crashes, launches and session start/end are always kept. |
| `EDGE_RUM_DEBUG` | `false` | Reserved; no effect in 1.0.0. |

Without a key or endpoint the plugin still captures to disk, and sends once `init()` supplies them.

## `init()`

Optional. Call it to change the defaults, ideally before `deviceready`:

```js
EdgeRum.init({
  release: 'web-2026.10.27',          // stamped on JS errors, for source-map lookup
  correlateRequestsTo: ['api.example.com'],
  ignoreUrls: [/\/health$/],
  beforeSend(event) {
    if (event.eventName === 'custom_event' && event.attributes['event.name'] === 'debug') return null;
    return event;
  },
});
```

| Option | Default | |
|---|---|---|
| `apiKey`, `endpoint` | install values | Override for this launch only (not stored). |
| `captureErrors` | `true` | Uncaught errors and unhandled rejections. |
| `captureRequests` | `true` | `fetch` and XHR. |
| `captureScreens` | `true` | Screen changes from the URL. `false` when you call `trackScreen()` from a router. |
| `captureInteractions` | `true` | Taps and clicks, incl. rage and dead taps. |
| `captureFrames` | `true` | Rendering smoothness. |
| `captureVitals` | `true` | Web Vitals (LCP, INP, CLS, FCP, TTFB). |
| `captureBridge` | `true` | Cordova plugin call timings. |
| `captureResourceTiming` | `false` | Per-resource load timings. |
| `captureConsoleErrors` | `false` | `console.error` reported as a handled error (otherwise a breadcrumb only). |
| `correlateRequestsTo` | `[]` | Hosts (string or RegExp) that get a W3C `traceparent` header. |
| `ignoreUrls` | `[]` | Requests to these URLs (substring or RegExp) are not captured. |
| `sanitizeUrl(url)` | — | Scrub a request URL further, after the built-in scrub. |
| `screenName(path)` | — | Map a route path to the screen name to report. |
| `beforeSend(event)` | — | Edit or drop (`return null`) each JS event. Synchronous. Native events (crashes, launch time, lifecycle, sessions) bypass it. |
| `release` | — | Release name stamped on JS errors. |
| `slowBridgeCallMs` | `1000` | A plugin call slower than this is reported on its own. |
| `frameSlowThresholdMs` | `34` | A frame slower than this counts as slow. |
| `debug` | `false` | Log plugin warnings to the console. |

Before `deviceready`, `init()` replaces the whole configuration; later calls apply to new captures only.

## API

All methods are on `window.EdgeRum`, synchronous, fire-and-forget and safe to call before `deviceready`. Typings ship in the package (`types/index.d.ts`).

| Method | |
|---|---|
| `init(opts?)` | See above. |
| `identify({ id?, name?, email?, phone? })` | Attach a user to every event; kept across launches until `clearUser()`. |
| `clearUser()` | Forget the user. |
| `track(name, attrs?)` | Record a named event (`custom_event`). |
| `measure(name, value, attrs?)` | Record a named number, e.g. `measure('cart.items', 3)`. |
| `time(name)` → `{ end(attrs?) }` | Timer; `end()` records the elapsed ms via `measure()`. |
| `trackScreen(name, attrs?)` | Report a screen change; see router recipes. |
| `captureError(err, attrs?)` | Report an error you caught. |
| `startTask(name, attrs?)` / `completeTask(name)` / `failTask(name, reason?)` | Measure whether a user journey completes. Open ones are abandoned at session end. |
| `markReady()` | The app is usable; ends the launch time if called within 30 s of `deviceready`. |
| `setAttribute(key, value)` / `removeAttribute(key)` | Add an attribute to every JS event. |
| `enable()` / `disable()` | Turn capture on / off, remembered across launches. `disable()` deletes anything unsent. |
| `reset()` | Start over as a new device: new session, user cleared, unsent data deleted. |
| `getSessionId()` → `Promise<string>` | Current session id once `deviceready` has fired. |

```js
document.addEventListener('deviceready', () => {
  EdgeRum.identify({ id: user.id });
  EdgeRum.startTask('checkout');
});
```

More: [what is captured](docs/events.md) · [privacy](docs/privacy.md) · [troubleshooting](docs/troubleshooting.md) · [changelog](CHANGELOG.md).

## Router recipes

By default, screens are named from the URL: the hash route if there is one (`#/…`), else the path. The query is dropped and ids become `{id}`. If your app uses a router, report the router's own route template instead: turn URL capture off before `deviceready`, then call `trackScreen()` when each navigation ends.

```js
EdgeRum.init({ captureScreens: false });
```

Pass a template (`/orders/:id`), never the live URL (`/orders/1234`).

### Angular Router

```ts
import { Component, inject } from '@angular/core';
import { NavigationEnd, Router, type ActivatedRouteSnapshot } from '@angular/router';
import { filter } from 'rxjs';

@Component({ selector: 'app-root', templateUrl: './app.component.html' })
export class AppComponent {
  constructor() {
    const router = inject(Router);
    router.events.pipe(filter((e) => e instanceof NavigationEnd)).subscribe(() => {
      const parts: string[] = [];
      for (let r: ActivatedRouteSnapshot | null = router.routerState.snapshot.root; r; r = r.firstChild) {
        if (r.routeConfig?.path) parts.push(r.routeConfig.path);
      }
      window.EdgeRum.trackScreen('/' + parts.join('/'));
    });
  }
}
```

### Vue Router

```ts
router.afterEach((to, _from, failure) => {
  if (!failure) window.EdgeRum.trackScreen(to.matched.at(-1)?.path ?? 'not-found');
});
```

### React Router

Render this once inside your router. `routes` is the same route array you give the router.

```tsx
import { useEffect } from 'react';
import { matchRoutes, useLocation } from 'react-router';
import { routes } from './routes';

export function ScreenTracker() {
  const location = useLocation();
  useEffect(() => {
    const path = (matchRoutes(routes, location) ?? []).map((m) => m.route.path).filter(Boolean).join('/');
    window.EdgeRum.trackScreen(('/' + path).replace(/\/+/g, '/'));
  }, [location.pathname]);
  return null;
}
```

### AngularJS ui-router

```js
angular.module('app').run(['$transitions', function ($transitions) {
  $transitions.onSuccess({}, function (trans) {
    window.EdgeRum.trackScreen(trans.to().name);
  });
}]);
```
